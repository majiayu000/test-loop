---
name: test-loop-bootstrap
description: |
  Meta-skill: choose which of the other five test-loop skills to invoke
  first, based on the user's description of the current state of their
  project. Use when a user says something like "I want to add tests to
  this project" or "this project has no CI" and the right entry point
  is not obvious.
metadata:
  type: meta
  language: any
  inputs: user's free-form description of project state
  outputs: a single next-skill recommendation
---

# test-loop-bootstrap

Pick the right next skill. The five other skills are pieces of one
loop; this skill is the door.

## When to use

When a user asks for help with testing, CI, or quality on a project
and it is not obvious which of the five concrete skills to start with.

If you already know the user wants, say, drift detection, call
[drift-check](../drift-check/SKILL.md) directly. Do not use this
meta-skill as an indirection layer.

## Inputs

A free-form description of where the project is now. Examples:

- "I just started a new Swift project and I want to set up testing."
- "I have a Python project that already has pytest but no CI."
- "My existing tests pass but I don't trust them — I want to know they
  actually run."
- "Someone added a public function and I want to know if it broke
  anything."

## Decision tree

```
Q1: Does the project have at least one of:
    - a pre-commit hook calling scripts/check_drift.sh
    - a CI workflow calling swift test / pytest / etc.
    - a docs/knowledge/ directory
    --> If no:        start with [init-loop]
    --> If yes:       continue to Q2

Q2: Did something just change in the public API (a new struct, function,
    class, or trait)?
    --> If yes:       run [drift-check] now
    --> If no:       continue to Q3

Q3: Did the test suite just run, and did it produce at least one
    failure?
    --> If yes:       run [failure-classify], then [report-render]
    --> If no:       continue to Q4

Q4: Have you (or anyone on the team) edited the loop tools
    (scripts/*.sh, scripts/*.py, .githooks/*, .github/workflows/*)
    in the last week?
    --> If yes:       run [drill] to verify the loop still reacts
    --> If no:       continue to Q5

Q5: When is the last time [drill] was run?
    --> > 30 days:    run [drill] as a regression check
    --> <= 30 days:   stop. The loop is healthy. No skill needed.
```

## Output

One of:

- `[init-loop]`
- `[drift-check]`
- `[failure-classify] + [report-render]`
- `[drill]`
- "no skill needed; the loop is healthy"

In addition, the skill should briefly state *why* it chose what it
chose, so the user can override.

## Anti-patterns

- **Routing every request through this skill.** If the user already
  named a skill, call it. This skill is for undecided situations.
- **Adding more branches to the decision tree.** The five Q&As
  already cover the realistic states. Adding a sixth tends to
  increase router complexity without improving routing accuracy.
- **Recommending [drill] on a project that does not yet have the
  loop.** The drill requires the loop to be installed. If the answer
  to Q1 is "no", go to [init-loop] first.

## Cross-references

- [init-loop](../init-loop/SKILL.md)
- [drift-check](../drift-check/SKILL.md)
- [failure-classify](../failure-classify/SKILL.md)
- [report-render](../report-render/SKILL.md)
- [drill](../drill/SKILL.md)
