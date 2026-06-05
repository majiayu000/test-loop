# test-loop

A small, language-agnostic toolkit for the **closed test loop**:
drift detection, failure classification, structured reports, a pre-commit
guardrail, and a CI workflow you can copy into any project.

> Status: design phase. Skills and their contracts are written; the
> underlying scripts that those skills describe are tracked in
> [docs/knowledge/L0_overview.md](docs/knowledge/L0_overview.md).

## What it is

test-loop does for the test loop what a linter does for syntax: gives you
five points of friction and tells you which one is broken.

| Tool | What it catches | When it runs |
| --- | --- | --- |
| `drift-check` | a public symbol that is not in the knowledge base | pre-commit + CI |
| `failure-classify` | a real assertion failure hiding among expected-failure tests | after `swift test` / `pytest` / `go test` |
| `report-render` | a passing suite whose report is unparseable | after every test run |
| `init-loop` | a project that does not have the loop at all | once per project |
| `drill` | a loop that exists but does not actually react | once after install |

The tools do not overlap with the language's own test runner. They sit
around the runner and inspect its inputs and outputs.

## What it is not

- Not a test framework. Use Swift Testing / pytest / go test / cargo test
  for that.
- Not a code generator. It will not write tests for you.
- Not a coverage tool. It will not tell you which lines are untested.
- Not tied to any specific project. It is a pattern, packaged.

## Relationship to other projects

| Project | Relationship |
| --- | --- |
| [aitest-kit](../aitest-kit) | A deeper, Python-specific toolchain that *compiles* Markdown test designs into pytest code. test-loop is the lighter sibling: no codegen, no module profile, no emitter. |
| [caff](../caff) | A macOS menu bar app where this loop was first built out end-to-end. caff 0.1.4 ships the loop in its own `scripts/`, `docs/knowledge/`, `.githooks/`, and `.github/workflows/`. test-loop generalises what caff proved. |

## Skills (the entry points)

test-loop is consumed through six skills, shipped in three directories so
the same SKILL.md serves Claude Code (`.claude/`), Codex (`.codex/`)
and generic agents (`.agents/`):

| Skill | Purpose |
| --- | --- |
| `test-loop-bootstrap` | meta: choose which of the other five skills to use |
| `init-loop` | copy the loop into a fresh project |
| `drift-check` | flag public symbols not in the knowledge base |
| `failure-classify` | group failing tests by naming convention |
| `report-render` | turn a test log into a Markdown + JSON report |
| `drill` | inject one failing test, verify the loop reacts, roll back |

## License

MIT. See [LICENSE](LICENSE).
