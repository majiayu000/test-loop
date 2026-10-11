#!/usr/bin/env python3
"""Replay supported text formats without installing or running test frameworks."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DAY = subprocess.check_output(["date", "+%Y-%m-%d"], text=True).strip()
# The same existing per-test protocols as the classifier/report self-checks.
CASES = {
    "python": (
        "FAILED test_sample.py::test_rejects_empty - assert False\n"
        "FAILED test_sample.py::test_answer - assert 4 == 5\n"
        "2 failed in 0.12s\n",
        ["test_sample.py::test_rejects_empty", "test_sample.py::test_answer"],
        "PASSED test_sample.py::test_answer\n1 passed in 0.12s\n",
    ),
    "go": (
        "--- FAIL: TestRejectsEmpty (0.00s)\n--- FAIL: TestHelloName (0.00s)\n"
        "FAIL    example.com/greetings   0.182s\n",
        ["TestRejectsEmpty", "TestHelloName"],
        "--- PASS: TestHelloName (0.00s)\nok    example.com/greetings   0.182s\n",
    ),
    "rust": (
        "test test_rejects_empty ... FAILED\ntest tests::another ... FAILED\n"
        "test result: FAILED. 0 passed; 2 failed; 0 ignored\n",
        ["test_rejects_empty", "tests::another"],
        "test tests::another ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored\n",
    ),
    "swift": (
        "✘ Test valueRejectsEmpty() failed after 0.001 seconds with 1 issue.\n"
        "✘ Test example() failed after 0.001 seconds with 1 issue.\n",
        ["valueRejectsEmpty", "example"],
        "✔ Test example() passed after 0.001 seconds.\n"
        "✔ Test run with 1 test passed after 0.001 seconds.\n",
    ),
}


def variants(text):
    whole = "".join("\x1b[31m" + line + "\x1b[0m\n" for line in text.splitlines())
    tokens = re.sub(r"FAILED|FAIL|✘|✔|Test|test|[0-9]+",
                    lambda m: "\x1b[1;31m" + m[0] + "\x1b[0m", text)
    return (text, text.replace("\n", "\r\n"), whole, tokens,
            tokens.replace("\n", "\r\n"))


def render(sandbox, language, raw, process_exit=None, degraded=False):
    sandbox.mkdir()
    shutil.copytree(ROOT / "bin", sandbox / "bin")
    if degraded:
        (sandbox / "bin/classify_failures.py").unlink()
    reports = sandbox / "docs/reports" / DAY
    reports.mkdir(parents=True)
    if process_exit is None:
        (reports / "log.txt").write_bytes(raw)
        extra = ["--collect"]
    else:
        (sandbox / "input.log").write_bytes(raw)
        extra = ["--test-command", f"cat input.log; exit {process_exit}"]
    temp = sandbox / "tmp"
    temp.mkdir()
    import os
    env = dict(os.environ, TMPDIR=str(temp))
    result = subprocess.run(
        ["bash", str(sandbox / "bin/render_report.sh"), "--language", language, *extra],
        capture_output=True, env=env, check=False,
    )
    summary = json.loads((reports / "summary.json").read_text())
    report = (reports / "report.md").read_text()
    names = re.findall(r"^- `([^`]+)`$", report, re.MULTILINE)
    assert (reports / "log.txt").read_bytes() == raw
    assert not list(temp.iterdir()), "parser temporary files must be removed"
    assert summary["exit_code"] == result.returncode
    verdict = "✅ PASS" if result.returncode == 0 else f"❌ FAIL (exit {result.returncode})"
    assert f"**Result:** {verdict}" in report
    assert "\x1b" not in report and "\r" not in summary["run_line"]
    return summary, names


def main():
    reports_checked = classifiers_checked = 0
    with tempfile.TemporaryDirectory(prefix="text-normalization-") as tmp:
        root = Path(tmp)
        for language, (failure, expected_names, passing) in CASES.items():
            for outcome, text in (("failed", failure), ("passed", passing)):
                baseline = None
                for index, variant in enumerate(variants(text)):
                    raw = variant.encode()
                    result = render(root / f"{language}-{outcome}-{index}", language, raw)
                    reports_checked += 1
                    summary, names = result
                    expected = expected_names if outcome == "failed" else []
                    assert names == expected, (language, outcome, index, names)
                    assert summary["failed"] == len(expected)
                    assert summary["exit_code"] == int(bool(expected))
                    if outcome == "failed":
                        assert summary["failures_grouped"] == {
                            "EXPECTED_FAILURE": [expected_names[0]],
                            "ASSERTION_FAILURE": [expected_names[1]],
                        }
                    if baseline is None:
                        baseline = result
                    assert result == baseline, (language, outcome, index, result, baseline)
                    log = root / "classifier-input.log"
                    log.write_bytes(raw)
                    # Auto-detection deliberately needs a failure; passing logs
                    # retain its existing no-match behavior.
                    for selected in (language, "auto") if expected else (language,):
                        for output in (None, root / "classifier-output.json"):
                            cmd = [sys.executable, str(ROOT / "bin/classify_failures.py"),
                                   "--language", selected, "--in", str(log)]
                            if output:
                                cmd += ["--out", str(output)]
                            run = subprocess.run(cmd, capture_output=True, check=True)
                            payload = json.loads(output.read_text() if output else run.stdout)
                            assert payload["failures"] == expected
                            assert payload["failures_grouped"] == summary["failures_grouped"]
                            classifiers_checked += 1
            styled = variants(failure)[-1].encode() + b"\xff\r\n"
            for exit_code in (0, 3):
                summary, names = render(root / f"{language}-live-{exit_code}", language, styled, exit_code)
                reports_checked += 1
                assert names == expected_names and summary["failed"] == 2
                assert summary["exit_code"] == (exit_code or 1)
            summary, names = render(root / f"{language}-degraded", language, styled, degraded=True)
            reports_checked += 1
            assert names == expected_names and summary["failed"] == 2
            assert summary["exit_code"] == 1 and summary["classify_error"] is True
            assert summary["failures_by_class"] == {}
    print(f"log normalization: {reports_checked} reports and {classifiers_checked} classifier CLI calls passed")


if __name__ == "__main__":
    main()
