#!/usr/bin/env python3
"""
sync_skills.py — copy .agents/skills/<name>/SKILL.md into
.claude/skills/<name>/SKILL.md and .codex/skills/<name>/SKILL.md.

Run from the test-loop project root:

    python3 scripts/sync_skills.py

Why: the agent-neutral skills/ tree is the single source of truth.
.claude/ and .codex/ directories are generated; never edit them by
hand. Re-run after editing anything under .agents/skills/.

This script is also the only place where the rule "do not maintain
three copies" is enforced. If you find yourself hand-editing a file
under .claude/skills/ or .codex/skills/, delete that file and re-run
this script instead.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "--root",
        default=".",
        help="Path to the test-loop project root (default: current dir).",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if any .claude/ or .codex/ SKILL.md is out of sync.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not (root / ".agents/skills").is_dir():
        print(f"error: {root / '.agents/skills'} not found", file=sys.stderr)
        return 2

    targets = [".claude/skills", ".codex/skills"]
    skill_names = sorted(
        p.parent.name for p in root.glob(".agents/skills/*/SKILL.md")
    )

    if not skill_names:
        print("error: no .agents/skills/*/SKILL.md found", file=sys.stderr)
        return 2

    mismatches: list[str] = []
    for name in skill_names:
        src = root / ".agents/skills" / name / "SKILL.md"
        body = src.read_bytes()
        for target_rel in targets:
            dst = root / target_rel / name / "SKILL.md"
            existing = dst.read_bytes() if dst.exists() else None
            if existing != body:
                if args.check:
                    mismatches.append(str(dst.relative_to(root)))
                else:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(body)
                    print(f"wrote {dst.relative_to(root)}")

    if args.check:
        if mismatches:
            print(
                f"{len(mismatches)} SKILL.md out of sync:",
                file=sys.stderr,
            )
            for m in mismatches:
                print(f"  {m}", file=sys.stderr)
            return 1
        print(f"all {len(skill_names)} skills in sync across {len(targets)} targets")
        return 0

    print(f"synced {len(skill_names)} skill(s) to {len(targets)} target(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
