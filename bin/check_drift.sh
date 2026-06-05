#!/usr/bin/env bash
# check_drift.sh — flag public symbols in a source tree that are not
# documented in the project's knowledge base.
#
# Usage:
#   bin/check_drift.sh                                # caff defaults: Sources/CaffCore + L1_modules.md
#   bin/check_drift.sh --source-glob 'src/**/*.py' --knowledge-base docs/knowledge
#   bin/check_drift.sh --language python --changed
#   bin/check_drift.sh --language auto               # auto-detect from manifest
#
# Supported languages: swift (default), python, go, rust, auto.
# "auto" picks from the project's manifest: Package.swift -> swift,
# pyproject.toml -> python, go.mod -> go, Cargo.toml -> rust.
#
# Maintenance: when a new public symbol is added, edit the knowledge base
# (and/or add it to the L1_BASELINE list below) so the warning goes away.
#
# Notes:
#   - Pure POSIX-ish bash, no associative arrays, no mapfile. macOS bash 3.2
#     compatible.
#   - Coarse regex per language (see LANGUAGE_PATTERNS below). L1 documents
#     public API at the type level, so coarse is sufficient for drift.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults preserve the caff 0.1.4 behaviour so this script can drop in
# unchanged for caff users.
SOURCE_GLOB="Sources/CaffCore"
KNOWLEDGE_BASE="docs/knowledge/L1_modules.md"
LANGUAGE="swift"
CHANGED_ONLY=0

while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --changed) CHANGED_ONLY=1; shift ;;
        --source-glob)        SOURCE_GLOB="${2:-}"; shift 2 ;;
        --source-glob=*)      SOURCE_GLOB="${arg#--source-glob=}"; shift ;;
        --knowledge-base)     KNOWLEDGE_BASE="${2:-}"; shift 2 ;;
        --knowledge-base=*)   KNOWLEDGE_BASE="${arg#--knowledge-base=}"; shift ;;
        --language)           LANGUAGE="${2:-}"; shift 2 ;;
        --language=*)         LANGUAGE="${arg#--language=}"; shift ;;
        -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Resolve repo-root-relative paths.
case "$SOURCE_GLOB" in
    /*) ;;
    *)  SOURCE_GLOB="$REPO_ROOT/$SOURCE_GLOB" ;;
esac
case "$KNOWLEDGE_BASE" in
    /*) ;;
    *)  KNOWLEDGE_BASE="$REPO_ROOT/$KNOWLEDGE_BASE" ;;
esac
L1_FILE="$KNOWLEDGE_BASE"

# Auto-detect language from a project manifest.
if [ "$LANGUAGE" = "auto" ]; then
    if [ -f "$REPO_ROOT/Package.swift" ]; then LANGUAGE="swift"
    elif [ -f "$REPO_ROOT/pyproject.toml" ]; then LANGUAGE="python"
    elif [ -f "$REPO_ROOT/go.mod" ]; then LANGUAGE="go"
    elif [ -f "$REPO_ROOT/Cargo.toml" ]; then LANGUAGE="rust"
    else
        echo "error: --language auto could not find Package.swift / pyproject.toml / go.mod / Cargo.toml" >&2
        exit 2
    fi
fi

# Pick the source directory for --changed: the first directory segment of
# the glob, or a known default for caff compatibility.
SRC_DIR="$(echo "$SOURCE_GLOB" | sed -E 's|/\*[^/]*$||;s|/\*\*$||')"
if [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 2
fi
if [[ ! -f "$L1_FILE" ]]; then
    echo "error: $L1_FILE not found" >&2
    exit 2
fi

CHANGED_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --changed) CHANGED_ONLY=1 ;;
        -h|--help)
            sed -n '3,22p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Language -> file extension used for filtering and the awk symbol rules.
case "$LANGUAGE" in
    swift)  LANG_EXT="swift" ;;
    python) LANG_EXT="py" ;;
    go)     LANG_EXT="go" ;;
    rust)   LANG_EXT="rs" ;;
    *)
        echo "error: unsupported --language: $LANGUAGE (swift|python|go|rust|auto)" >&2
        exit 2
        ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXTRACTED="$WORK/extracted.txt"
LIST_OF_FILES="$WORK/files.txt"
> "$EXTRACTED"
> "$LIST_OF_FILES"

# Decide which files to scan, in --changed mode or full mode.
if [[ $CHANGED_ONLY -eq 1 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: --changed requires a git repo" >&2
        exit 2
    fi
    # SOURCE_GLOB may be a path or a path/**/*.ext pattern. Build a git
    # pathspec from the directory part (git pathspecs accept dir/* glob).
    SRC_DIR_FOR_GIT="$(echo "$SOURCE_GLOB" | sed -E 's|/\*\*?[^/]*$||;s|/\*[^/]*$||')"
    {
        git -C "$REPO_ROOT" diff --name-only -- "${SRC_DIR_FOR_GIT}/**/*.${LANG_EXT}" 2>/dev/null || true
        git -C "$REPO_ROOT" diff --cached --name-only -- "${SRC_DIR_FOR_GIT}/**/*.${LANG_EXT}" 2>/dev/null || true
        git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "${SRC_DIR_FOR_GIT}/**/*.${LANG_EXT}" 2>/dev/null || true
    } | sort -u | grep -E "\.${LANG_EXT}$" > "$LIST_OF_FILES"
    if [[ ! -s "$LIST_OF_FILES" ]]; then
        echo "no changed $LANGUAGE files under $SRC_DIR_FOR_GIT; nothing to check"
        exit 0
    fi
else
    # Full mode. SOURCE_GLOB may be a path or a glob. Use find for
    # portability; -path "$SRC_DIR" matches the dir-or-anywhere patterns.
    cd "$REPO_ROOT"
    # shellcheck disable=SC2086
    find . -path "$SOURCE_GLOB" -type f 2>/dev/null \
        | sed 's|^\./||' > "$LIST_OF_FILES" \
        || find "$SOURCE_GLOB" -type f 2>/dev/null | sed "s|^$REPO_ROOT/||" >> "$LIST_OF_FILES"
    if [[ ! -s "$LIST_OF_FILES" ]]; then
        echo "error: no files matched $SOURCE_GLOB" >&2
        exit 2
    fi
fi

# Per-language awk rules. Each rule prints "<rel_path>:<Name>".
emit_awk() {
    case "$LANGUAGE" in
        swift)
            awk -v rel="$1" '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                /^public[[:space:]]+(struct|class|enum|protocol)[[:space:]]+[A-Z][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "struct" || $i == "class" || $i == "enum" || $i == "protocol") { print rel ":" ident($(i+1)); break }
                    }
                    next
                }
                /^public[[:space:]]+(static[[:space:]]+)?(func|init)[[:space:]]+/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "func" || $i == "init") { print rel ":" ident($(i+1)); break }
                    }
                }
            '
            ;;
        python)
            # Match top-level (zero-indent) class/def and names that are not
            # private (no leading underscore). Multiline `class Foo(Bar):`
            # and `def foo(x):` are common.
            awk -v rel="$1" '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                # top-level class or def (no leading whitespace)
                /^class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "class") { print rel ":" ident($(i+1)); break }
                    }
                }
                /^def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "def") { print rel ":" ident($(i+1)); break }
                    }
                }
            '
            ;;
        go)
            # Top-level func / type / var / const with an uppercase first
            # letter (Go convention for exported identifiers).
            awk -v rel="$1" '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                # indented continuation lines are not declarations
                /^[[:space:]]/ { next }
                /^(func[[:space:]]+([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?[A-Z][A-Za-z0-9_]*|type[[:space:]]+[A-Z][A-Za-z0-9_]*|var[[:space:]]+[A-Z][A-Za-z0-9_]*|const[[:space:]]+[A-Z][A-Za-z0-9_]*)/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "func" || $i == "type" || $i == "var" || $i == "const") { print rel ":" ident($(i+1)); break }
                    }
                }
            '
            ;;
        rust)
            # pub fn / pub struct / pub enum / pub trait / pub use.
            awk -v rel="$1" '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                /pub[[:space:]]+(fn|struct|enum|trait|use|mod|type)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "fn" || $i == "struct" || $i == "enum" || $i == "trait" || $i == "use" || $i == "mod" || $i == "type") { print rel ":" ident($(i+1)); break }
                    }
                }
            '
            ;;
    esac
}

while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    f="$REPO_ROOT/$rel"
    [[ -f "$f" ]] || continue
    emit_awk "$rel" < "$f" >> "$EXTRACTED" 2>/dev/null || true
done < "$LIST_OF_FILES"

# Sorted unique names extracted from sources.
EXTRACTED_NAMES="$WORK/names.txt"
sed -E 's|^[^:]+:||' "$EXTRACTED" | sort -u > "$EXTRACTED_NAMES"

# Sorted unique identifiers appearing in L1 (strip code fences and backticks first).
L1_NAMES="$WORK/l1_names.txt"
sed -E 's/```[^`]*```//g' "$L1_FILE" \
    | tr -cs 'A-Za-z0-9_' '\n' \
    | sort -u > "$L1_NAMES"

# Baseline: symbols that are deliberately undocumented in L1 (e.g., trivial
# accessors the regex catches but the L1 table doesn't enumerate by name).
# Add a name here ONLY if it is genuinely not worth documenting in L1.
L1_BASELINE_RAW='
PowerAssertionKind
PowerAssertionError
AgentHookTarget
AgentHookChange
AgentHookManagerError
AgentHookManager
RemoteControlError
RemoteControlParser
AgentActivityState
AgentActivityEvaluation
AgentActivityTouch
AgentActivityCooldown
SessionDuration
RemainingTimeFormatter
SessionHistoryResult
SessionHistoryEntry
PowerSourceState
SafetyPolicyError
SafetyPolicy
PowerSourceMonitor
SessionOptions
SessionSource
WakeSession
'
BASELINE_NAMES="$WORK/baseline_names.txt"
printf '%s' "$L1_BASELINE_RAW" | tr -d ' ' | grep -E '^[A-Z][A-Za-z0-9_]+$' | sort -u > "$BASELINE_NAMES"

# Known = (L1 names) union (baseline names).
KNOWN="$WORK/known.txt"
cat "$L1_NAMES" "$BASELINE_NAMES" | sort -u > "$KNOWN"

# Missing = extracted names minus known.
MISSING="$WORK/missing.txt"
comm -23 "$EXTRACTED_NAMES" "$KNOWN" > "$MISSING"

TOTAL=$(wc -l < "$EXTRACTED_NAMES" | tr -d ' ')
NUM_MISSING=$(wc -l < "$MISSING" | tr -d ' ')

echo "scanned $TOTAL public symbol(s) across $(wc -l < "$LIST_OF_FILES" | tr -d ' ') file(s)"

if [[ "$NUM_MISSING" -eq 0 ]]; then
    echo "drift: clean ✅"
    exit 0
fi

echo "drift: $NUM_MISSING public symbol(s) not in L1_modules.md or baseline:"
# Show file:line for each missing name by joining back with EXTRACTED.
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -E ":${name}$" "$EXTRACTED" | head -3 | sed 's/^/  - /'
done < "$MISSING"
echo
echo "Fix: add the symbol to docs/knowledge/L1_modules.md (or update the"
echo "     L1_BASELINE list in scripts/check_drift.sh if it is intentionally"
echo "     undocumented)."
exit 1
