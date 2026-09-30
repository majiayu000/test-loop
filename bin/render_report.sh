#!/usr/bin/env bash
# render_report.sh — run the project's test command and produce
# docs/reports/<date>/{log.txt, summary.json, report.md}.
#
# Usage:
#   bin/render_report.sh                                  # caff defaults (swift test --parallel)
#   bin/render_report.sh --language python                # pytest (no extra args)
#   bin/render_report.sh --test-command "go test ./..."   # explicit command
#   bin/render_report.sh --collect                        # only render from an existing log
#
# Supported languages: swift (default), python, go, rust.
# --test-command overrides the per-language default test invocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TODAY="$(date +%Y-%m-%d)"
TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S)"
REPORT_DIR="$REPO_ROOT/docs/reports/$TODAY"
LOG_FILE="$REPORT_DIR/log.txt"
SUMMARY_FILE="$REPORT_DIR/summary.json"
REPORT_FILE="$REPORT_DIR/report.md"

mkdir -p "$REPORT_DIR"

LANGUAGE="swift"
COLLECT_ONLY=0
TEST_COMMAND=""
while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --collect)       COLLECT_ONLY=1; shift ;;
        --language)      LANGUAGE="${2:-}"; shift 2 ;;
        --language=*)    LANGUAGE="${arg#--language=}"; shift ;;
        --test-command)  TEST_COMMAND="${2:-}"; shift 2 ;;
        --test-command=*) TEST_COMMAND="${arg#--test-command=}"; shift ;;
        -h|--help)
            sed -n '3,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Per-language defaults. --test-command overrides.
if [[ -z "$TEST_COMMAND" ]]; then
    case "$LANGUAGE" in
        swift)  TEST_COMMAND="swift test --parallel" ;;
        python) TEST_COMMAND="python -m pytest -q" ;;
        go)     TEST_COMMAND="go test ./..." ;;
        rust)   TEST_COMMAND="cargo test --no-fail-fast" ;;
        *) echo "unsupported --language: $LANGUAGE" >&2; exit 2 ;;
    esac
fi

# Per-language log parsing patterns.
case "$LANGUAGE" in
    swift)
        # ✔ Test foo() passed after 0.001 seconds.
        # ✘ Test bar() failed after 0.002 seconds with 1 issue.
        TEST_LINE_RX='^(✔|✘) Test [^()]+\('
        PASS_LINE_RX='^✔ Test '
        FAIL_LINE_RX='^✘ Test '
        FAIL_NAME_RX='^✘ Test ([^(]+).*'
        RUN_LINE_RX='Test run with .* tests? '
        ;;
    python)
        # pytest short summary lines are "FAILED test_module.py::test_name".
        # Use run summaries for counts: quiet logs omit PASSED lines and
        # FAILED short-summary lines may repeat.
        # Parsed below with Python to share node IDs with the classifier.
        ;;
    go)
        # go test verbose:
        #   --- FAIL: TestFoo (0.00s)
        #   --- PASS: TestFoo (0.00s)
        TEST_LINE_RX='^--- (PASS|FAIL): '
        PASS_LINE_RX='^--- PASS: '
        FAIL_LINE_RX='^--- FAIL: '
        FAIL_NAME_RX='^--- FAIL: ([^ ]+).*'
        RUN_LINE_RX='^(ok|FAIL)[[:space:]]'
        ;;
    rust)
        # cargo test per-test:
        #   test test_foo ... ok
        #   test test_foo ... FAILED
        TEST_LINE_RX='^test[[:space:]]+\S+[[:space:]]+\.\.\. '
        PASS_LINE_RX='^test[[:space:]]+\S+[[:space:]]+\.\.\. ok'
        FAIL_LINE_RX='^test[[:space:]]+\S+[[:space:]]+\.\.\. FAILED'
        FAIL_NAME_RX='^test[[:space:]]+(\S+)[[:space:]]+\.\.\. FAILED'
        RUN_LINE_RX='test result: (ok|FAILED)\.'
        ;;
    *) echo "unsupported --language: $LANGUAGE" >&2; exit 2 ;;
esac

if [[ $COLLECT_ONLY -eq 0 ]]; then
    echo "running: $TEST_COMMAND" >&2
    set +e
    eval "$TEST_COMMAND" 2>&1 | tee "$LOG_FILE"
    SWIFT_EXIT=${PIPESTATUS[0]}
    set -e
else
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "error: $LOG_FILE not found for --collect" >&2
        exit 2
    fi
    SWIFT_EXIT=0
fi

# Classify failing tests by naming convention. Output is a small JSON file
# that we then merge into summary.json. classify_failures.py is a sibling of
# this script, so $SCRIPT_DIR resolves it whether installed under bin/ or
# scripts/.
CLASSIFY_FILE="$REPORT_DIR/classify.json"
CLASSIFY_ERR="$REPORT_DIR/classify.err"
if python3 "$SCRIPT_DIR/classify_failures.py" --language "$LANGUAGE" --in "$LOG_FILE" --out "$CLASSIFY_FILE" 2>"$CLASSIFY_ERR"; then
    rm -f "$CLASSIFY_ERR"
else
    # Do not hide the failure behind an empty {} (no silent degradation):
    # surface the error and flag the classification as degraded.
    echo "error: classify_failures.py failed; see $CLASSIFY_ERR" >&2
    cat "$CLASSIFY_ERR" >&2 || true
    echo '{"failures": [], "failures_by_class": {}, "failures_grouped": {}, "classify_error": true}' > "$CLASSIFY_FILE"
fi

# macOS ships bash 3.2 (no mapfile), so pass parsed failure names through a
# temp file and a here-string read loop.
FAILING_TESTS_TMP="$(mktemp)"
trap 'rm -f "$FAILING_TESTS_TMP"' EXIT
if [[ "$LANGUAGE" == "python" ]]; then
    PYTEST_REPORT=$(python3 - "$LOG_FILE" "$CLASSIFY_FILE" <<'PY'
import json
import re
import sys
from pathlib import Path

# Classification already ran at its guarded boundary. Counting and rendering
# still work from the raw log when that call produced a degraded result.
names = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))["failures"]
log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="backslashreplace")
lines = log.splitlines()
progress_rx = r"^(?:.*\.py\s+)?[.FEsxX]+(?:\s+\[\s*\d+%\])?\s*$"
has_runner_output = any(re.match(progress_rx, line) or
                        re.match(r"^=+ test session starts =+$", line) for line in lines)
last_line = max((i for i, line in enumerate(lines) if line.strip()), default=-1)
failing_names = dict.fromkeys(names)
passed = failed = 0
run_passed, run_failed = set(), set()
summaries = []
in_details = False
in_session = in_short_summary = False
for i, line in enumerate(lines):
    if re.match(r"^=+ (test session starts|FAILURES|ERRORS) =+$", line):
        passed += len(run_passed)
        failed += len(run_failed)
        run_passed.clear()
        run_failed.clear()
        in_details = False
        in_short_summary = False
    if re.match(r"^=+ test session starts =+$", line):
        in_session = True
    if re.match(r"^=+ (FAILURES|ERRORS) =+$", line):
        in_details = True
    if re.match(r"^=+ short test summary info =+$", line):
        in_details = False
        in_short_summary = True
    if line.startswith("PASSED "):
        run_passed.add(line[7:])
    if line.startswith("FAILED "):
        raw_name = line[7:]
        name = max((name for name in names if raw_name == name or
                    raw_name.startswith(name + " - ")), key=len, default=raw_name)
        run_failed.add(name)
        failing_names.setdefault(name, None)
    # Non-quiet pytest decorates its summary. Quiet summaries follow progress
    # or short-summary details, or terminate the log. Test stdout before
    # progress (notably with -s) is not a run summary.
    summary_position = line.startswith("=") or in_short_summary or i == last_line or (
        not in_session and (not has_runner_output or
                            (i > 0 and re.match(progress_rx, lines[i - 1]))))
    if not in_details and summary_position and re.match(r"^[=\s]*\d+ [a-zA-Z]+(, \d+ [a-zA-Z]+)* in ", line):
        counts = dict((status, int(count)) for count, status in
                      re.findall(r"(\d+) (passed|failed)\b", line))
        # A quiet passing run has no session banner. Retain failures from
        # an earlier truncated run rather than discarding them here.
        passed += max(counts.get("passed", 0), len(run_passed))
        failed += max(counts.get("failed", 0), len(run_failed))
        run_passed.clear()
        run_failed.clear()
        summaries.append(line)
        in_session = in_short_summary = False
passed += len(run_passed)
failed += len(run_failed)
print(passed, failed)
print("; ".join(summaries))
for name in failing_names:
    print(name)
PY
    )
    read -r PASSED FAILED <<< "$PYTEST_REPORT"
    TOTAL=$((PASSED + FAILED))
    RUN_LINE=$(printf '%s\n' "$PYTEST_REPORT" | sed -n '2p')
    printf '%s\n' "$PYTEST_REPORT" | sed -n '3,$p' > "$FAILING_TESTS_TMP"
else
    # Swift may prefix the run summary with a check mark.
    RUN_LINE=$(grep -E "$RUN_LINE_RX" "$LOG_FILE" | sed -E 's/^[✔✘] //' | tail -1 || true)
    TOTAL=$(grep -cE "$TEST_LINE_RX" "$LOG_FILE" || true)
    PASSED=$(grep -cE "$PASS_LINE_RX" "$LOG_FILE" || true)
    FAILED=$(grep -cE "$FAIL_LINE_RX" "$LOG_FILE" || true)
    grep -E "$FAIL_LINE_RX" "$LOG_FILE" | sed -E "s/${FAIL_NAME_RX}/\1/" > "$FAILING_TESTS_TMP" || true
fi
FAILING_TESTS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && FAILING_TESTS+=("$line")
done < "$FAILING_TESTS_TMP"

[[ -z "$RUN_LINE" ]] && RUN_LINE="(no summary line found)"

# Write a small JSON summary. Use python3 for safe JSON encoding.
python3 -c '
import json, sys
summary_path, classify_path = sys.argv[1], sys.argv[2]
total, passed, failed, exit_code, run_line = sys.argv[3:8]
with open(summary_path, "w", encoding="utf-8") as f:
    body = {
        "total": int(total),
        "passed": int(passed),
        "failed": int(failed),
        "exit_code": int(exit_code),
        "run_line": run_line,
    }
    try:
        with open(classify_path, "r", encoding="utf-8") as cf:
            cls = json.load(cf)
        body["failures_by_class"] = cls.get("failures_by_class", {})
        body["failures_grouped"] = cls.get("failures_grouped", {})
        if cls.get("classify_error"):
            body["classify_error"] = True
    except (OSError, ValueError):
        body["failures_by_class"] = {}
        body["failures_grouped"] = {}
        body["classify_error"] = True
    json.dump(body, f, indent=2, ensure_ascii=False)
' "$SUMMARY_FILE" "$CLASSIFY_FILE" "$TOTAL" "$PASSED" "$FAILED" "$SWIFT_EXIT" "$RUN_LINE"


# Render the markdown report.
{
    echo "# Caff Test Report — $TODAY $TIMESTAMP"
    echo
    echo "**Result:** $([[ $SWIFT_EXIT -eq 0 ]] && echo "✅ PASS" || echo "❌ FAIL (exit $SWIFT_EXIT)")"
    echo
    echo "**Summary:** $RUN_LINE"
    echo
    echo "**Counts:** total=$TOTAL passed=$PASSED failed=$FAILED"
    echo
    if [[ ${#FAILING_TESTS[@]} -gt 0 && ${FAILING_TESTS[0]} != "" ]]; then
        echo "## Failing tests"
        echo
        for t in "${FAILING_TESTS[@]}"; do
            echo "- \`$t\`"
        done
        echo
        # Failures by class (from classify_failures.py).
        if [[ -s "$CLASSIFY_FILE" ]]; then
            echo "## Failures by class"
            echo
            echo '```json'
            cat "$CLASSIFY_FILE"
            echo
            echo '```'
            echo
        fi
    fi
    echo "## Artifacts"
    echo
    echo "- Raw log: \`docs/reports/$TODAY/log.txt\`"
    echo "- JSON summary: \`docs/reports/$TODAY/summary.json\`"
} > "$REPORT_FILE"

echo >&2
echo "wrote:" >&2
echo "  $LOG_FILE" >&2
echo "  $SUMMARY_FILE" >&2
echo "  $REPORT_FILE" >&2

exit "$SWIFT_EXIT"
