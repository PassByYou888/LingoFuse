#!/usr/bin/env bash
# =============================================================================
#  run_test_ci.sh
# -----------------------------------------------------------------------------
#  One-shot CI orchestration for the LingoFuse Java binding on Linux / macOS.
#
#  Wraps `mvn test -Dlingofuse.ci=true` and captures the JSON Lines
#  emitted by CiTestListener. Produces:
#
#      test_ci_report.jsonl   -- every event, one JSON object per line
#      test_ci_summary.txt    -- compact human-readable summary
#      test_ci_raw.log        -- the full Maven output, unfiltered
#
#  Exit codes:
#      0  all tests PASSed
#      1  at least one test FAILed
#      2  startup error (pom.xml not found, mvn missing, ...)
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

POM="$SCRIPT_DIR/pom.xml"
if [ ! -f "$POM" ]; then
    echo "Cannot find pom.xml in $SCRIPT_DIR" >&2
    exit 2
fi

REPORT="$SCRIPT_DIR/test_ci_report.jsonl"
SUMMARY="$SCRIPT_DIR/test_ci_summary.txt"
RAW_LOG="$SCRIPT_DIR/test_ci_raw.log"

rm -f "$REPORT" "$SUMMARY" "$RAW_LOG"

echo ""
echo "======================================================================"
echo "  LingoFuse Java -- CI test run"
echo "======================================================================"
echo "  Working directory : $SCRIPT_DIR"
echo "  Report            : $REPORT"
echo "  Summary           : $SUMMARY"
echo "======================================================================"
echo ""

# Run Maven; capture exit code without aborting on failure.
set +e
mvn -B test -Dlingofuse.ci=true 2>&1 | tee "$RAW_LOG"
EXIT=$?
set -e

# ---- Extract JSON Lines ------------------------------------------------------
if [ -f "$RAW_LOG" ]; then
    grep -E '^[[:space:]]*\{' "$RAW_LOG" > "$REPORT" || true
fi

# ---- Build summary -----------------------------------------------------------
SUMMARY_LINE=""
if [ -f "$REPORT" ]; then
    SUMMARY_LINE=$(grep '"event":"summary"' "$REPORT" | tail -n 1 || true)
fi

{
    echo ""
    echo "======================================================================"
    echo "  LingoFuse Java -- CI Summary"
    echo "======================================================================"
    echo ""

    if [ -n "$SUMMARY_LINE" ]; then
        echo "  $SUMMARY_LINE"
    else
        echo "  (no summary line found in the report)"
    fi

    # List any failures.
    FAIL_LINES=""
    if [ -f "$REPORT" ]; then
        FAIL_LINES=$(grep '"event":"test"' "$REPORT" | grep '"status":"FAIL"' || true)
    fi

    if [ -n "$FAIL_LINES" ]; then
        echo ""
        echo "  Failed tests:"
        echo ""
        echo "$FAIL_LINES" | while IFS= read -r line; do
            echo "    $line"
        done
    fi

    echo ""
    echo "======================================================================"
    if [ "$EXIT" -eq 0 ]; then
        echo "  RESULT: ALL TESTS PASSED"
    else
        echo "  RESULT: TEST FAILURES DETECTED"
    fi
    echo "======================================================================"
} | tee "$SUMMARY"

exit "$EXIT"