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

# Longest directory prefix without wildcards — used for existence checks
# and messaging. Keeps intermediate glob segments (src/*/pkg/*.py → src).
SRC_DIR="$(echo "$SOURCE_GLOB" | sed -E 's|/[^/]*[\*\?].*$||')"
if [ -z "$SRC_DIR" ]; then
    SRC_DIR="$SOURCE_GLOB"
fi
if [ ! -d "$SRC_DIR" ] && [ ! -f "$SOURCE_GLOB" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run find | sort with pipefail so traversal errors are not masked by sort.
find_sorted() {
    local out="$1"
    shift
    local err="$WORK/find_err.txt"
    local rc
    set +e
    set -o pipefail
    "$@" 2>"$err" | sort > "$out"
    rc=$?
    set +o pipefail
    set -e
    if [ "$rc" -ne 0 ]; then
        cat "$err" >&2
        return "$rc"
    fi
    return 0
}

# Prefer repo-relative paths when a match lives under REPO_ROOT.
normalize_listed_paths() {
    local infile="$1"
    local outfile="$2"
    > "$outfile"
    while IFS= read -r abs; do
        [[ -z "$abs" ]] && continue
        case "$abs" in
            "$REPO_ROOT"/*) printf '%s\n' "${abs#$REPO_ROOT/}" >> "$outfile" ;;
            *)              printf '%s\n' "$abs" >> "$outfile" ;;
        esac
    done < "$infile"
}

# Drop paths with any hidden component (leading '.') so --changed matches
# full-mode Python glob semantics (include_hidden=False / leading-dot skip).
filter_visible_paths() {
    local infile="$1"
    local outfile="$2"
    > "$outfile"
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        case "/$rel/" in
            */.*/*|*/.*/) continue ;;
        esac
        printf '%s\n' "$rel" >> "$outfile"
    done < "$infile"
}

# --knowledge-base may be a Markdown file or a directory of *.md files.
# Directory mode matches the documented invocation and the drift-check skill.
L1_FILE="$WORK/l1_combined.md"
if [ -d "$KNOWLEDGE_BASE" ]; then
    KB_LIST="$WORK/kb_files.txt"
    if ! find_sorted "$KB_LIST" find "$KNOWLEDGE_BASE" -type f -name '*.md'; then
        echo "error: failed to traverse knowledge base $KNOWLEDGE_BASE" >&2
        exit 2
    fi
    if [[ ! -s "$KB_LIST" ]]; then
        echo "error: no *.md files under $KNOWLEDGE_BASE" >&2
        exit 2
    fi
    > "$L1_FILE"
    while IFS= read -r kb; do
        [[ -z "$kb" ]] && continue
        cat "$kb" >> "$L1_FILE"
        printf '\n' >> "$L1_FILE"
    done < "$KB_LIST"
elif [ -f "$KNOWLEDGE_BASE" ]; then
    cp "$KNOWLEDGE_BASE" "$L1_FILE"
else
    echo "error: $KNOWLEDGE_BASE not found" >&2
    exit 2
fi

EXTRACTED="$WORK/extracted.txt"
LIST_OF_FILES="$WORK/files.txt"
> "$EXTRACTED"
> "$LIST_OF_FILES"

# Expand a source path or glob into newline-separated file paths.
# Handles directories, literal files, and * / ** patterns without bash
# globstar or GNU find -maxdepth (both unavailable on macOS bash 3.2 /
# BSD find). Wildcard expansion uses Python's glob so intermediate
# segments (src/*/pkg/*.py, src/**/pkg/*.py) keep their meaning.
expand_source_glob() {
    local pattern="$1"
    local out="$2"
    local raw="$WORK/expand_raw.txt"

    if [ -f "$pattern" ]; then
        printf '%s\n' "$pattern" > "$raw"
        normalize_listed_paths "$raw" "$out"
        return 0
    fi

    if [ -d "$pattern" ]; then
        if ! find_sorted "$raw" find "$pattern" -type f -name "*.${LANG_EXT}"; then
            echo "error: failed to traverse $pattern" >&2
            return 1
        fi
        normalize_listed_paths "$raw" "$out"
        return 0
    fi

    case "$pattern" in
        *\**|*\?*)
            if ! python3 - "$pattern" "$raw" <<'PY'
import glob
import os
import sys

pattern, out = sys.argv[1], sys.argv[2]


def literal_prefix(pat: str) -> str:
    """Longest path prefix before the first glob metacharacter."""
    sep = os.sep
    parts = pat.split(sep)
    acc = []
    for i, part in enumerate(parts):
        if i == 0 and part == "":
            acc.append("")
            continue
        if any(c in part for c in "*?["):
            break
        acc.append(part)
    if not acc:
        return "."
    prefix = sep.join(acc)
    if prefix == "":
        return sep
    return prefix


# glob.glob swallows OSError from unreadable directories via _listdir and can
# report a clean scan while public symbols under those trees were skipped.
# Probe the literal prefix with os.walk(..., onerror=...) and fail closed.
root = literal_prefix(pattern)
errors = []


def on_walk_error(err: OSError) -> None:
    errors.append(err)


if os.path.isdir(root):
    for _dirpath, _dirnames, _filenames in os.walk(root, onerror=on_walk_error):
        pass
    if errors:
        for err in errors:
            sys.stderr.write(f"{err}\n")
        sys.exit(1)

# recursive=True enables ** and preserves intermediate wildcard segments.
matches = sorted(
    {p for p in glob.glob(pattern, recursive=True) if os.path.isfile(p)}
)
with open(out, "w", encoding="utf-8") as fh:
    for path in matches:
        fh.write(path + "\n")
PY
            then
                echo "error: failed to expand source glob $pattern" >&2
                return 1
            fi
            normalize_listed_paths "$raw" "$out"
            return 0
            ;;
    esac

    > "$out"
    return 0
}

# Decide which files to scan, in --changed mode or full mode.
if [[ $CHANGED_ONLY -eq 1 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: --changed requires a git repo" >&2
        exit 2
    fi
    # Preserve the caller's glob as a git pathspec so restrictive patterns
    # (e.g. dir/*.py) are not widened to dir/**/*.py. Use :(glob) so '*' does
    # not cross '/' (git's default pathspec magic matches across directories).
    GLOB_FOR_GIT="$SOURCE_GLOB"
    case "$GLOB_FOR_GIT" in
        "$REPO_ROOT"/*) GLOB_FOR_GIT="${GLOB_FOR_GIT#$REPO_ROOT/}" ;;
    esac
    PATHSPEC=":(glob)$GLOB_FOR_GIT"
    {
        git -C "$REPO_ROOT" diff --name-only -- "$PATHSPEC" 2>/dev/null || true
        git -C "$REPO_ROOT" diff --cached --name-only -- "$PATHSPEC" 2>/dev/null || true
        git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "$PATHSPEC" 2>/dev/null || true
    } | sort -u > "$WORK/changed_raw.txt"
    # grep exits 1 on no matches; with set -e that must not abort before
    # the empty-list success path below. Then drop hidden-component paths so
    # :(glob) matches full-mode glob (which skips leading-dot names).
    grep -E "\.${LANG_EXT}$" "$WORK/changed_raw.txt" > "$WORK/changed_ext.txt" || true
    filter_visible_paths "$WORK/changed_ext.txt" "$LIST_OF_FILES"
    if [[ ! -s "$LIST_OF_FILES" ]]; then
        echo "no changed $LANGUAGE files matching $GLOB_FOR_GIT; nothing to check"
        exit 0
    fi
else
    if ! expand_source_glob "$SOURCE_GLOB" "$LIST_OF_FILES"; then
        exit 2
    fi
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
    case "$rel" in
        /*) f="$rel" ;;
        *)  f="$REPO_ROOT/$rel" ;;
    esac
    [[ -f "$f" ]] || continue
    # Report repo-relative paths when possible; otherwise keep absolute.
    case "$f" in
        "$REPO_ROOT"/*) display="${f#$REPO_ROOT/}" ;;
        *)              display="$f" ;;
    esac
    emit_awk "$display" < "$f" >> "$EXTRACTED" 2>/dev/null || true
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
echo "Fix: add the symbol to the knowledge base (or update the"
echo "     L1_BASELINE list in bin/check_drift.sh if it is intentionally"
echo "     undocumented)."
exit 1
