---
name: drill
description: |
  Verify the closed test loop actually reacts by injecting one
  intentionally failing test, running each of the five loop tools, and
  recording the result. Use after init-loop and after any change to a
  loop tool.
metadata:
  type: project
  language: any
  inputs: target project path, language, test framework
  outputs: docs/knowledge/drill-YYYY-MM-DD.md, drill artifacts
---

# drill

Prove the loop is wired correctly by breaking it on purpose.

## When to use

- Right after [init-loop](../init-loop/SKILL.md).
- After editing any of the five loop tools.
- After a refactor that touches CI, the pre-commit hook, or the
  report-render script.

Do not use this skill to verify a real failure. The drill is *for*
verifying the loop, not for triaging a regression.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `target_path` | yes | none | The project to drill. |
| `language` | yes | none | One of `swift`, `python`, `go`, `rust`. Picks the injection template. |
| `expected_failures` | no | `1` | The number of distinct failing tests to inject. One is the minimum needed to exercise the failure-classify step. Two or more tests whether the classifier deduplicates duplicate failure lines. |
| `drill_label` | no | `closed-loop-drill` | A short label used in test names so the drill fixture can be located later if cleanup is interrupted. |

## Output

| Path | Contents |
| --- | --- |
| `docs/knowledge/drill-YYYY-MM-DD.md` | Evidence document: the commands that ran, the output captured, the verdict per step, and any defects found. |
| `docs/reports/<date>/` | Rendered test report from the injected failure (this is the "real" run the loop produces). |
| working tree | Briefly contains the drill fixture file. Cleaned up on success. |

## Algorithm (eight steps)

1. **Inject** a test fixture file containing the expected number of
   failing tests. Use the language-specific template. Place the file
   in the project's test directory under a name ending in `DrillTests`.
2. **Run the test runner.** The expected outcome is the test suite
   fails with the same number of failures as injected.
3. **Run the report renderer.** Verify the JSON summary has the
   `failures_by_class` field populated and the Markdown report has a
   `Failures by class` section.
4. **Run the drift check.** It should report `drift: clean ✅` — the
   drill fixture is in the test directory, not the source directory,
   and so should not introduce drift. If it does, that is a finding
   for the drill report.
5. **Run the pre-commit hook** in dry-run mode. The fixture is
   intentional and should be staged to test the hook. The hook is
   expected to allow the test file (it only inspects the source
   directory), and a subsequent drill injects an undocumented source
   file to verify the hook blocks.
6. **Run the pre-commit hook** with a staged undocumented public
   symbol. The hook should exit non-zero and print a message
   pointing at the knowledge base.
7. **Clean up** the injected fixtures and verify the working tree is
   empty.
8. **Write** the drill evidence document.

## Worked example (Swift)

In a Swift project with the loop already installed:

1. Create `Tests/<Target>Tests/ClosedLoopDrillTests.swift`:

   ```swift
   @Test func drillAssertsWrongValue() {
       #expect(SessionDuration.thirtyMinutes.endDate(from: Date(timeIntervalSince1970: 0))
              == Date(timeIntervalSince1970: 100))
   }
   ```

2. Run `swift test`. Expect red.
3. Run `bash scripts/render_report.sh`. Expect the report to list
   the failing test under `ASSERTION_FAILURE`.
4. Run `bash scripts/check_drift.sh`. Expect `drift: clean`.
5. Stage the test file, run `.githooks/pre-commit`. Expect exit 0
   (test files are not in scope).
6. Create `Sources/<Target>/DrillUndocumentedFixture.swift`, stage it,
   run the hook. Expect exit 1.
7. `rm` the two fixtures, `git reset`, `swift test` — back to green.
8. Write `docs/knowledge/drill-2026-06-02.md`.

## Anti-patterns

- **Leaving the fixture in the working tree.** The drill is supposed
  to be invisible. A leftover fixture corrupts the next commit.
- **Drilling the loop but never reading the report.** The drill
  produces an evidence document for a reason. If the report does not
  contain the expected sections, the loop is broken; the user must
  read the report to find that out.
- **Drilling the same day, twice.** Two drills on the same day
  overwrite each other's evidence document. Wait until tomorrow, or
  pass a custom `drill_label` to disambiguate.

## Cross-references

- [init-loop](../init-loop/SKILL.md) — runs this skill automatically
  on first install.
- [drift-check](../drift-check/SKILL.md) — exercised by step 4 of
  the drill.
- [failure-classify](../failure-classify/SKILL.md) — exercised by
  step 3.
- [report-render](../report-render/SKILL.md) — exercised by step 3.
