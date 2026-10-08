# L0 — test-loop system overview

## Purpose

test-loop packages a small set of **language-agnostic** tools that close
the loop between source code, test code, and CI for any project. It is
not a test framework, not a coverage tool, and not a code generator.

The loop answers five questions:

1. Has a public symbol been added that is not in the knowledge base?
   → `drift-check`
2. Did a test fail, and is it a real failure or an expected one?
   → `failure-classify`
3. Can a human read what just ran?
   → `report-render`
4. Does the project have any of the above wired up?
   → `init-loop`
5. If yes, do the tools actually react when something breaks?
   → `drill`

## What is in scope for v0.1

| Tool | v0.1 status | Language coverage |
| --- | --- | --- |
| `drift-check` skill | written; script preview available | Coarse Swift, Python, Go, and Rust symbol extraction; adapt source globs and the knowledge base to the target project. |
| `failure-classify` skill | written; script preview available | Swift Testing, pytest, go test, and cargo test log patterns; classification is based on test names. |
| `report-render` skill | written; script preview available | Swift, Python, Go, and Rust text-log parsing, with runner-specific counts and summaries. |
| `init-loop` skill | written | Decision tree plus a copy list; current hook and Swift/macOS CI templates require project-specific adaptation. |
| `drill` skill | written | Procedure, not a script. |
| `test-loop-bootstrap` skill | written | Pure routing. |
| Underlying scripts | **working preview in `bin/`** | Drift checking, failure classification, and report rendering are available, alongside copyable templates and a self-check workflow. There is no polished installer. |

Report status preserves a nonzero live command exit code and changes a zero
status to `1` when failures are parsed. Collect mode derives `0` or `1` from
the log and cannot recover the original command status. Zero counts or a
PASS report do not prove tests ran; see the
[report contract](../../.agents/skills/report-render/SKILL.md#exit-status-and-verdict).

## Why v0.1 ships contracts alongside a script preview

Skills are **contracts**. Scripts are **implementations**. Pinning the
contract first means:

- A user can read a `SKILL.md` and decide whether the loop fits.
- Future maintainers (or other agents) can reimplement the same skill
  in a different language without changing the user-facing shape.
- The drill from caff on 2026-06-02 has already exercised the same
  five tools; the v0.1 skills reflect what was learned there.

## The five-tool loop

```
                       init-loop
                          |
                          v
   +--------------------------------------------------+
   |  pre-commit  --drift-check-->  drift: clean ✅   |
   |                              |                  |
   |                              v                  |
   |                       swift test / pytest       |
   |                              |                  |
   |                              v                  |
   |                  failure-classify               |
   |                              |                  |
   |                              v                  |
   |                  report-render                  |
   |                              |                  |
   |                              v                  |
   |                       docs/reports/             |
   +--------------------------------------------------+
                          |
                          v
                       drill
            (verify the loop reacts)
```

## Failure classification taxonomy (v0.1 contract)

The seven-class taxonomy follows [aitest-kit's failure-class
model](../caff/docs/knowledge/drill-2026-06-02.md) and adapts it to
runner output:

| Class | Meaning | Trigger keyword examples |
| --- | --- | --- |
| `EXPECTED_FAILURE` | the test verifies the system rejects something | `Reject`, `Refuse`, `ErrorContains`, `WithInvalid`, `DataCorrupted` |
| `IO_BACKEND` | the test exercises a system API (IOKit, libusb, ...) | `powerAssertion*`, `usb*`, `disk*` |
| `ENVIRONMENT_ERROR` | the test depends on a live system reading | `PowerSourceMonitor`, `BluetoothState`, `NetworkLink` |
| `TEST_SCAFFOLD` | the test depends on a missing setup artifact | rare; reserved for explicit markers |
| `ASSERTION_FAILURE` | real bug | default bucket |
| `PRECONDITION_MISSING` | required env var / file is missing | `requireEnv` markers |
| `UNKNOWN` | could not classify | fallback |

`failure-classify` falls through to `ASSERTION_FAILURE` for any test
whose name does not match a pattern, by design. Better to make a real
regression loud than to hide it in `UNKNOWN`.

## Out of scope (v0.1)

- No polished installer or CLI that adapts the loop automatically.
- No fully generalized per-language pattern library beyond the current preview.
- No automatic `init-loop` generator; agents copy and adapt templates manually.
- No GitHub Action published under the marketplace.

## Reference projects

- [caff 0.1.4](https://github.com/majiayu000/caff) — first end-to-end
  deployment of this loop on a Swift macOS app.
- [aitest-kit](https://github.com/majiayu000/aitest-kit) — the deeper
  Python pytest sibling that this loop was distilled from.
