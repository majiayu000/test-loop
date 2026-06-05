#!/usr/bin/env python3
"""
classify_failures.py — categorize failing tests by naming convention.

Borrowed from aitest-kit's failure-class taxonomy but adapted to Swift
Testing's naming style. The classifier is rule-based on the test name:
it does not read the test body. That keeps it deterministic and cheap,
at the cost of misclassifying a few cases. The trade-off is documented
in docs/knowledge/L2_equivalence_classes.md.

Usage:
    classify_failures.py <log_file>        # print JSON to stdout
    classify_failures.py --in <log> --out <json>
    classify_failures.py --self-test       # run unit tests and exit

The seven-class taxonomy (matches aitest-kit where possible):
    EXPECTED_FAILURE    — test verifies the function rejects something;
                          failure here means a guard went missing.
    ASSERTION_FAILURE   — the real failure; the function under test did
                          the wrong thing.
    TEST_SCAFFOLD       — fixture/setup/teardown is broken.
    ENVIRONMENT_ERROR   — the test depends on a missing system resource.
    PRECONDITION_MISSING — a required env var / file is missing.
    IO_BACKEND          — failure traced to the IOKit backend.
    UNKNOWN             — fallback.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unittest
from collections import Counter
from typing import Iterable

# Order matters: more specific patterns first.
PATTERNS: dict[str, list[tuple[str, re.Pattern[str]]]] = {
    "swift": [
        # EXPECTED_FAILURE: the test is verifying the system rejects something.
        (
            "EXPECTED_FAILURE",
            re.compile(
                r"("
                r"Reject(s|ing|ed)?"
                r"|Refus(e|ing|ed)"
                r"|ErrorContains"
                r"|WithInvalid"
                r"|NonNumeric"
                r"|DataCorrupted"
                r"|InvalidDuration|InvalidSource|InvalidCooldown|InvalidJSON|UnsupportedRoot"
                r"|LongSessionOnBattery"
                r"|Rejects?Unrecognized|RejectsUnknown"
                r")"
            ),
        ),
        # ENVIRONMENT_ERROR: known to depend on a live system reading.
        (
            "ENVIRONMENT_ERROR",
            re.compile(
                r"("
                r"PowerSourceMonitor"
                r")"
            ),
        ),
        # IO_BACKEND: real IOKit.
        (
            "IO_BACKEND",
            re.compile(
                r"("
                r"^powerAssertion(Start|Stop|IsIdempotent|Lifecycle|Inactive|AssertionsAppear)"
                r")"
            ),
        ),
    ],
    "python": [
        # pytest: `test_foo` is conventional, but the failing test name
        # is preceded by "FAILED " in the short summary and "____ test_foo ____"
        # in the verbose summary. The class is `TestError` / `TestInvalid` /
        # `TestRejects` etc.; we match on those substrings after `Test`.
        (
            "EXPECTED_FAILURE",
            re.compile(
                r"(Rejects?|Refus(es|ing|ed)?|Invalid|ErrorContains|DataCorrupted"
                r"|With[A-Z][a-z]+|TestError|TestInvalid|TestReject)",
                re.IGNORECASE,
            ),
        ),
    ],
    "go": [
        # go test prints FAIL lines like:
        #   --- FAIL: TestFoo (0.00s)
        # Test functions are TestXxx. We only mark a test EXPECTED_FAILURE
        # when its name explicitly indicates a negative-path test.
        (
            "EXPECTED_FAILURE",
            re.compile(
                r"(TestReject|TestRefuse|TestInvalid|TestErrorContains"
                r"|TestNegative|TestBadInput|TestMalformed)",
            ),
        ),
    ],
    "rust": [
        # cargo test prints failures as:
        #   test test_foo ... FAILED
        # plus a `failures:` section. The test name itself has no convention
        # for negative tests, so we fall through to the default bucket
        # unless the test name explicitly mentions rejection.
        (
            "EXPECTED_FAILURE",
            re.compile(
                r"(rejects|rejects_|refuses|invalid_input|error_contains"
                r"|with_invalid|with_malformed)",
                re.IGNORECASE,
            ),
        ),
    ],
}


# Per-language regex for extracting a failing test name from a log line.
# Group 1 is the test name. Each pattern is anchored to the start of a line
# (use re.MULTILINE when matching).
EXTRACT_PATTERNS: dict[str, re.Pattern[str]] = {
    "swift": re.compile(
        r"^✘\s+Test\s+([^(]+?)\s*\(",
        re.MULTILINE,
    ),
    "python": re.compile(
        r"^FAILED\s+\S*::?([A-Za-z_][A-Za-z0-9_]*)",  # pytest short summary
        re.MULTILINE,
    ),
    "go": re.compile(
        r"^---\s+FAIL:\s+(\w+)",  # go test verbose
        re.MULTILINE,
    ),
    "rust": re.compile(
        r"^test\s+(\S+)\s+\.\.\.\s+FAILED",  # cargo test per-test
        re.MULTILINE,
    ),
}

DEFAULT_CLASS = "ASSERTION_FAILURE"
FALLBACK_CLASS = "UNKNOWN"


def extract_failing_names(log_text: str, language: str = "swift") -> list[str]:
    """Pull failing test names out of a test log, deduplicated.

    Swift Testing may emit two ✘ lines per failing test (one for the
    recorded issue, one for the failure summary). We dedupe while keeping
    the first-seen order so callers see one entry per failing test.

    The line shape depends on the runner; see EXTRACT_PATTERNS.
    """
    rx = EXTRACT_PATTERNS.get(language)
    if rx is None:
        raise ValueError(f"unsupported language: {language!r}")
    seen: dict[str, None] = {}
    for m in rx.finditer(log_text):
        name = m.group(1).strip()
        if name and name not in seen:
            seen[name] = None
    return list(seen.keys())


def classify(name: str, language: str = "swift") -> str:
    patterns = PATTERNS.get(language, [])
    for label, rx in patterns:
        if rx.search(name):
            return label
    return DEFAULT_CLASS


def classify_all(names: Iterable[str], language: str = "swift") -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for n in names:
        out.setdefault(classify(n, language), []).append(n)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("log_pos", nargs="?", help="Log file path (positional)")
    parser.add_argument("--in", dest="log", help="Log file path")
    parser.add_argument(
        "--out",
        help="Output JSON file (default: stdout)",
    )
    parser.add_argument(
        "--language",
        default="swift",
        choices=["swift", "python", "go", "rust", "auto"],
        help="Test runner language (default: swift).",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run internal unit tests and exit",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        runner = unittest.TextTestRunner(verbosity=2)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestClassifier)
        result = runner.run(suite)
        return 0 if result.wasSuccessful() else 1

    log_path = args.log or args.log_pos
    if not log_path:
        print("error: log file required", file=sys.stderr)
        return 2

    with open(log_path, "r", encoding="utf-8") as f:
        log_text = f.read()

    names = extract_failing_names(log_text, language=args.language)
    grouped = classify_all(names, language=args.language)
    counts = Counter({label: len(items) for label, items in grouped.items()})

    payload = {
        "failures": names,
        "failures_by_class": dict(counts),
        "failures_grouped": grouped,
    }

    encoded = json.dumps(payload, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(encoded)
            f.write("\n")
    else:
        print(encoded)
    return 0


class TestClassifier(unittest.TestCase):
    def test_extracts_names(self) -> None:
        log = """
✔ Test a() passed after 0.001 seconds.
✘ Test foo() failed after 0.002 seconds with 1 issue.
✘ Test bar() recorded an issue at Path.swift:10:5: ...
"""
        self.assertEqual(
            extract_failing_names(log),
            ["foo", "bar"],
        )

    def test_extracts_names_dedupes_duplicate_failure_lines(self) -> None:
        # swift test may print two ✘ lines per failing test:
        #   ✘ Test foo() recorded an issue at ...
        #   ✘ Test foo() failed after ... with 1 issue.
        # We want exactly one entry per failing test, first-seen wins.
        log = """
✘ Test foo() recorded an issue at Path.swift:1:1: ...
✘ Test foo() failed after 0.001 seconds with 1 issue.
✘ Test bar() recorded an issue at Path.swift:2:2: ...
✘ Test bar() failed after 0.001 seconds with 1 issue.
"""
        self.assertEqual(
            extract_failing_names(log),
            ["foo", "bar"],
        )

    def test_extracts_names_preserves_order_across_duplicates(self) -> None:
        log = """
✘ Test z() recorded an issue at ...
✘ Test a() failed after ... with 1 issue.
✘ Test z() failed after ... with 1 issue.
"""
        # First-seen order: z, a (z's duplicate is dropped).
        self.assertEqual(
            extract_failing_names(log),
            ["z", "a"],
        )

    def test_classify_expected_failure_rejects(self) -> None:
        self.assertEqual(
            classify("remoteControlDurationRejectsZero"),
            "EXPECTED_FAILURE",
        )
        self.assertEqual(
            classify("sessionHistoryRejectsUnknownResult"),
            "EXPECTED_FAILURE",
        )
        self.assertEqual(
            classify("remoteControlSourceWithInvalidValue"),
            "EXPECTED_FAILURE",
        )

    def test_classify_expected_failure_error_keys(self) -> None:
        for n in [
            "agentHookManagerReturnsInvalidJSON",
            "agentHookManagerReturnsUnsupportedRoot",
            "remoteControlDurationInvalidDuration",
            "safetyPolicyLongSessionOnBattery",
        ]:
            self.assertEqual(
                classify(n),
                "EXPECTED_FAILURE",
                msg=f"expected EXPECTED_FAILURE for {n!r}",
            )

    def test_classify_scaffold(self) -> None:
        # AgentHookManager test names default to ASSERTION_FAILURE because
        # most of them are behavior tests, not setup tests. We document this
        # rather than carve out a TEST_SCAFFOLD bucket that would be too
        # broad and would hide real regressions.
        self.assertEqual(
            classify("agentHookManagerInstallsAndRemovesHooks"),
            "ASSERTION_FAILURE",
        )

    def test_classify_io_backend(self) -> None:
        for n in [
            "powerAssertionLifecycle",
            "powerAssertionIsIdempotentAcrossRepeatedStarts",
            "powerAssertionStartWithoutDisplaySleepOnlyAcquiresIdleAssertion",
            "powerAssertionInactiveStateHasEmptyActiveAssertions",
        ]:
            self.assertEqual(
                classify(n),
                "IO_BACKEND",
                msg=f"expected IO_BACKEND for {n!r}",
            )

    def test_classify_default(self) -> None:
        # A safety policy happy-path test name should NOT match any pattern
        # other than the default ASSERTION_FAILURE.
        self.assertEqual(
            classify("safetyPolicyAtBatteryThresholdEdgeAccepts59Minutes"),
            "ASSERTION_FAILURE",
        )

    def test_classify_all(self) -> None:
        names = [
            "remoteControlDurationRejectsZero",
            "powerAssertionLifecycle",
            "agentHookManagerInstallsAndRemovesHooks",
            "safetyPolicySomeTest",
        ]
        grouped = classify_all(names)
        self.assertIn("EXPECTED_FAILURE", grouped)
        self.assertIn("IO_BACKEND", grouped)
        self.assertIn("ASSERTION_FAILURE", grouped)
        # AgentHookManager behavior test is now ASSERTION_FAILURE, not
        # a separate scaffold bucket.
        self.assertIn("agentHookManagerInstallsAndRemovesHooks",
                      grouped["ASSERTION_FAILURE"])

    def test_extracts_python_pytest_short_summary(self) -> None:
        log = """
============================= test session starts ==============================
collected 3 items

test_module.py F                                                          [ 33%]
test_module.py F.                                                         [ 66%]
test_module.py F                                                          [100%]

=========================== short test summary info ============================
FAILED test_module.py::test_rejects_invalid_input
FAILED test_module.py::test_handles_missing_data
FAILED test_module.py::test_rejects_invalid_input
"""
        names = extract_failing_names(log, language="python")
        # pytest short summary duplicates per test if a test is re-run;
        # we still dedupe.
        self.assertEqual(
            names,
            ["test_rejects_invalid_input", "test_handles_missing_data"],
        )

    def test_classify_python_routes_expected_failure(self) -> None:
        self.assertEqual(
            classify("test_rejects_invalid_input", language="python"),
            "EXPECTED_FAILURE",
        )
        self.assertEqual(
            classify("test_happy_path", language="python"),
            "ASSERTION_FAILURE",
        )

    def test_extracts_go_test_verbose(self) -> None:
        log = """
=== RUN   TestFoo
--- PASS: TestFoo (0.00s)
=== RUN   TestRejectsEmpty
--- FAIL: TestRejectsEmpty (0.00s)
    foo_test.go:42: should have rejected empty input
=== RUN   TestBar
--- FAIL: TestBar (0.00s)
    bar_test.go:12: wrong result
"""
        names = extract_failing_names(log, language="go")
        self.assertEqual(names, ["TestRejectsEmpty", "TestBar"])

    def test_extracts_rust_cargo_test(self) -> None:
        log = """
running 3 tests
test test_rejects_empty ... FAILED
test test_happy_path ... ok
test test_with_invalid_input ... FAILED

test result: FAILED. 2 passed; 2 failed; 0 ignored
"""
        names = extract_failing_names(log, language="rust")
        self.assertEqual(
            names,
            ["test_rejects_empty", "test_with_invalid_input"],
        )

    def test_payload_counts_each_failure(self) -> None:
        names = [
            "remoteControlDurationRejectsZero",
            "remoteControlDurationRejectsNegative",
            "powerAssertionLifecycle",
        ]
        grouped = classify_all(names)
        counts = Counter({label: len(items) for label, items in grouped.items()})
        self.assertEqual(counts["EXPECTED_FAILURE"], 2)
        self.assertEqual(counts["IO_BACKEND"], 1)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
