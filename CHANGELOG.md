# Changelog

## Unreleased

### Fixed

- `bin/check_drift.sh --changed` now keeps the first parser's `CHANGED_ONLY=1`
  value. A dead second argument-parsing block had reset `CHANGED_ONLY=0` after
  `shift` emptied argv, so changed-only mode never activated (LOGIC-01). The
  empty changed-file `grep` is also tolerated under `set -e` so the documented
  "no changed … files" exit 0 path is reachable. Self-check CI now smokes the
  changed-only path.
- `--changed` git pathspecs stay repository-relative (absolute `SOURCE_GLOB`
  prefixes no longer silence matches), cover both `dir/*.ext` and
  `dir/**/*.ext` so top-level source files are included, and staged paths are
  scanned from index blobs so pre-commit sees the commit contents even when the
  worktree diverges.
- `--changed` accepts an absolute `--source-glob` equal to the repository root
  (normalized to `.`), reads the knowledge base from the index blob alongside
  staged sources, and lists paths with `git -z` so C-quoted unusual filenames
  are not dropped before drift scanning.
- `--staged` scans index-only paths for pre-commit's staged-only contract;
  `--changed` keeps NUL-delimited path lists end-to-end, uses the worktree
  knowledge base when scanning unstaged sources, treats an index-deleted
  knowledge base as empty instead of falling back to the worktree, and rejects
  relative `--source-glob` values that escape the repository via `..`.
- `--changed` unions index and worktree symbols when a path has both staged and
  unstaged edits (so neither post-stage worktree APIs nor staged-only APIs are
  missed), and falls back to the index blob when the worktree copy is gone
  (staged+deleted / AD); extracted records use NUL-delimited path/symbol pairs
  so newline-bearing pathnames cannot invent phantom missing symbols;
  `--staged` no longer requires the source directory to exist in the worktree.
- Staged path membership uses a portable bash NUL-list probe instead of
  GNU-only `grep -z`; `--staged` treats a worktree-only knowledge base as empty
  rather than falling back to the uncommitted file; slashless
  `--source-glob '*.ext'` is normalized to the repository root like
  `$REPO_ROOT/*.ext`.
- `--changed` compares index symbols to the index knowledge base and worktree
  symbols to the worktree knowledge base (so documenting a staged-only API only
  in an unstaged KB no longer falsely cleans); `--changed` also scans when the
  worktree source directory is absent if staged blobs remain; `--staged
  --language auto` detects language from index-only manifests.

## v0.1.0 - 2026-06-23

Initial public release of test-loop as a contract package for closed test-loop
workflows.

### Added

- Six agent-facing skills:
  - `test-loop-bootstrap`
  - `init-loop`
  - `drift-check`
  - `failure-classify`
  - `report-render`
  - `drill`
- Agent-neutral skill source under `.agents/skills/`.
- Generated Claude Code and Codex skill copies under `.claude/skills/` and
  `.codex/skills/`.
- Sync checker for skill copies.
- Knowledge overview and drill notes.
- Script and hook templates for the future v0.2 implementation phase.

### Notes

v0.1.0 is intentionally contract-first. It documents the loop and skill
contracts before turning the scripts into a fully self-hosted executable loop.
