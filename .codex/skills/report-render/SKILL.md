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
| `summary.json` | Structured facts: `total`, `passed`, `failed`, report `exit_code` (see below), `run_line`, plus the merged `failures_by_class` and `failures_grouped` when classification is available. |
| `report.md` | A human-readable summary when rendering completes. Contains a `Failures by class` section only when there is at least one failure. |

### Exit status and verdict

The preview at `bin/render_report.sh` uses the same report status for its
process exit code, `summary.json.exit_code`, and Markdown PASS/FAIL verdict:

- **Live:** preserve a nonzero test-command exit code. If the command exits
  `0` but parsed failures are present, use `1`; otherwise use `0`.
- **Collect (`--collect`):** read the existing date-based `log.txt` without
  running the command. Use `1` when parsed failures are present, else `0`.
  This cannot recover the original runner exit code.

These rules describe a completed render. An unsupported `--language` value
or a missing collect log exits `2` before a new summary or report is written.
A zero status or zero test count is not proof that tests ran or passed;
compare the raw log and original runner result. Classification names such
as `EXPECTED_FAILURE` do not override the report status.

## Algorithm

1. **Capture** the test runner's stdout and stderr to `log.txt`. Use
   `tee` rather than `>` so the same output appears in the user's
   terminal.
2. **Count** results using the selected language's log patterns, and
   extract the run summary. Swift uses `✔` and `✘` lines; the other
   runners use their own result lines or summaries. See "Runner
   differences" below.
3. **List** the failing test names, deduplicated.
4. **Classify** if not already classified (call
   [failure-classify](../failure-classify/SKILL.md) on the log).
5. **Render** the Markdown. Use a `✅ PASS` / `❌ FAIL` indicator on
   the first line, then counts, then the run summary, then failing
   tests, then the failure-class breakdown, then a list of artifact
   paths.

## Runner differences

Result extraction and run-summary formats are runner-specific. The
working preview supports `--language swift|python|go|rust` and recognises:

| Runner | Summary line shape |
| --- | --- |
| Swift Testing | `Test run with N tests passed after X.XXX seconds.` |
| pytest | `N passed in X.XXs` |
| go test | `ok  <package>  X.XXXs` or `FAIL` per package |
| cargo test | `test result: ok. N passed; M failed; ...` |

An unsupported `--language` value is rejected, including when a custom
`--test-command` is supplied. For a supported language whose log has no
recognized summary, the report still renders with `run_line` set to
`(no summary line found)`. This fallback alone does not change the status;
the live-command status and parsed failures still determine the verdict.

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
