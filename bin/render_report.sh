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
        # The full per-test lines are "test_module.py F" etc. We treat each
        # FAILED summary line as one failing test (and let classify handle
        # dedup).
        TEST_LINE_RX='^(FAILED|PASSED) '
        PASS_LINE_RX='^PASSED '
        FAIL_LINE_RX='^FAILED '
        FAIL_NAME_RX='^FAILED [^:]+::(.+)$'
        RUN_LINE_RX='[0-9]+ (passed|failed) in '
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

TOTAL=$(grep -cE "$TEST_LINE_RX" "$LOG_FILE" || true)
PASSED=$(grep -cE "$PASS_LINE_RX" "$LOG_FILE" || true)
FAILED=$(grep -cE "$FAIL_LINE_RX" "$LOG_FILE" || true)

# Pull out the failing test names for the report. macOS ships bash 3.2 (no mapfile),
# so use a temp file and a here-string read loop.
FAILING_TESTS_TMP="$(mktemp)"
trap 'rm -f "$FAILING_TESTS_TMP"' EXIT
grep -E "$FAIL_LINE_RX" "$LOG_FILE" | sed -E "s/${FAIL_NAME_RX}/\1/" > "$FAILING_TESTS_TMP" || true
FAILING_TESTS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && FAILING_TESTS+=("$line")
done < "$FAILING_TESTS_TMP"

# Classify failing tests by naming convention. Output is a small JSON file
# that we then merge into summary.json. See scripts/classify_failures.py.
CLASSIFY_FILE="$REPORT_DIR/classify.json"
python3 "$REPO_ROOT/scripts/classify_failures.py" --in "$LOG_FILE" --out "$CLASSIFY_FILE" \
    >/dev/null 2>&1 || echo '{}' > "$CLASSIFY_FILE"

# Try to extract the run-summary line. swift test may print it as either
#   "Test run with 74 tests passed after 0.005 seconds."
# or, when stderr is interleaved,
#   "✔ Test run with 74 tests passed after 0.005 seconds."
RUN_LINE=$(grep -E 'Test run with .* tests? ' "$LOG_FILE" | tail -1 | sed -E 's/^[✔✘] //' || true)
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
    except (OSError, ValueError):
        body["failures_by_class"] = {}
        body["failures_grouped"] = {}
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
