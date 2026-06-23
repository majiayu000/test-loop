# Closed Test Loop Spec

## Goal

Keep source changes, knowledge-base documentation, test execution, reports, and
CI feedback aligned.

## Loop Components

- Drift check
- Failure classification
- Report rendering
- Pre-commit guardrail
- CI workflow
- Drill

## Done When

- The project can run its normal test command.
- The loop can classify failures.
- The loop can render a report.
- A drill proves at least one injected failure is detected.

