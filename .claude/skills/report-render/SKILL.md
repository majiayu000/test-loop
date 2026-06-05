---
name: report-render
description: |
  Turn a test runner's raw log into a Markdown report plus a structured
  JSON summary. Embeds the failure classification so a reader can see
  the failing tests, the run summary, and the failure-class counts on
  one page.
metadata:
  type: project
  language: any
  inputs: test log path, optional failure-classify JSON
  outputs: docs/reports/<date>/report.md, summary.json, log.txt
---

# report-render

Render a test run into something a human wants to read.

## When to use

- After every test run, whether green or red.
- From CI, with the report and summary uploaded as artifacts.
- Manually, to investigate a flake or to attach a report to a bug.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `repo_root` | yes | `.` | Path to the project root. The script writes outputs under `docs/reports/<YYYY-MM-DD>/`. |
| `log_path` | yes | none | Raw test runner output. Usually the file produced by `swift test 2>&1 | tee log.txt` or its equivalent. |
| `classify_json` | no | (none) | If [failure-classify](../failure-classify/SKILL.md) has already been run, pass its JSON output path to embed the classification. The render script calls the classifier itself if this is omitted. |
| `collect_only` | no | `false` | When `true`, skip running the test runner; render only from the existing log. Use to re-render a report after editing a summary template. |

## Output

Three artifacts under `docs/reports/<YYYY-MM-DD>/`:

| File | Purpose |
| --- | --- |
| `log.txt` | The raw test runner output, byte-for-byte. |
| `summary.json` | Structured facts: `total`, `passed`, `failed`, `exit_code`, `run_line`, plus the merged `failures_by_class` and `failures_grouped` when classification is available. |
| `report.md` | A human-readable summary. Always present. Contains a `Failures by class` section only when there is at least one failure. |

## Algorithm

1. **Capture** the test runner's stdout and stderr to `log.txt`. Use
   `tee` rather than `>` so the same output appears in the user's
   terminal.
2. **Count** the number of `✔` and `✘` lines, and the test run summary
   line. The summary line format is runner-specific; see "Runner
   differences" below.
3. **List** the failing test names, deduplicated.
4. **Classify** if not already classified (call
   [failure-classify](../failure-classify/SKILL.md) on the log).
5. **Render** the Markdown. Use a `✅ PASS` / `❌ FAIL` indicator on
   the first line, then counts, then the run summary, then failing
   tests, then the failure-class breakdown, then a list of artifact
   paths.

## Runner differences

The run-summary line format is the only runner-specific bit. v0.1
recognises:

| Runner | Summary line shape |
| --- | --- |
| Swift Testing | `Test run with N tests passed after X.XXX seconds.` |
| pytest | `N passed in X.XXs` |
| go test | `ok  <package>  X.XXXs` or `FAIL` per package |
| cargo test | `test result: ok. N passed; M failed; ...` |

If the runner is not in this list, the report still renders but the
`run_line` field in `summary.json` reads `(no summary line found)`.
That is a deliberate fallback, not a failure.

## Worked example (Swift, end-to-end)

```bash
bash scripts/render_report.sh
```

Produces, in `docs/reports/2026-06-02/`:

```
log.txt            # full swift test output
summary.json       # 83 / 85 / 0, exit 0, run_line="Test run with 83 tests..."
report.md          # 10-line markdown summary
```

When run with a failing test injected, the report gains a `Failures by
class` section with the `ASSERTION_FAILURE` bucket populated.

## Anti-patterns

- **Treating the Markdown report as a primary source of truth.** It is
  a view. `summary.json` is the structured fact. Build downstream tools
  off `summary.json`.
- **Committing `docs/reports/` to source control.** It is a run output,
  not a design artifact. Add `docs/reports/` to `.gitignore`.
- **Renaming `summary.json` per run.** Keep the schema stable across
  days. Triage tools that consume it should not need to be told which
  day a report came from.

## Cross-references

- [failure-classify](../failure-classify/SKILL.md) — invoked by this
  skill when no `classify_json` is supplied.
- [init-loop](../init-loop/SKILL.md) — installs the render script into
  a fresh project.
- [drift-check](../drift-check/SKILL.md) — the corresponding pre-test
  step in the loop.
