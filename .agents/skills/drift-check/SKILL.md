---
name: drift-check
description: |
  Flag public symbols in the project's source tree that are not documented
  in the project's knowledge base. Use this before committing, in CI, or
  whenever a public API surface changes and you want to know whether the
  knowledge base has gone stale.
metadata:
  type: project
  language: any
  inputs: source directory, knowledge base path
  outputs: exit code 0 (clean) or 1 (drift), plus a list of undocumented symbols
---

# drift-check

Detect drift between the project's **public API surface** and its
**knowledge base** (a `docs/knowledge/` directory that names every public
type and function).

## When to use

- Before committing a change that adds, renames, or removes a public symbol.
- As a CI step that runs after every push.
- After a `git pull` if the upstream changed the public API.

Do **not** use this skill to scan private internals, generated code, or
third-party dependencies. Its job is to keep the human-readable
knowledge base honest about the public surface.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `source_glob` | yes | none | Glob for the source files to scan, e.g. `Sources/CaffCore/*.swift` or `src/**/*.py`. |
| `knowledge_base` | yes | none | Path to a Markdown directory, usually `docs/knowledge/`. The skill extracts identifier tokens from every file under it. |
| `baseline` | no | none | Optional file with one identifier per line, listing symbols intentionally left undocumented. Add an entry here only after a human has confirmed it is genuinely not worth a knowledge-base entry. |
| `scope` | no | `all` | `all` scans every file matching `source_glob`. `changed` scans only files in `git diff` (staged + unstaged + untracked-but-staged). |

## Output

| Channel | Content |
| --- | --- |
| stdout | One line per undocumented symbol in the form `<relative_path>:<Symbol>`. |
| exit code | `0` = every public symbol in scope is either in the knowledge base or in the baseline. `1` = at least one symbol is missing. `2` = the input was malformed (e.g. the knowledge base path does not exist). |
| stderr | Summary line, then a hint pointing at where to fix the drift. |

## What counts as a public symbol

The skill uses a coarse regex; the precise rules are language-specific:

| Language | Public surface is |
| --- | --- |
| Swift | `public struct`, `public class`, `public enum`, `public protocol`, `public func`, `public static func`, `public init` |
| Python | `def` and `class` not prefixed with `_` at module top level; `__all__` if present |
| Go | identifiers in `package ...` that start with an uppercase letter |
| Rust | `pub struct`, `pub fn`, `pub enum`, `pub trait`, `pub use` re-exports |
| TypeScript | `export function`, `export class`, `export interface`, `export type` |

The skill is deliberately not a full parser. It trades false positives
for a small, predictable rule set. If the regex does not match a
deliberate public symbol, add it to `baseline` rather than fight the
regex.

## Algorithm (in three steps)

1. **Extract** public symbol names from the source tree using the
   language-specific regex.
2. **Tokenise** every file under `knowledge_base` into identifier-like
   tokens (alphanumerics and underscores).
3. **Diff** the symbol set against `(knowledge base tokens ∪ baseline)`.
   Any symbol not present is drift.

## Worked example (Swift)

Suppose `Sources/CaffCore/SafetyPolicy.swift` adds:

```swift
public struct SafetyPolicy {
    public func someNewMethod() { ... }
}
```

`docs/knowledge/L1_modules.md` does not mention `someNewMethod`.

Running `drift-check` with `source_glob=Sources/CaffCore/*.swift` and
`knowledge_base=docs/knowledge/` produces:

```
scanned 24 public symbol(s) across 9 file(s)
drift: 1 public symbol(s) not in L1_modules.md or baseline:
  - Sources/CaffCore/SafetyPolicy.swift:someNewMethod
```

The fix is to add `someNewMethod` to the L1 modules document. If it is
genuinely not worth a knowledge-base entry, add `someNewMethod` to the
baseline file.

## Anti-patterns

- **Running the skill on generated code.** Generated code can change
  with every build, and its public surface is the generator's contract,
  not the project's. Exclude it from `source_glob`.
- **Adding every internal helper to the baseline.** The baseline is for
  symbols intentionally left out of the knowledge base, not for skipping
  the work. Use the knowledge base.
- **Treating drift warnings as a code review substitute.** The skill
  tells you the knowledge base is stale. It does not tell you whether
  the new symbol is well-designed.

## Cross-references

- [failure-classify](../failure-classify/SKILL.md) — the next step in
  the loop. drift-check runs before the test, failure-classify runs
  after.
- [init-loop](../init-loop/SKILL.md) — installs the script that this
  skill describes into a fresh project.
- [drill](../drill/SKILL.md) — verifies that this skill actually
  reacts to a deliberately drifted commit.
