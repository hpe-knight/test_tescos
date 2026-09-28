#!/usr/bin/env bash
# =============================================================================
# Suite S — smoke / liveness (TC-S01..TC-S05). See tests/testcases/TEST_CASES.md
# Runs against the environment from docker-compose.test.yml.
# Usage: smoke_test.sh <junit-output.xml>
# =============================================================================
set -uo pipefail

JUNIT_OUT="${1:-junit-smoke.xml}"
CONTAINER="kyuubi-test"
HEALTH_URL="http://localhost:10099/api/v1/ping"
THRIFT_PORT=10009
STARTUP_TIMEOUT=180

PASS=0; FAIL=0; CASES=""

record() {
  local name="$1" status="$2" msg="${3:-}"
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS+1)); CASES+="    <testcase classname=\"smoke\" name=\"${name}\"/>\n"
    echo "PASS: ${name}"
  else
    FAIL=$((FAIL+1)); CASES+="    <testcase classname=\"smoke\" name=\"${name}\"><failure message=\"${msg}\"/></testcase>\n"
    echo "FAIL: ${name} — ${msg}"
  fi
}

# TC-S01 — healthy within budget
echo "Waiting up to ${STARTUP_TIMEOUT}s for ${CONTAINER} to become healthy..."
DEADLINE=$((SECONDS + STARTUP_TIMEOUT)); HEALTHY=1; STATUS="unknown"
while [ $SECONDS -lt $DEADLINE ]; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "missing")
  [ "$STATUS" = "healthy" ] && { HEALTHY=0; break; }
  [ "$STATUS" = "missing" ] && break
  sleep 5
done
record "container_healthy_within_${STARTUP_TIMEOUT}s" ${HEALTHY} "Health status: ${STATUS}"

# TC-S02 — REST ping
curl -sf --max-time 10 "${HEALTH_URL}" > /dev/null
record "rest_ping_endpoint" $? "No response from ${HEALTH_URL}"

# TC-S03 — Thrift port listening
(exec 3<>"/dev/tcp/localhost/${THRIFT_PORT}") 2>/dev/null
record "thrift_port_${THRIFT_PORT}_listening" $? "Port ${THRIFT_PORT} closed"
exec 3>&- 2>/dev/null || true

# TC-S04 — kyuubi process running
docker exec "${CONTAINER}" sh -c "ps aux | grep -v grep | grep -qi kyuubi"
record "kyuubi_process_running" $? "No kyuubi process in container"

# TC-S05 — clean startup logs
if docker logs "${CONTAINER}" 2>&1 | grep -qE 'FATAL|OutOfMemoryError'; then
  record "no_fatal_errors_in_logs" 1 "FATAL/OOM entries in logs"
else
  record "no_fatal_errors_in_logs" 0
fi

TOTAL=$((PASS+FAIL))
mkdir -p "$(dirname "${JUNIT_OUT}")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"smoke-tests\" tests=\"${TOTAL}\" failures=\"${FAIL}\">"
  printf "%b" "${CASES}"
  echo "</testsuite>"
} > "${JUNIT_OUT}"

echo "Smoke tests: ${PASS}/${TOTAL} passed (${JUNIT_OUT})"
[ "${FAIL}" -eq 0 ]
