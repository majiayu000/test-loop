# Changelog

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
