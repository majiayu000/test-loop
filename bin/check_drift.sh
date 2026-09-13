#!/usr/bin/env bash
# check_drift.sh — flag public symbols in a source tree that are not
# documented in the project's knowledge base.
#
# Usage:
#   bin/check_drift.sh                                # caff defaults: Sources/CaffCore + L1_modules.md
#   bin/check_drift.sh --source-glob 'src/**/*.py' --knowledge-base docs/knowledge
#   bin/check_drift.sh --language python --changed
#   bin/check_drift.sh --language python --staged   # index-only (pre-commit)
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
#   - --changed scans staged + unstaged + untracked sources (worktree view).
#   - --staged scans only the index (for pre-commit's staged-only contract).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults preserve the caff 0.1.4 behaviour so this script can drop in
# unchanged for caff users.
SOURCE_GLOB="Sources/CaffCore"
KNOWLEDGE_BASE="docs/knowledge/L1_modules.md"
LANGUAGE="swift"
CHANGED_ONLY=0
STAGED_ONLY=0

while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --changed) CHANGED_ONLY=1; shift ;;
        --staged)  STAGED_ONLY=1; CHANGED_ONLY=1; shift ;;
        --source-glob)        SOURCE_GLOB="${2:-}"; shift 2 ;;
        --source-glob=*)      SOURCE_GLOB="${arg#--source-glob=}"; shift ;;
        --knowledge-base)     KNOWLEDGE_BASE="${2:-}"; shift 2 ;;
        --knowledge-base=*)   KNOWLEDGE_BASE="${arg#--knowledge-base=}"; shift ;;
        --language)           LANGUAGE="${2:-}"; shift 2 ;;
        --language=*)         LANGUAGE="${arg#--language=}"; shift ;;
        -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Keep the caller-facing glob for git pathspecs (must stay repo-relative).
SOURCE_GLOB_INPUT="$SOURCE_GLOB"

# Resolve repo-root-relative paths for filesystem checks / full-mode find.
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

# Resolve knowledge-base path relative to the repo (for index lookups).
L1_REL="$KNOWLEDGE_BASE"
case "$L1_REL" in
    /*)
        case "$L1_REL" in
            "$REPO_ROOT"/*) L1_REL="${L1_REL#"$REPO_ROOT"/}" ;;
            "$REPO_ROOT") L1_REL="." ;;
        esac
        ;;
esac

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

# Lexically normalize a path (absolute or repo-relative) and ensure it stays
# inside REPO_ROOT. Prints a repo-relative path (or ".") on success.
repo_rel_or_die() {
    local raw="$1"
    local abs
    case "$raw" in
        /*) abs="$raw" ;;
        *)  abs="$REPO_ROOT/$raw" ;;
    esac
    # Collapse . and .. without resolving symlinks (bash 3.2 / macOS).
    local normalized="" part
    local IFS='/'
    # shellcheck disable=SC2086
    set -- $abs
    unset IFS
    for part in "$@"; do
        case "$part" in
            ""|.) continue ;;
            ..)
                if [[ -z "$normalized" || "$normalized" == "/" ]]; then
                    echo "error: --source-glob must be inside the repository ($raw)" >&2
                    exit 2
                fi
                normalized="${normalized%/*}"
                [[ -z "$normalized" ]] && normalized="/"
                ;;
            *)
                if [[ -z "$normalized" || "$normalized" == "/" ]]; then
                    normalized="/$part"
                else
                    normalized="$normalized/$part"
                fi
                ;;
        esac
    done
    [[ -z "$normalized" ]] && normalized="/"
    case "$normalized" in
        "$REPO_ROOT") printf '%s\n' "." ;;
        "$REPO_ROOT"/*) printf '%s\n' "${normalized#"$REPO_ROOT"/}" ;;
        *)
            echo "error: --source-glob must be inside the repository ($raw)" >&2
            exit 2
            ;;
    esac
}

# Reject relative/absolute source globs that escape the repository before any
# git pathspec work (including cases where the outside directory exists).
SRC_DIR_INPUT="$(echo "$SOURCE_GLOB_INPUT" | sed -E 's|/\*\*?[^/]*$||;s|/\*[^/]*$||')"
SRC_DIR_REPO_REL="$(repo_rel_or_die "$SRC_DIR_INPUT")"

# Pick the source directory for filesystem checks / full-mode find.
SRC_DIR="$(echo "$SOURCE_GLOB" | sed -E 's|/\*[^/]*$||;s|/\*\*$||')"
if [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXTRACTED="$WORK/extracted.txt"
LIST_OF_FILES="$WORK/files.txt"
STAGED_FILES="$WORK/staged.txt"
WORKTREE_FILES="$WORK/worktree_changed.txt"
> "$EXTRACTED"
> "$LIST_OF_FILES"
> "$STAGED_FILES"
> "$WORKTREE_FILES"

# Filter NUL-terminated git pathnames, keeping only those with LANG_EXT.
# Preserve NUL delimiters end-to-end so embedded newlines cannot split paths.
# Line-oriented git output may C-quote unusual names (ending in .ext"), which
# silently drops them from extension filters.
filter_paths_z() {
    local ext="$1"
    while IFS= read -r -d '' path; do
        [[ -z "$path" ]] && continue
        case "$path" in
            *."$ext") printf '%s\0' "$path" ;;
        esac
    done
}

# Decide which files to scan, in --changed/--staged mode or full mode.
if [[ $CHANGED_ONLY -eq 1 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: --changed/--staged requires a git repo" >&2
        exit 2
    fi
    # SOURCE_GLOB may be a path or a path/**/*.ext pattern. Build repo-relative
    # git pathspecs: absolute pathspecs do not match, and ** alone omits files
    # directly under the source directory.
    SRC_DIR_FOR_GIT="$SRC_DIR_REPO_REL"
    if [[ -z "$SRC_DIR_FOR_GIT" || "$SRC_DIR_FOR_GIT" == "." ]]; then
        PATHSPEC_DIRECT="*.${LANG_EXT}"
        PATHSPEC_NESTED="**/*.${LANG_EXT}"
        SRC_DIR_FOR_GIT="."
    else
        PATHSPEC_DIRECT="${SRC_DIR_FOR_GIT}/*.${LANG_EXT}"
        PATHSPEC_NESTED="${SRC_DIR_FOR_GIT}/**/*.${LANG_EXT}"
    fi
    {
        git -C "$REPO_ROOT" diff --cached -z --name-only -- "$PATHSPEC_DIRECT" "$PATHSPEC_NESTED" 2>/dev/null || true
    } | filter_paths_z "$LANG_EXT" | sort -z -u > "$STAGED_FILES" || true
    if [[ $STAGED_ONLY -eq 1 ]]; then
        cp "$STAGED_FILES" "$LIST_OF_FILES"
    else
        {
            git -C "$REPO_ROOT" diff -z --name-only -- "$PATHSPEC_DIRECT" "$PATHSPEC_NESTED" 2>/dev/null || true
            git -C "$REPO_ROOT" ls-files -z --others --exclude-standard -- "$PATHSPEC_DIRECT" "$PATHSPEC_NESTED" 2>/dev/null || true
        } | filter_paths_z "$LANG_EXT" | sort -z -u > "$WORKTREE_FILES" || true
        cat "$STAGED_FILES" "$WORKTREE_FILES" | sort -z -u > "$LIST_OF_FILES"
    fi
    if [[ ! -s "$LIST_OF_FILES" ]]; then
        echo "no changed $LANGUAGE files under $SRC_DIR_FOR_GIT; nothing to check"
        exit 0
    fi
else
    if [[ ! -f "$L1_FILE" ]]; then
        echo "error: $L1_FILE not found" >&2
        exit 2
    fi
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

# Choose the knowledge-base snapshot to match the sources being scanned.
# - Index-only / staged-only scans: use the index blob. If the KB exists in
#   HEAD but was deleted from the index, treat it as empty (do not fall back
#   to a worktree recreation).
# - Worktree changes present under --changed: use the worktree KB so unstaged
#   API + docs edits are compared together.
L1_SOURCE="$L1_FILE"
if [[ $CHANGED_ONLY -eq 1 ]]; then
    use_index_l1=0
    if [[ $STAGED_ONLY -eq 1 ]]; then
        use_index_l1=1
    elif [[ -s "$STAGED_FILES" && ! -s "$WORKTREE_FILES" ]]; then
        use_index_l1=1
    fi
    if [[ $use_index_l1 -eq 1 ]]; then
        if git -C "$REPO_ROOT" cat-file -e ":$L1_REL" 2>/dev/null; then
            git -C "$REPO_ROOT" show ":$L1_REL" > "$WORK/l1_blob.md"
            L1_SOURCE="$WORK/l1_blob.md"
        elif git -C "$REPO_ROOT" cat-file -e "HEAD:$L1_REL" 2>/dev/null; then
            # Tracked in HEAD but removed from the index (e.g. git rm --cached).
            : > "$WORK/l1_blob.md"
            L1_SOURCE="$WORK/l1_blob.md"
        elif [[ ! -f "$L1_FILE" ]]; then
            echo "error: $L1_FILE not found" >&2
            exit 2
        fi
    else
        # Worktree (or mixed) scan: prefer the worktree knowledge base.
        if [[ ! -f "$L1_FILE" ]]; then
            if git -C "$REPO_ROOT" cat-file -e ":$L1_REL" 2>/dev/null; then
                git -C "$REPO_ROOT" show ":$L1_REL" > "$WORK/l1_blob.md"
                L1_SOURCE="$WORK/l1_blob.md"
            else
                echo "error: $L1_FILE not found" >&2
                exit 2
            fi
        fi
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

scan_one() {
    local rel="$1"
    [[ -z "$rel" ]] && return 0
    # Staged paths are scanned from the index blob so --changed/--staged
    # match what pre-commit will commit, even when the worktree diverges.
    if [[ $CHANGED_ONLY -eq 1 ]] && grep -F -z -x -q -- "$rel" "$STAGED_FILES" 2>/dev/null; then
        git -C "$REPO_ROOT" show ":$rel" 2>/dev/null \
            | emit_awk "$rel" >> "$EXTRACTED" 2>/dev/null || true
        return 0
    fi
    f="$REPO_ROOT/$rel"
    [[ -f "$f" ]] || return 0
    emit_awk "$rel" < "$f" >> "$EXTRACTED" 2>/dev/null || true
}

if [[ $CHANGED_ONLY -eq 1 ]]; then
    while IFS= read -r -d '' rel; do
        scan_one "$rel"
    done < "$LIST_OF_FILES"
    FILE_COUNT=$(tr -cd '\0' < "$LIST_OF_FILES" | wc -c | tr -d ' ')
else
    while IFS= read -r rel; do
        scan_one "$rel"
    done < "$LIST_OF_FILES"
    FILE_COUNT=$(wc -l < "$LIST_OF_FILES" | tr -d ' ')
fi

# Sorted unique names extracted from sources.
EXTRACTED_NAMES="$WORK/names.txt"
sed -E 's|^[^:]+:||' "$EXTRACTED" | sort -u > "$EXTRACTED_NAMES"

# Sorted unique identifiers appearing in L1 (strip code fences and backticks first).
L1_NAMES="$WORK/l1_names.txt"
sed -E 's/```[^`]*```//g' "$L1_SOURCE" \
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

echo "scanned $TOTAL public symbol(s) across $FILE_COUNT file(s)"

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
