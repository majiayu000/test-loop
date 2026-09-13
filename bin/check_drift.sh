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
#   - --changed scans staged + unstaged + untracked sources (unioning both
#     snapshots when a path differs in the index and the worktree), comparing
#     index symbols to the index KB and worktree symbols to the worktree KB.
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

# Auto-detect language from a project manifest snapshot.
# snapshot=index  -> index blobs only (--staged, and the staged side of --changed)
# snapshot=worktree -> worktree files only
# snapshot=either -> worktree first, then index (full-mode / single-language fallback)
manifest_present_in() {
    local snapshot="$1" name="$2"
    case "$snapshot" in
        index)
            git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
                && git -C "$REPO_ROOT" cat-file -e ":$name" 2>/dev/null
            return $?
            ;;
        worktree)
            [ -f "$REPO_ROOT/$name" ]
            return $?
            ;;
        either)
            if [ -f "$REPO_ROOT/$name" ]; then
                return 0
            fi
            git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
                && git -C "$REPO_ROOT" cat-file -e ":$name" 2>/dev/null
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

detect_language_in() {
    local snapshot="$1"
    if manifest_present_in "$snapshot" "Package.swift"; then
        printf '%s\n' "swift"
    elif manifest_present_in "$snapshot" "pyproject.toml"; then
        printf '%s\n' "python"
    elif manifest_present_in "$snapshot" "go.mod"; then
        printf '%s\n' "go"
    elif manifest_present_in "$snapshot" "Cargo.toml"; then
        printf '%s\n' "rust"
    else
        return 1
    fi
}

lang_ext_for() {
    case "$1" in
        swift)  printf '%s\n' "swift" ;;
        python) printf '%s\n' "py" ;;
        go)     printf '%s\n' "go" ;;
        rust)   printf '%s\n' "rs" ;;
        *)      return 1 ;;
    esac
}

INDEX_LANGUAGE=""
WORKTREE_LANGUAGE=""
if [ "$LANGUAGE" = "auto" ]; then
    if [[ $STAGED_ONLY -eq 1 ]]; then
        # --staged: index-only so a worktree-only higher-priority manifest
        # (e.g. unstaged Package.swift) cannot override staged pyproject.toml.
        if ! LANGUAGE="$(detect_language_in index)"; then
            echo "error: --language auto could not find Package.swift / pyproject.toml / go.mod / Cargo.toml" >&2
            exit 2
        fi
        INDEX_LANGUAGE="$LANGUAGE"
        WORKTREE_LANGUAGE="$LANGUAGE"
    elif [[ $CHANGED_ONLY -eq 1 ]]; then
        # --changed: resolve index and worktree languages independently so a
        # worktree-only higher-priority manifest cannot mask staged sources.
        INDEX_LANGUAGE="$(detect_language_in index || true)"
        WORKTREE_LANGUAGE="$(detect_language_in worktree || true)"
        if [[ -z "$INDEX_LANGUAGE" && -z "$WORKTREE_LANGUAGE" ]]; then
            echo "error: --language auto could not find Package.swift / pyproject.toml / go.mod / Cargo.toml" >&2
            exit 2
        fi
        [[ -z "$INDEX_LANGUAGE" ]] && INDEX_LANGUAGE="$WORKTREE_LANGUAGE"
        [[ -z "$WORKTREE_LANGUAGE" ]] && WORKTREE_LANGUAGE="$INDEX_LANGUAGE"
        LANGUAGE="$WORKTREE_LANGUAGE"
    else
        if ! LANGUAGE="$(detect_language_in either)"; then
            echo "error: --language auto could not find Package.swift / pyproject.toml / go.mod / Cargo.toml" >&2
            exit 2
        fi
        INDEX_LANGUAGE="$LANGUAGE"
        WORKTREE_LANGUAGE="$LANGUAGE"
    fi
else
    case "$LANGUAGE" in
        swift|python|go|rust) ;;
        *)
            echo "error: unsupported --language: $LANGUAGE (swift|python|go|rust|auto)" >&2
            exit 2
            ;;
    esac
    INDEX_LANGUAGE="$LANGUAGE"
    WORKTREE_LANGUAGE="$LANGUAGE"
fi

# Language -> file extension used for filtering and the awk symbol rules.
# Changed+auto may use distinct staged vs worktree extensions.
if ! LANG_EXT="$(lang_ext_for "$LANGUAGE")"; then
    echo "error: unsupported --language: $LANGUAGE (swift|python|go|rust|auto)" >&2
    exit 2
fi
INDEX_LANG_EXT="$(lang_ext_for "$INDEX_LANGUAGE")"
WORKTREE_LANG_EXT="$(lang_ext_for "$WORKTREE_LANGUAGE")"

# Lexically normalize a path (absolute or repo-relative) and ensure it stays
# inside REPO_ROOT. Prints a repo-relative path (or ".") on success.
# Splits on '/' with noglob so wildcard components (e.g. packages/*/src) are
# preserved for git pathspecs instead of expanding against the caller's cwd.
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
    set -f
    # shellcheck disable=SC2086
    set -- $abs
    set +f
    unset IFS
    for part in "$@"; do
        case "$part" in
            ""|.) continue ;;
            ..)
                if [[ -z "$normalized" || "$normalized" == "/" ]]; then
                    echo "error: path must be inside the repository ($raw)" >&2
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
            echo "error: path must be inside the repository ($raw)" >&2
            exit 2
            ;;
    esac
}

# Resolve knowledge-base path relative to the repo (for index lookups).
# Normalize .. segments when the path is inside REPO_ROOT so git cat-file
# ":docs/knowledge/../knowledge/..." resolves. Absolute paths outside the
# repository (e.g. a mktemp worktree-only KB) are left unchanged so index
# lookups miss and staged mode treats them as empty.
case "$KNOWLEDGE_BASE" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        L1_REL="$(repo_rel_or_die "$KNOWLEDGE_BASE")"
        ;;
    *)
        L1_REL="$KNOWLEDGE_BASE"
        ;;
esac

# Reject relative/absolute source globs that escape the repository before any
# git pathspec work (including cases where the outside directory exists).
# Slashless file globs such as '*.py' mean the repository root (same as
# '$REPO_ROOT/*.py'); the trailing-suffix strip only matches slash-prefixed
# patterns and would otherwise leave '*.py' as a bogus directory name.
#
# Filename-specific patterns (src/api.py, src/test_*.py, src/**/api.py,
# src/**/test_*) must keep the caller's file pattern: after peeling trailing
# /*.ext directory globs, a remaining basename that still looks like a file
# pathspec (contains '.' or a wildcard metacharacter) must not be rewritten as
# dir/*.ext. Dotless wildcards such as test_* are valid Git pathspecs.
SRC_STRIPPED="$(echo "$SOURCE_GLOB_INPUT" | sed -E 's|/\*\*?[^/]*$||;s|/\*[^/]*$||')"
FILE_PATHSPEC_REPO_REL=""
case "$SOURCE_GLOB_INPUT" in
    */*)
        _base="${SRC_STRIPPED##*/}"
        case "$_base" in
            *.*|*[\*\?]*|*\[*)
                FILE_PATHSPEC_REPO_REL="$(repo_rel_or_die "$SOURCE_GLOB_INPUT")"
                SRC_DIR_INPUT="${SRC_STRIPPED%/*}"
                [[ -z "$SRC_DIR_INPUT" ]] && SRC_DIR_INPUT="."
                ;;
            *)
                SRC_DIR_INPUT="$SRC_STRIPPED"
                ;;
        esac
        ;;
    *[\*\?]*|*\[*)
        # Slashless wildcards such as '*.py' mean the repository root (same as
        # '$REPO_ROOT/*.py'); keep directory-root pathspec expansion.
        SRC_DIR_INPUT="."
        ;;
    *.*)
        # Slashless filename such as 'api.py' at the repository root.
        FILE_PATHSPEC_REPO_REL="$(repo_rel_or_die "$SOURCE_GLOB_INPUT")"
        SRC_DIR_INPUT="."
        ;;
    *)
        SRC_DIR_INPUT="$SRC_STRIPPED"
        ;;
esac
unset _base
SRC_DIR_REPO_REL="$(repo_rel_or_die "$SRC_DIR_INPUT")"

# Pick the source directory for filesystem checks / full-mode find.
# Changed/staged scans do not require the worktree directory: staged blobs may
# still exist after the last source file is deleted or a newly staged tree is
# removed locally before commit.
SRC_DIR="$(echo "$SOURCE_GLOB" | sed -E 's|/\*[^/]*$||;s|/\*\*$||')"
if [[ $CHANGED_ONLY -ne 1 ]] && [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR not found" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# EXTRACTED_* store NUL-delimited path/symbol pairs (path\0symbol\0...) so a
# pathname containing a newline cannot split records the way path:symbol lines
# would. Staged and worktree origins are kept separate so each set can be
# validated against the matching knowledge-base snapshot.
EXTRACTED_STAGED="$WORK/extracted_staged.txt"
EXTRACTED_WORKTREE="$WORK/extracted_worktree.txt"
EXTRACTED="$WORK/extracted.txt"
LIST_OF_FILES="$WORK/files.txt"
STAGED_FILES="$WORK/staged.txt"
WORKTREE_FILES="$WORK/worktree_changed.txt"
> "$EXTRACTED_STAGED"
> "$EXTRACTED_WORKTREE"
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

# Membership test for NUL-delimited path lists. Avoid GNU-only `grep -z`
# (macOS / BSD grep historically lack lowercase -z; failed checks would
# silently treat every staged path as absent from the list).
path_in_z_list() {
    local needle="$1" file="$2" path
    [[ -s "$file" ]] || return 1
    while IFS= read -r -d '' path; do
        [[ "$path" == "$needle" ]] && return 0
    done < "$file"
    return 1
}

# Unique NUL-delimited paths without `sort -z` (absent or unreliable on some
# BSD/macOS sort builds). Use an O(n) hash-set directory instead of scanning
# the accumulated list for every path (quadratic membership hung pre-commit
# on ~2k staged files).
unique_paths_z() {
    local out="$1" path key setdir tmp
    setdir="$(mktemp -d "$WORK/unique_set.XXXXXX")"
    tmp="$(mktemp "$WORK/unique_paths.XXXXXX")"
    : > "$tmp"
    while IFS= read -r -d '' path; do
        [[ -z "$path" ]] && continue
        key="$(printf '%s' "$path" | shasum -a 256 2>/dev/null | awk '{print $1}')"
        if [[ -z "$key" ]]; then
            # Extremely defensive fallback if shasum is unavailable.
            path_in_z_list "$path" "$tmp" && continue
            printf '%s\0' "$path" >> "$tmp"
            continue
        fi
        if [[ -e "$setdir/$key" ]]; then
            continue
        fi
        : > "$setdir/$key"
        printf '%s\0' "$path" >> "$tmp"
    done
    rm -rf "$setdir"
    mv "$tmp" "$out"
}

# Decide which files to scan, in --changed/--staged mode or full mode.
if [[ $CHANGED_ONLY -eq 1 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: --changed/--staged requires a git repo" >&2
        exit 2
    fi
    # SOURCE_GLOB may be a path or a path/**/*.ext pattern. Build repo-relative
    # git pathspecs: absolute pathspecs do not match, and ** alone omits files
    # directly under the source directory. Filename-specific globs keep the
    # caller's pattern (src/api.py) instead of becoming dir/*.ext.
    # Emit pathspecs for a language extension into PATHSPEC_DIRECT/NESTED and
    # set SRC_DIR_FOR_GIT for messaging.
    build_pathspecs_for_ext() {
        local ext="$1"
        SRC_DIR_FOR_GIT="$SRC_DIR_REPO_REL"
        if [[ -n "$FILE_PATHSPEC_REPO_REL" ]]; then
            PATHSPEC_DIRECT="$FILE_PATHSPEC_REPO_REL"
            PATHSPEC_NESTED="$FILE_PATHSPEC_REPO_REL"
            SRC_DIR_FOR_GIT="$FILE_PATHSPEC_REPO_REL"
        elif [[ -z "$SRC_DIR_FOR_GIT" || "$SRC_DIR_FOR_GIT" == "." ]]; then
            PATHSPEC_DIRECT="*.${ext}"
            PATHSPEC_NESTED="**/*.${ext}"
            SRC_DIR_FOR_GIT="."
        else
            PATHSPEC_DIRECT="${SRC_DIR_FOR_GIT}/*.${ext}"
            PATHSPEC_NESTED="${SRC_DIR_FOR_GIT}/**/*.${ext}"
        fi
    }
    build_pathspecs_for_ext "$INDEX_LANG_EXT"
    {
        git -C "$REPO_ROOT" diff --cached -z --name-only -- "$PATHSPEC_DIRECT" "$PATHSPEC_NESTED" 2>/dev/null || true
    } | filter_paths_z "$INDEX_LANG_EXT" | unique_paths_z "$STAGED_FILES"
    if [[ $STAGED_ONLY -eq 1 ]]; then
        cp "$STAGED_FILES" "$LIST_OF_FILES"
    else
        build_pathspecs_for_ext "$WORKTREE_LANG_EXT"
        {
            git -C "$REPO_ROOT" diff -z --name-only -- "$PATHSPEC_DIRECT" "$PATHSPEC_NESTED" 2>/dev/null || true
            git -C "$REPO_ROOT" ls-files -z --others --exclude-standard -- "$PATHSPEC_DIRECT" "$PATHSPEC_NESTED" 2>/dev/null || true
        } | filter_paths_z "$WORKTREE_LANG_EXT" | unique_paths_z "$WORKTREE_FILES"
        {
            cat "$STAGED_FILES" "$WORKTREE_FILES"
        } | unique_paths_z "$LIST_OF_FILES"
        # Prefer a stable messaging root; filename pathspecs win when set.
        build_pathspecs_for_ext "$LANG_EXT"
    fi
    if [[ ! -s "$LIST_OF_FILES" ]]; then
        if [[ "$INDEX_LANGUAGE" != "$WORKTREE_LANGUAGE" ]]; then
            echo "no changed $INDEX_LANGUAGE/$WORKTREE_LANGUAGE files under $SRC_DIR_FOR_GIT; nothing to check"
        else
            echo "no changed $LANGUAGE files under $SRC_DIR_FOR_GIT; nothing to check"
        fi
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

# Resolve knowledge-base snapshots for staged vs worktree symbol sets.
# - Index/staged symbols: use the index blob. If the KB exists in HEAD but was
#   deleted from the index, treat it as empty (do not fall back to a worktree
#   recreation). Index-only scans never fall back to a worktree-only KB.
# - Worktree symbols: use the worktree file; if it is missing, treat the KB as
#   deleted (empty) rather than substituting the index copy (which would hide
#   drift when the worktree KB was removed).
INDEX_L1_SOURCE=""
WORKTREE_L1_SOURCE=""

# Read an index (or HEAD) blob, dereferencing in-repo symlink objects so a
# tracked KB symlink yields the target Markdown content rather than the
# symlink pathname stored in the blob.
git_show_blob_deref() {
    local rev_path="$1" dest="$2"
    local mode="" target="" base_dir="" resolved=""
    local spec_path="${rev_path#*:}"
    local rev_prefix="${rev_path%%:*}"
    if [[ "$rev_prefix" == ":" || "$rev_prefix" == "" ]]; then
        mode="$(git -C "$REPO_ROOT" ls-files --stage -- "$spec_path" 2>/dev/null | awk '{print $1; exit}')"
    else
        mode="$(git -C "$REPO_ROOT" ls-tree "$rev_prefix" -- "$spec_path" 2>/dev/null | awk '{print $1; exit}')"
    fi
    if [[ "$mode" == "120000" ]]; then
        target="$(git -C "$REPO_ROOT" show "$rev_path" 2>/dev/null || true)"
        [[ -z "$target" ]] && return 1
        case "$target" in
            /*)
                # Absolute symlink targets are not index paths; refuse.
                return 1
                ;;
            *)
                base_dir="$(dirname "$spec_path")"
                if [[ "$base_dir" == "." ]]; then
                    resolved="$target"
                else
                    resolved="$base_dir/$target"
                fi
                # Collapse . / .. without leaving the repo spelling git expects.
                resolved="$(repo_rel_or_die "$REPO_ROOT/$resolved")"
                if [[ "$rev_prefix" == ":" || "$rev_prefix" == "" ]]; then
                    git -C "$REPO_ROOT" show ":$resolved" > "$dest" 2>/dev/null
                else
                    git -C "$REPO_ROOT" show "$rev_prefix:$resolved" > "$dest" 2>/dev/null
                fi
                return $?
                ;;
        esac
    fi
    git -C "$REPO_ROOT" show "$rev_path" > "$dest" 2>/dev/null
}

resolve_index_l1() {
    if git -C "$REPO_ROOT" cat-file -e ":$L1_REL" 2>/dev/null; then
        if ! git_show_blob_deref ":$L1_REL" "$WORK/l1_index.md"; then
            : > "$WORK/l1_index.md"
        fi
        INDEX_L1_SOURCE="$WORK/l1_index.md"
    elif git -C "$REPO_ROOT" cat-file -e "HEAD:$L1_REL" 2>/dev/null; then
        # Tracked in HEAD but removed from the index (e.g. git rm --cached).
        : > "$WORK/l1_index.md"
        INDEX_L1_SOURCE="$WORK/l1_index.md"
    else
        # Missing from index/HEAD: treat as empty for staged/index comparisons
        # (never fall back to a worktree-only KB).
        : > "$WORK/l1_index.md"
        INDEX_L1_SOURCE="$WORK/l1_index.md"
    fi
}

resolve_worktree_l1() {
    if [[ -f "$L1_FILE" ]]; then
        WORKTREE_L1_SOURCE="$L1_FILE"
    else
        # Missing/deleted in the worktree: empty KB (do not use the index blob).
        : > "$WORK/l1_worktree.md"
        WORKTREE_L1_SOURCE="$WORK/l1_worktree.md"
    fi
}

# Per-language awk rules. Each rule prints one symbol name per line.
# The caller pairs names with the source path via NUL-delimited EXTRACTED
# records so pathnames with embedded newlines stay unambiguous.
emit_awk() {
    local lang="${1:-$LANGUAGE}"
    case "$lang" in
        swift)
            awk '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                /^public[[:space:]]+(struct|class|enum|protocol)[[:space:]]+[A-Z][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "struct" || $i == "class" || $i == "enum" || $i == "protocol") { print ident($(i+1)); break }
                    }
                    next
                }
                /^public[[:space:]]+(static[[:space:]]+)?(func|init)[[:space:]]+/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "func" || $i == "init") { print ident($(i+1)); break }
                    }
                }
            '
            ;;
        python)
            # Match top-level (zero-indent) class/def and names that are not
            # private (no leading underscore). Multiline `class Foo(Bar):`
            # and `def foo(x):` are common.
            awk '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                # top-level class or def (no leading whitespace)
                /^class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "class") { print ident($(i+1)); break }
                    }
                }
                /^def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "def") { print ident($(i+1)); break }
                    }
                }
            '
            ;;
        go)
            # Top-level func / type / var / const with an uppercase first
            # letter (Go convention for exported identifiers).
            awk '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                # indented continuation lines are not declarations
                /^[[:space:]]/ { next }
                /^(func[[:space:]]+([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?[A-Z][A-Za-z0-9_]*|type[[:space:]]+[A-Z][A-Za-z0-9_]*|var[[:space:]]+[A-Z][A-Za-z0-9_]*|const[[:space:]]+[A-Z][A-Za-z0-9_]*)/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "func" || $i == "type" || $i == "var" || $i == "const") { print ident($(i+1)); break }
                    }
                }
            '
            ;;
        rust)
            # pub fn / pub struct / pub enum / pub trait / pub use.
            awk '
                function ident(s) { n = split(s, _, "[^A-Za-z0-9_]"); return _[1] }
                /pub[[:space:]]+(fn|struct|enum|trait|use|mod|type)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "fn" || $i == "struct" || $i == "enum" || $i == "trait" || $i == "use" || $i == "mod" || $i == "type") { print ident($(i+1)); break }
                    }
                }
            '
            ;;
    esac
}

# Append path/symbol pairs from stdin source text into the given EXTRACTED file.
append_extracted() {
    local rel="$1" out="$2" lang="${3:-$LANGUAGE}" name
    emit_awk "$lang" | while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        printf '%s\0%s\0' "$rel" "$name" >> "$out"
    done
}

# Extract symbols for one path from the index and/or worktree without
# membership probes. --staged never consults worktree lists; --changed
# iterates each origin's path list independently so scan cost stays linear.
extract_staged_path() {
    local rel="$1"
    [[ -z "$rel" ]] && return 0
    git -C "$REPO_ROOT" show ":$rel" 2>/dev/null \
        | append_extracted "$rel" "$EXTRACTED_STAGED" "$INDEX_LANGUAGE" 2>/dev/null || true
}

extract_worktree_path() {
    local rel="$1"
    local f
    [[ -z "$rel" ]] && return 0
    f="$REPO_ROOT/$rel"
    [[ -f "$f" ]] || return 0
    append_extracted "$rel" "$EXTRACTED_WORKTREE" "$WORKTREE_LANGUAGE" < "$f" 2>/dev/null || true
}

if [[ $STAGED_ONLY -eq 1 ]]; then
    while IFS= read -r -d '' rel; do
        extract_staged_path "$rel"
    done < "$STAGED_FILES"
    FILE_COUNT=$(tr -cd '\0' < "$STAGED_FILES" | wc -c | tr -d ' ')
elif [[ $CHANGED_ONLY -eq 1 ]]; then
    while IFS= read -r -d '' rel; do
        extract_staged_path "$rel"
    done < "$STAGED_FILES"
    while IFS= read -r -d '' rel; do
        extract_worktree_path "$rel"
    done < "$WORKTREE_FILES"
    FILE_COUNT=$(tr -cd '\0' < "$LIST_OF_FILES" | wc -c | tr -d ' ')
else
    while IFS= read -r rel; do
        extract_worktree_path "$rel"
    done < "$LIST_OF_FILES"
    FILE_COUNT=$(wc -l < "$LIST_OF_FILES" | tr -d ' ')
fi

# Merge origin-specific extractions for reporting path:symbol pairs.
cat "$EXTRACTED_STAGED" "$EXTRACTED_WORKTREE" > "$EXTRACTED"

# Sorted unique names extracted from a NUL path/symbol pair file.
names_from_extracted() {
    local src="$1" dest="$2"
    : > "$dest"
    [[ -s "$src" ]] || return 0
    {
        while true; do
            IFS= read -r -d '' _rel || break
            IFS= read -r -d '' name || break
            [[ -z "$name" ]] && continue
            printf '%s\n' "$name"
        done < "$src"
    } | sort -u > "$dest"
}

# Missing = extracted names minus (L1 names ∪ baseline).
compute_missing_against_l1() {
    local extracted_file="$1" l1_source="$2" missing_out="$3"
    local names_file l1_names known
    names_file="$WORK/names_$(basename "$missing_out").txt"
    l1_names="$WORK/l1_names_$(basename "$missing_out").txt"
    known="$WORK/known_$(basename "$missing_out").txt"
    names_from_extracted "$extracted_file" "$names_file"
    sed -E 's/```[^`]*```//g' "$l1_source" \
        | tr -cs 'A-Za-z0-9_' '\n' \
        | sort -u > "$l1_names"
    cat "$l1_names" "$BASELINE_NAMES" | sort -u > "$known"
    comm -23 "$names_file" "$known" > "$missing_out"
}

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

MISSING="$WORK/missing.txt"
: > "$MISSING"
EXTRACTED_NAMES="$WORK/names.txt"
: > "$EXTRACTED_NAMES"

# Compare each origin's symbols against the matching KB snapshot. Combining
# both symbol sets with a single worktree KB falsely cleans staged-only APIs
# that were documented only in an unstaged knowledge-base edit.
need_index_compare=0
need_worktree_compare=0
if [[ $STAGED_ONLY -eq 1 ]]; then
    need_index_compare=1
elif [[ $CHANGED_ONLY -eq 1 ]]; then
    [[ -s "$EXTRACTED_STAGED" ]] && need_index_compare=1
    [[ -s "$EXTRACTED_WORKTREE" ]] && need_worktree_compare=1
    # Path listed but extraction empty (e.g. deleted worktree file): still
    # honor the corresponding KB side when that file list is non-empty and the
    # other side already triggered a compare, or when only one side has paths.
    if [[ $need_index_compare -eq 0 && $need_worktree_compare -eq 0 ]]; then
        [[ -s "$STAGED_FILES" ]] && need_index_compare=1
        [[ -s "$WORKTREE_FILES" ]] && need_worktree_compare=1
    fi
else
    need_worktree_compare=1
fi

if [[ $need_index_compare -eq 1 ]]; then
    resolve_index_l1
    compute_missing_against_l1 "$EXTRACTED_STAGED" "$INDEX_L1_SOURCE" "$WORK/missing_staged.txt"
    names_from_extracted "$EXTRACTED_STAGED" "$WORK/names_staged.txt"
    cat "$WORK/names_staged.txt" >> "$EXTRACTED_NAMES"
    cat "$WORK/missing_staged.txt" >> "$MISSING"
fi
if [[ $need_worktree_compare -eq 1 ]]; then
    resolve_worktree_l1
    compute_missing_against_l1 "$EXTRACTED_WORKTREE" "$WORKTREE_L1_SOURCE" "$WORK/missing_worktree.txt"
    names_from_extracted "$EXTRACTED_WORKTREE" "$WORK/names_worktree.txt"
    cat "$WORK/names_worktree.txt" >> "$EXTRACTED_NAMES"
    cat "$WORK/missing_worktree.txt" >> "$MISSING"
fi

sort -u "$EXTRACTED_NAMES" -o "$EXTRACTED_NAMES"
sort -u "$MISSING" -o "$MISSING"

TOTAL=$(wc -l < "$EXTRACTED_NAMES" | tr -d ' ')
NUM_MISSING=$(wc -l < "$MISSING" | tr -d ' ')

echo "scanned $TOTAL public symbol(s) across $FILE_COUNT file(s)"

if [[ "$NUM_MISSING" -eq 0 ]]; then
    echo "drift: clean ✅"
    exit 0
fi

echo "drift: $NUM_MISSING public symbol(s) not in L1_modules.md or baseline:"
# Show path:symbol for each missing name by joining back with EXTRACTED pairs.
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    shown=0
    while true; do
        IFS= read -r -d '' rel || break
        IFS= read -r -d '' sym || break
        if [[ "$sym" == "$name" ]]; then
            # Collapse embedded newlines in path for single-line display only.
            safe_rel="${rel//$'\n'/\\n}"
            printf '  - %s:%s\n' "$safe_rel" "$sym"
            shown=$((shown + 1))
            [[ "$shown" -ge 3 ]] && break
        fi
    done < "$EXTRACTED"
done < "$MISSING"
echo
echo "Fix: add the symbol to docs/knowledge/L1_modules.md (or update the"
echo "     L1_BASELINE list in scripts/check_drift.sh if it is intentionally"
echo "     undocumented)."
exit 1
