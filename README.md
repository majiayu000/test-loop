# test-loop

[![self-check](https://github.com/majiayu000/test-loop/actions/workflows/self-check.yml/badge.svg)](https://github.com/majiayu000/test-loop/actions/workflows/self-check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/majiayu000/test-loop?include_prereleases&label=release)](https://github.com/majiayu000/test-loop/releases)

A small, language-agnostic toolkit for the **closed test loop**:
drift detection, failure classification, structured reports, a pre-commit
guardrail, and a CI workflow you can copy into any project.

> Status: skills and a working script preview. Target projects still need
> their own language globs, test commands, and knowledge-base content. The
> copyable templates and self-check workflow are tracked in
> [docs/knowledge/L0_overview.md](docs/knowledge/L0_overview.md).

## What it is

test-loop does for the test loop what a linter does for syntax: gives you
five points of friction and tells you which one is broken.

| Tool | What it catches | When it runs |
| --- | --- | --- |
| `drift-check` | a public symbol that is not in the knowledge base | pre-commit + CI |
| `failure-classify` | a real assertion failure hiding among expected-failure tests | after `swift test` / `pytest` / `go test` |
| `report-render` | test-log counts, failures, and report status (subject to text-parser limits) | after every test run |
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

## Quick Start

Clone and run the repository self-checks:

```sh
git clone https://github.com/majiayu000/test-loop.git
cd test-loop
bash -n bin/check_drift.sh bin/render_report.sh templates/githooks/pre-commit
python3 bin/classify_failures.py --self-test
python3 scripts/sync_skills.py --check
```

Use the agent-facing contracts:

```text
.agents/skills/              # source of truth
.claude/skills/              # generated Claude Code copy
.codex/skills/               # generated Codex copy
```

Copy the preview templates into a target repository when you are ready to adapt
the loop:

```sh
cp -R bin scripts templates docs/knowledge /path/to/your-project/
```

v0.1.0 does not provide a polished installer yet. Treat `bin/` and `templates/`
as a working preview that still needs project-specific adaptation.

## Generate a report from your test runner

After copying the preview scripts into a target project, run from that project's
root. Install its normal test dependencies first. `render_report.sh` invokes
the selected command and writes `log.txt`, `summary.json`, `classify.json`, and
`report.md` under `docs/reports/<date>/`:

```sh
# Include pytest's passed and failed short-summary entries.
bash bin/render_report.sh --language python --test-command 'python -m pytest -q -rA'

# Include Go's per-test PASS/FAIL lines.
bash bin/render_report.sh --language go --test-command 'go test -v ./...'

# Cargo emits the per-test lines used by the Rust parser.
bash bin/render_report.sh --language rust --test-command 'cargo test --no-fail-fast'
```

The default language is Swift and the default command is
`swift test --parallel`. The checked-in [CI template](templates/github/test.yml)
is a Swift/macOS starting point: adapt its runner, build command, and report
invocation for your target project. Retain its `if: always()` artifact upload
so a failed test run still leaves evidence.

### Why does a passing report show zero tests?

This preview parses text, not JUnit or the test framework's internal results.
Quiet pytest output omits passed-test summary entries; default Go output omits
individual passing tests. Use the explicit commands above, then compare the
raw log, `run_line`, counts, and `exit_code` in `summary.json`. Collection errors,
unsupported log formats, and indented subtests can be missing from the per-test
counts. A zero count is not evidence that the suite passed or ran nothing.
See [pytest's summary options](https://docs.pytest.org/en/stable/how-to/output.html#producing-a-detailed-summary-report)
and the [report skill contract](.agents/skills/report-render/SKILL.md).

### Does `EXPECTED_FAILURE` mean I can ignore a failed test?

No. Classification uses the **test name**, not its body or assertion result.
`EXPECTED_FAILURE` describes a test intended to verify rejection; a runner
failure in that test can mean the rejection contract is broken. It is not
pytest's `xfail` status and does not turn a red suite green. Read the raw failure
before deciding what to fix, and use the
[failure-classification skill](.agents/skills/failure-classify/SKILL.md)
and [taxonomy](templates/knowledge/L2_equivalence_classes.md).

### How is the report exit status determined?

When rendering completes, the same status drives the script's exit code,
`summary.json.exit_code`, and the Markdown PASS/FAIL verdict:

- A live run preserves any nonzero exit code from the test command, even if
  the log contains no recognized failures.
- If the test command exits zero but the parser finds failed tests, the
  report status becomes `1`. Otherwise it remains `0`.
- `--collect` starts from `0` and sets the report status to `1` when the
  parser finds failed tests.

`--collect` only renders the existing date-based `log.txt`; it does not rerun
tests or recover the original command's exit status. A collect-only `0` means
no failures were recognized, not that the original command succeeded or that
tests ran. Retain the original runner result alongside the report for CI.

Unsupported `--language` values and a missing collect log exit `2` before
rendering. With a supported language, an unrecognized summary instead uses
`(no summary line found)`; that fallback alone does not make the report fail.

## Relationship to other projects

| Project | Relationship |
| --- | --- |
| `aitest-kit` | A deeper, Python-specific toolchain that *compiles* Markdown test designs into pytest code. test-loop is the lighter sibling: no codegen, no module profile, no emitter. No public repository link is currently available. |
| [caff](https://github.com/majiayu000/caff) | A macOS menu bar app where this loop was first built out end-to-end. caff 0.1.4 ships the loop in its own `scripts/`, `docs/knowledge/`, `.githooks/`, and `.github/workflows/`. test-loop generalises what caff proved. |

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

## Why test-loop and not X

A short positioning note for the most likely alternatives.

**`test-loop` vs. `aitest-kit`.** aitest-kit is a deeper, Python-specific
toolchain that *compiles* Markdown test designs into pytest code. If your
project is Python and you want AI-generated test code from prose, use
aitest-kit. If your project is in Swift, Go, Rust, TypeScript, or any
other language and you want a thin loop around whatever test runner
you already have, use test-loop. They do not overlap.

**`test-loop` vs. a linter (ESLint, RuboCop, swift-format, …).** A linter
checks one file at a time against a static rule. test-loop is a loop
across at least five moving parts: source, tests, the test runner, the
report, and CI. A linter would not have caught the
[2026-06-02 caff drill](https://github.com/majiayu000/caff) regression,
where the failure classifier was double-counting tests. test-loop did.

**`test-loop` vs. a coverage tool (codecov, llvm-cov, …).** Coverage
answers "which lines are exercised?" It does not answer "did the test
that is supposed to verify this contract actually run?" `drill` is the
test-loop tool that answers the second question.

**`test-loop` vs. hand-rolled `scripts/` in one project.** Every
mid-size repo eventually grows a `scripts/` directory with
`check_drift.sh`, `classify_failures.py`, `render_report.sh`, and a
pre-commit hook that calls the first one. test-loop is the version of
that pattern that you copy once and reuse, with the five pieces
kept in lock-step across Claude Code, Codex, and generic agents.

**`test-loop` vs. a test framework (Swift Testing, pytest, go test, …).**
test-loop does not implement a test framework. The report script invokes
your selected runner and inspects its output; the other tools inspect the
surrounding source, documentation, and workflow. Use the framework for the
tests and test-loop for the loop.

## Roadmap

test-loop is shipped in three increments. The current release is the
first.

### v0.1 — contract + script preview (this release)

- Six skills, each with a self-contained `SKILL.md` describing inputs,
  outputs, algorithms, and worked examples.
- Three copy destinations (`.claude/`, `.codex/`, `.agents/`) kept in
  sync from a single agent-neutral source by `scripts/sync_skills.py`.
- A project-level L0 in `docs/knowledge/L0_overview.md` describing the
  loop, the failure-class taxonomy, and the boundaries of the project.
- Preview scripts under `bin/`, copyable hook/CI templates under `templates/`,
  and starter knowledge/spec templates.
- A self-check GitHub Actions workflow that verifies script syntax, the
  classifier self-test, and skill-copy synchronization.

What v0.1 cannot do: it cannot install and fully adapt the loop by itself. The
skills and scripts exist, but target projects still need project-specific
language globs, test commands, and knowledge-base content.

Release notes are tracked in [CHANGELOG.md](CHANGELOG.md).

### v0.2 — generalized scripts

- Generalize the five scripts that already shipped in [caff 0.1.4](https://github.com/majiayu000/caff):
  `check_drift.sh`, `classify_failures.py`, `render_report.sh`,
  `.githooks/pre-commit`, `.github/workflows/test.yml`.
- Add `--language` parameters so the scripts work on Swift, Python, Go,
  and Rust. The caff versions are Swift-only; test-loop versions are
  cross-language.
- Self-test each script. `classify_failures.py` already has ten
  internal unit tests; the others get similar treatment.
- Run a real `drill` on the test-loop repository itself, with the
  evidence in `docs/knowledge/drill-2026-06-XX.md`.
- Expand the self-check workflow into a full dogfood loop.

### v0.3 — adoption

- Point [caff](https://github.com/majiayu000/caff)'s own `scripts/` at
  test-loop's copy, so caff 0.2.0 pulls rather than re-implementing.
  (Optional; caff is the reference project but does not have to be a
  consumer.)
- Add a Homebrew formula, so macOS users can `brew install test-loop`
  and get the loop as a system tool.
- Add an `examples/` directory with one minimal project per supported
  language, each one running its own drill on every commit.

### Out of scope (any version)

- Per-language pattern libraries beyond Swift in v0.2.
- A pluggable plugin system. The five tools are deliberately the five
  tools; adding a sixth needs a separate spec.
- A web UI for the report. The Markdown report is the report.
- An AI auto-fixer. The loop surfaces what is wrong; the user decides.

## License

MIT. See [LICENSE](LICENSE).
