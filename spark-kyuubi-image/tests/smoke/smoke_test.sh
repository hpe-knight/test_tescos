#!/usr/bin/env bash
# =============================================================================
# Stage 3 smoke tests — "is the container alive?"
# Runs against the environment started by docker-compose.test.yml.
# Usage: smoke_test.sh <junit-output.xml>
# =============================================================================
set -uo pipefail

JUNIT_OUT="${1:-junit-smoke.xml}"
CONTAINER="kyuubi-test"
HEALTH_URL="http://localhost:10099/api/v1/ping"
THRIFT_PORT=10009
STARTUP_TIMEOUT=300   # seconds — Spark+Kyuubi needs ~3 min on 2-core CI runners

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

# --- Test 1: container reaches HEALTHY within the startup budget ------------
echo "Waiting up to ${STARTUP_TIMEOUT}s for ${CONTAINER} to become healthy..."
DEADLINE=$((SECONDS + STARTUP_TIMEOUT)); HEALTHY=1
while [ $SECONDS -lt $DEADLINE ]; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "missing")
  if [ "$STATUS" = "healthy" ]; then HEALTHY=0; break; fi
  if [ "$STATUS" = "missing" ]; then break; fi
  sleep 5
done
record "container_healthy_within_${STARTUP_TIMEOUT}s" ${HEALTHY} "Health status: ${STATUS:-unknown}"

# --- Test 2: REST health endpoint answers -----------------------------------
curl -sf --max-time 10 "${HEALTH_URL}" > /dev/null
record "rest_ping_endpoint" $? "No response from ${HEALTH_URL}"

# --- Test 3: Thrift/JDBC port is listening -----------------------------------
(exec 3<>"/dev/tcp/localhost/${THRIFT_PORT}") 2>/dev/null
record "thrift_port_${THRIFT_PORT}_listening" $? "Port ${THRIFT_PORT} not accepting connections"
exec 3>&- 2>/dev/null || true

# --- Test 4: Kyuubi server process is running inside the container ----------
docker exec "${CONTAINER}" sh -c "ps aux | grep -v grep | grep -qi kyuubi"
record "kyuubi_process_running" $? "No kyuubi process found in container"

# --- Test 5: no FATAL/OOM errors in startup logs ------------------------------
if docker logs "${CONTAINER}" 2>&1 | grep -qE 'FATAL|OutOfMemoryError'; then
  record "no_fatal_errors_in_logs" 1 "FATAL or OOM entries present in container logs"
else
  record "no_fatal_errors_in_logs" 0
fi

# --- Emit JUnit XML ----------------------------------------------------------
TOTAL=$((PASS+FAIL))
mkdir -p "$(dirname "${JUNIT_OUT}")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"smoke-tests\" tests=\"${TOTAL}\" failures=\"${FAIL}\">"
  printf "%b" "${CASES}"
  echo "</testsuite>"
} > "${JUNIT_OUT}"

echo "Smoke tests: ${PASS}/${TOTAL} passed (report: ${JUNIT_OUT})"
[ "${FAIL}" -eq 0 ]
