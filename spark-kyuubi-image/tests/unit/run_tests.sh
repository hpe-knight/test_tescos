#!/usr/bin/env bash
# =============================================================================
# Stage 1 unit tests — validate configs and scripts BEFORE anything runs.
# Usage: run_tests.sh <junit-output.xml>
# Add TESCO-specific config validation cases here as they are collected from
# the testing team (docs/05 discovery checklist).
# =============================================================================
set -uo pipefail

JUNIT_OUT="${1:-junit-unit.xml}"
IMAGE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0; CASES=""

record() { # name, status(0/1), message
  local name="$1" status="$2" msg="${3:-}"
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS+1))
    CASES+="    <testcase classname=\"unit\" name=\"${name}\"/>\n"
    echo "PASS: ${name}"
  else
    FAIL=$((FAIL+1))
    CASES+="    <testcase classname=\"unit\" name=\"${name}\"><failure message=\"${msg}\"/></testcase>\n"
    echo "FAIL: ${name} — ${msg}"
  fi
}

# --- Test 1: Dockerfile exists and pins versions (no :latest base) ----------
if grep -qE '^FROM .+:latest' "${IMAGE_DIR}/Dockerfile"; then
  record "dockerfile_no_latest_tag" 1 "Base image uses :latest tag"
else
  record "dockerfile_no_latest_tag" 0
fi

# --- Test 2: Dockerfile declares a HEALTHCHECK (needed by Stage 3) ----------
grep -q '^HEALTHCHECK' "${IMAGE_DIR}/Dockerfile"
record "dockerfile_has_healthcheck" $? "No HEALTHCHECK instruction found"

# --- Test 3: Dockerfile switches to a non-root USER -------------------------
grep -qE '^USER [^r]' "${IMAGE_DIR}/Dockerfile"
record "dockerfile_non_root_user" $? "No non-root USER instruction found"

# --- Test 4: spark-defaults.conf parses (key value pairs, no tabs-only junk)
BAD_LINES=$(grep -vE '^\s*(#|$)' "${IMAGE_DIR}/conf/spark-defaults.conf" | grep -cvE '^\S+\s+\S+' || true)
[ "${BAD_LINES}" -eq 0 ]
record "spark_defaults_syntax" $? "${BAD_LINES} malformed line(s) in spark-defaults.conf"

# --- Test 5: kyuubi-defaults.conf declares the Thrift port -------------------
grep -q 'kyuubi.frontend.thrift.binary.bind.port' "${IMAGE_DIR}/conf/kyuubi-defaults.conf"
record "kyuubi_defaults_thrift_port" $? "Thrift bind port not configured"

# --- Test 6: required test scripts are present and executable-ish -----------
for f in tests/smoke/smoke_test.sh tests/integration/integration_test.sh; do
  [ -f "${IMAGE_DIR}/${f}" ]
  record "exists_${f//\//_}" $? "Missing ${f}"
done

# --- Emit JUnit XML ----------------------------------------------------------
TOTAL=$((PASS+FAIL))
mkdir -p "$(dirname "${JUNIT_OUT}")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"unit-tests\" tests=\"${TOTAL}\" failures=\"${FAIL}\">"
  printf "%b" "${CASES}"
  echo "</testsuite>"
} > "${JUNIT_OUT}"

echo "Unit tests: ${PASS}/${TOTAL} passed (report: ${JUNIT_OUT})"
[ "${FAIL}" -eq 0 ]
