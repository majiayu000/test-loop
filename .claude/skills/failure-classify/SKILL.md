---
name: failure-classify
description: |
  Group failing tests by naming convention so a real assertion failure is
  not hidden among tests that exist to verify a system rejects something.
  Use after running the test suite and before reading the report.
metadata:
  type: project
  language: any
  inputs: test runner log path, optional language pattern
  outputs: failures_by_class counts, failures_grouped listing, exit code
---

# failure-classify

Triage failing tests so a real regression does not get lost among
tests that are *expected* to fail (because they verify that the system
rejects bad input).

## When to use

- After every test run that produced at least one failing test.
- Before triaging a CI failure manually.
- In the report-render skill's input pipeline.

Do **not** use this skill to decide whether a regression is "important
enough to fix". That is a human judgement. The skill only sorts.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `log_path` | yes | none | Path to the test runner's output. The skill scans for `✘` lines (or `FAIL` lines, depending on the language pattern). |
| `language` | no | `swift` | One of `swift`, `python`, `go`, `rust`. Picks the line-extraction regex and the classification patterns. |
| `self_test` | no | `false` | When `true`, runs the skill's internal unit tests and exits. Use after editing the classification rules. |

## Output

| Channel | Content |
| --- | --- |
| stdout | A JSON object with three keys: `failures` (deduplicated list of failing test names), `failures_by_class` (counts per class), `failures_grouped` (test names bucketed by class). |
| exit code | `0` on success regardless of test outcomes. `1` if the log could not be read. `2` on self-test failure. |

## Classification taxonomy

Seven classes. Order matters: the first matching pattern wins. A test
name that matches no pattern falls into `ASSERTION_FAILURE` by default.

| Class | Meaning | Trigger keyword (regex fragment) |
| --- | --- | --- |
| `EXPECTED_FAILURE` | the test verifies the system rejects something | `Reject`, `Refuse`, `ErrorContains`, `WithInvalid`, `DataCorrupted`, `InvalidDuration`, `LongSessionOnBattery` |
| `IO_BACKEND` | the test exercises a system API (IOKit, libusb, raw sockets) | language-specific prefix, e.g. `powerAssertion*` in Swift |
| `ENVIRONMENT_ERROR` | the test depends on a live system reading | `PowerSourceMonitor`, `BluetoothState`, `NetworkLink` |
| `TEST_SCAFFOLD` | the test depends on a missing setup artifact | reserved; no patterns in v0.1 |
| `ASSERTION_FAILURE` | real bug | default bucket |
| `PRECONDITION_MISSING` | required env var / file is missing | `requireEnv`, `skipIf` markers |
| `UNKNOWN` | could not classify | fallback (rare; usually means the runner produced an unexpected line format) |

## Algorithm

1. **Extract** failing test names from the log. Swift Testing emits two
   `✘` lines per failing test (one for the issue, one for the
   summary). The skill deduplicates while keeping the first-seen order.
2. **Classify** each name against the patterns, first-match-wins.
3. **Emit** JSON: list, counts, grouped.

## Worked example (Swift)

Log:
```
✔ Test foo() passed after 0.001 seconds.
✘ Test barRejectsZero() failed after 0.001 seconds with 1 issue.
✘ Test bazShouldBehave() failed after 0.001 seconds with 1 issue.
```

Output:
```json
{
  "failures": ["barRejectsZero", "bazShouldBehave"],
  "failures_by_class": {
    "EXPECTED_FAILURE": 1,
    "ASSERTION_FAILURE": 1
  },
  "failures_grouped": {
    "EXPECTED_FAILURE": ["barRejectsZero"],
    "ASSERTION_FAILURE": ["bazShouldBehave"]
  }
}
```

The first test is an expected-failure pattern (`Rejects`). The second
is a real regression candidate.

## Anti-patterns

- **Treating `EXPECTED_FAILURE` as a green light.** A failure classified
  as `EXPECTED_FAILURE` still failed. The classification only means the
  failure is the test's *purpose*, not that the system under test
  behaves correctly. The test author must read the message.
- **Adding patterns that match everything.** Patterns are first-match
  wins. A pattern like `.*` would swallow every test into one bucket.
- **Assuming a runner that is not in the language list still works.**
  The v0.1 patterns cover Swift Testing only. For other runners, the
  user must extend the patterns and add a self-test.

## Cross-references

- [report-render](../report-render/SKILL.md) — consumes the JSON
  output and embeds it in the Markdown report.
- [drill](../drill/SKILL.md) — uses this skill to verify the loop
  reacts to a real failure.
- [drift-check](../drift-check/SKILL.md) — the previous step in the
  loop.
