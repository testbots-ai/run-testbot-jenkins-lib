#!/usr/bin/env bash
#
# Run TestBot — bundled script for the Jenkins Shared Library.
#
# Loaded via libraryResource() by vars/runTestBot.groovy, written to the
# build workspace, and executed with `sh`. Reads JWT_TOKEN and
# TEST_BOT_CONFIGURATION as environment variables (set by runTestBot.groovy
# from the customer's Jenkins Credentials), triggers a TestBot execution,
# polls until it completes, and writes JUnit + Markdown reports into the
# current workspace so the customer's Jenkinsfile can pick them up via
# `junit 'test-reports/*.xml'` and `archiveArtifacts`.
#
# This is the same script (unchanged) already validated end-to-end against
# a real AutomationHQ execution as the Bitbucket Pipe entrypoint.

set -euo pipefail

JWT_TOKEN="${JWT_TOKEN:-}"
TEST_BOT_CONFIGURATION="${TEST_BOT_CONFIGURATION:-}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
POLL_TIMEOUT_MINUTES="${POLL_TIMEOUT_MINUTES:-345}"

# AutomationHQ's executor API. Polled directly so every failure mode (bad
# config, unreachable API, auth failure, timeout, malformed results)
# produces a clear reason in the pipeline log instead of the build just
# going red with no explanation.
TESTOPS_BASE_URL="https://api.automationhq.ai/ahq-test-bot-executor-services"

mkdir -p results test-reports

# Collapses newlines, escapes "|", and caps length so a raw API error body
# (which can be an entire HTML error page from a gateway) never floods the log.
sanitize() {
  local msg
  msg=$(echo "$1" | tr '\n\r' '  ' | sed 's/|/\\|/g')
  if [ ${#msg} -gt 500 ]; then
    echo "${msg:0:500}... (truncated)"
  else
    echo "$msg"
  fi
}

echo "===== Validate Inputs ====="

if [ -z "$JWT_TOKEN" ]; then
  echo "ERROR: JWT_TOKEN variable is empty. Set it in your step's 'pipe: ... variables:' block."
  exit 1
fi

if ! CONFIG=$(echo "$TEST_BOT_CONFIGURATION" | jq -c . 2>&1); then
  echo "ERROR: TEST_BOT_CONFIGURATION is not valid JSON: $(echo "$CONFIG" | tr '\n' ' ')"
  echo "   Diagnostic (no secret values shown): ${#TEST_BOT_CONFIGURATION} chars, $(echo "$TEST_BOT_CONFIGURATION" | wc -l | tr -d ' ') lines, starts with '$(echo -n "$TEST_BOT_CONFIGURATION" | head -c1)', ends with '$(echo -n "$TEST_BOT_CONFIGURATION" | tail -c1)', braces: $(echo -n "$TEST_BOT_CONFIGURATION" | tr -cd '{' | wc -c | tr -d ' ') open / $(echo -n "$TEST_BOT_CONFIGURATION" | tr -cd '}' | wc -c | tr -d ' ') close"
  exit 1
fi

TEST_BOT_ID=$(echo "$CONFIG" | jq -r '.testBotId // empty')
if [ -z "$TEST_BOT_ID" ]; then
  echo "ERROR: TEST_BOT_CONFIGURATION is missing a \"testBotId\" field"
  exit 1
fi

TEST_BOT_NAME=$(echo "$CONFIG" | jq -r '.name')
echo "   Test Bot ID  : $TEST_BOT_ID"
echo "   Test Bot Name: $TEST_BOT_NAME"

echo ""
echo "===== Trigger and Poll TestBot Execution ====="

echo "Triggering test bot execution..."
echo "   Endpoint : ${TESTOPS_BASE_URL}/rest/api/testops/${TEST_BOT_ID}/execute"

# No --retry here: this POST triggers a real execution and is not idempotent.
# The status/detailed-results calls below are plain GETs, so they retry safely.
set +e
TRIGGER_RESPONSE=$(curl -sS --fail-with-body -X POST \
  "${TESTOPS_BASE_URL}/rest/api/testops/${TEST_BOT_ID}/execute" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$CONFIG")
CURL_EXIT=$?
set -e

if [ $CURL_EXIT -ne 0 ]; then
  echo "ERROR: Trigger request failed (curl exit $CURL_EXIT — endpoint unreachable, timed out, or a non-2xx status, e.g. an invalid/expired token): $(sanitize "$TRIGGER_RESPONSE")"
  exit 1
fi

EXECUTION_ID=$(echo "$TRIGGER_RESPONSE" | jq -r '.id // empty')
if [ -z "$EXECUTION_ID" ]; then
  echo "ERROR: Trigger response did not include an execution id: $(sanitize "$(echo "$TRIGGER_RESPONSE" | jq -r '.message // .')")"
  exit 1
fi

echo "Execution triggered. ID: $EXECUTION_ID"

echo "Polling every ${POLL_INTERVAL_SECONDS}s (timeout: ${POLL_TIMEOUT_MINUTES}m)..."
START_TIME=$SECONDS
POLL_COUNT=0
FINAL_STATUS="UNKNOWN"

while true; do
  POLL_COUNT=$((POLL_COUNT + 1))
  ELAPSED=$((SECONDS - START_TIME))

  if [ $ELAPSED -gt $((POLL_TIMEOUT_MINUTES * 60)) ]; then
    echo "ERROR: Polling timed out after ${POLL_TIMEOUT_MINUTES} minutes. Last known status: $FINAL_STATUS"
    exit 1
  fi

  set +e
  STATUS_RESPONSE=$(curl -sS --fail-with-body --retry 3 --retry-delay 5 \
    "${TESTOPS_BASE_URL}/rest/api/testops/execution/${EXECUTION_ID}/status?pollCount=${POLL_COUNT}")
  CURL_EXIT=$?
  set -e

  if [ $CURL_EXIT -ne 0 ]; then
    echo "ERROR: Status check failed (curl exit $CURL_EXIT) after ${ELAPSED}s: $(sanitize "$STATUS_RESPONSE")"
    exit 1
  fi

  FINAL_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status // "UNKNOWN"')
  echo "   Status: $FINAL_STATUS (elapsed: ${ELAPSED}s)"

  # ENQUEUED / PROCESSING / OPTIMIZATION_IN_PROGRESS are the only "still
  # running" states the backend emits. Everything else (SUCCEEDED,
  # COMPLETED, FAILED, CANCELLED, UNKNOWN-fallback) is terminal.
  case "$FINAL_STATUS" in
    ENQUEUED|PROCESSING|OPTIMIZATION_IN_PROGRESS)
      sleep "$POLL_INTERVAL_SECONDS"
      ;;
    *)
      break
      ;;
  esac
done

echo "Execution finished with status: $FINAL_STATUS"

echo ""
echo "===== Fetch Detailed Results ====="
set +e
curl -sS --fail-with-body --retry 3 --retry-delay 5 \
  "${TESTOPS_BASE_URL}/rest/api/testops/execution/${EXECUTION_ID}/detailed-results" \
  -o results/execution-result.json
CURL_EXIT=$?
set -e

if [ $CURL_EXIT -ne 0 ]; then
  BODY=$(cat results/execution-result.json 2>/dev/null || echo "")
  echo "ERROR: Execution finished with status $FINAL_STATUS but fetching detailed results failed (curl exit $CURL_EXIT): $(sanitize "$BODY")"
  exit 1
fi

if ! FAILED_SCRIPTS=$(jq -r '.summary.failedScripts // 0' results/execution-result.json 2>&1) || ! [[ "$FAILED_SCRIPTS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Detailed results were downloaded but are not valid/expected JSON: $(sanitize "$(cat results/execution-result.json 2>/dev/null)")"
  exit 1
fi

echo ""
echo "===== Generate JUnit XML + Markdown Report ====="

python3 <<'PY'
import json
import xml.etree.ElementTree as ET
from pathlib import Path

json_file = Path("results/execution-result.json")
with open(json_file, "r", encoding="utf-8") as f:
    data = json.load(f)

Path("test-reports").mkdir(exist_ok=True)
Path("results").mkdir(exist_ok=True)
summary = data.get("summary", {})

suite = ET.Element(
    "testsuite",
    name=data.get("testBotName", "TestBot"),
    tests=str(summary.get("totalScripts", 0)),
    failures=str(summary.get("failedScripts", 0)),
    errors="0",
)

for ts in data.get("testSuiteResults", []):
    suite_name = ts.get("testSuiteName", "Suite")
    for script in ts.get("testScriptResults", []):
        tc = ET.SubElement(
            suite, "testcase",
            classname=suite_name,
            name=script.get("testScriptName", "Test"),
        )
        if script.get("resultStatus") != "PASSED":
            fail = ET.SubElement(tc, "failure")
            fail.text = script.get("resultStatus")

# Written to test-reports/ — one of Bitbucket Pipelines' default scan paths,
# so the pipeline's Tests tab picks it up automatically with no extra config.
ET.ElementTree(suite).write(
    "test-reports/junit.xml", encoding="utf-8", xml_declaration=True
)

md = []
md.append("# TestBot Execution Report")
md.append("")
md.append(f"**Execution ID:** {data.get('executionId')}")
md.append("")
md.append(f"**Bot:** {data.get('testBotName')}")
md.append("")
md.append(f"**Status:** {data.get('status')}")
md.append("")
md.append(f"**Duration:** {summary.get('formattedDuration')}")
md.append("")
md.append("## Summary")
md.append("")
md.append("| Metric | Value |")
md.append("|----------|----------|")
md.append(f"| Total Suites | {summary.get('totalSuites')} |")
md.append(f"| Passed Suites | {summary.get('passedSuites')} |")
md.append(f"| Failed Suites | {summary.get('failedSuites')} |")
md.append(f"| Total Scripts | {summary.get('totalScripts')} |")
md.append(f"| Passed Scripts | {summary.get('passedScripts')} |")
md.append(f"| Failed Scripts | {summary.get('failedScripts')} |")

for suite_r in data.get("testSuiteResults", []):
    md.append("")
    md.append(f"## Suite: {suite_r.get('testSuiteName', 'Suite')}")
    md.append("")
    for script in suite_r.get("testScriptResults", []):
        icon = "✅" if script.get("resultStatus") == "PASSED" else "❌"
        md.append(f"### {icon} {script.get('testScriptName', 'Test')}")
        for iteration in script.get("iterations", []):
            md.append("")
            md.append("| Step | Status | Description |")
            md.append("|------|--------|-------------|")
            for step in iteration.get("stepResults", []):
                status = step.get("resultStatus")
                emoji = "✅" if status == "PASSED" else "❌"
                md.append(f"| {step.get('sequence')} | {emoji} {status} | {step.get('testStepName')} |")

Path("results/report.md").write_text("\n".join(md), encoding="utf-8")
print("Generated test-reports/junit.xml and results/report.md")
PY

echo ""
echo "===== TestBot Run Summary ====="
echo ""
echo "Execution ID : $EXECUTION_ID"
echo "Status       : $FINAL_STATUS"
echo ""
cat results/report.md
echo ""
echo "================================"

if [ "$FINAL_STATUS" = "FAILED" ] || [ "$FAILED_SCRIPTS" -gt 0 ]; then
  echo ""
  echo "TestBot run finished with failures ($FAILED_SCRIPTS failed script(s))."
  exit 1
fi
