---
name: init-loop
description: |
  Install the closed test loop into a fresh project. Copies the
  pre-commit hook, the CI workflow, the render script, the drift check
  script, the failure classifier, and the knowledge-base templates,
  then runs the drill to verify the loop reacts.
metadata:
  type: project
  language: any
  inputs: target project path, language, optional existing knowledge base
  outputs: scripts/, .githooks/, .github/workflows/, docs/knowledge/ populated
---

# init-loop

Stand up the closed test loop in a project that does not have it.

## When to use

- Once, at the start of a new project, after the build system works.
- Once, in an existing project that has a test suite but no loop.
- After forking a project that you want to bring up to the same
  standard as the rest of your fleet.

Do not use this skill to install a single piece of the loop. If you
only want the drift check, copy `scripts/check_drift.sh` directly and
move on.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `target_path` | yes | none | Path to the project root. The skill refuses to write outside this directory. |
| `language` | yes | none | One of `swift`, `python`, `go`, `rust`. Picks the source glob and the failure-classify patterns. |
| `ci_provider` | no | `github` | Currently only `github` is supported. `gitlab` and `circleci` are tracked for v0.3. |
| `knowledge_base_path` | no | `docs/knowledge/` | Where the L0/L1/L2 Markdown lives. The skill will create the directory if it does not exist. |
| `existing_loop_check` | no | `true` | When `true`, the skill aborts if it finds an existing `.githooks/pre-commit` or `.github/workflows/test.yml` to avoid clobbering. |

## Output

The skill writes into `target_path`:

| Path | Contents |
| --- | --- |
| `scripts/check_drift.sh` | The drift check script. |
| `scripts/classify_failures.py` | The failure classifier. |
| `scripts/render_report.sh` | The report renderer. |
| `.githooks/pre-commit` | The drift guardrail. |
| `.github/workflows/test.yml` | The CI workflow. |
| `docs/knowledge/L0_overview.md` | A starter L0 file the user is expected to fill in. |
| `docs/knowledge/L1_modules.md` | A starter L1 file. |
| `docs/knowledge/L2_equivalence_classes.md` | A starter L2 file. |
| `docs/spec/closed-loop.md` | A reference spec explaining the loop. |
| `.gitignore` (append) | `docs/reports/` if not already ignored. |

After writing, the skill runs the [drill](../drill/SKILL.md) procedure
to verify the loop reacts to a real injected failure.

## Algorithm

1. **Detect** the language from the project: `Package.swift` for
   Swift, `pyproject.toml` for Python, `go.mod` for Go, `Cargo.toml`
   for Rust.
2. **Refuse** if the project already has the loop and
   `existing_loop_check=true`.
3. **Copy** each file in the table above. If the target file already
   exists, skip it. Do not overwrite user-edited files.
4. **Configure** `git config core.hooksPath .githooks` in the target
   project, so the pre-commit hook is active.
5. **Drill** by running the [drill](../drill/SKILL.md) skill. If the
   drill fails, the skill exits non-zero and the user should read
   `docs/reports/<date>/drill-*.md` to understand why.

## Worked example

```bash
# Add the loop to a Swift project.
test-loop init --target /path/to/project --language swift

# Or, since v0.1 ships skills rather than a CLI, the equivalent
# agent-driven flow:
# 1. /init-loop target=/path/to/project language=swift
# 2. /drill target=/path/to/project
```

## Anti-patterns

- **Overwriting an existing loop.** Always run with
  `existing_loop_check=true` unless you know the existing loop is
  broken beyond repair.
- **Treating the starter L0/L1/L2 files as a finished knowledge base.**
  They are scaffolding. Fill them in based on the project's actual
  modules and contracts.
- **Skipping the drill.** The drill is the only way to know the loop
  actually reacts. A loop that was copied but never drilled is a loop
  that may not work.

## Cross-references

- [drill](../drill/SKILL.md) — the next step, run automatically by
  this skill.
- [drift-check](../drift-check/SKILL.md) — one of the pieces this
  skill installs.
- [report-render](../report-render/SKILL.md) — another piece.
- [test-loop-bootstrap](../test-loop-bootstrap/SKILL.md) — for users
  who do not know which skill to start with.
