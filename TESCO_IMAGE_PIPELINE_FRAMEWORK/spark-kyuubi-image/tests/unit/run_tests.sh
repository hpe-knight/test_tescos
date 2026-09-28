#!/usr/bin/env bash
# =============================================================================
# Suite U — unit / static validation (TC-U01..TC-U06). See tests/testcases/TEST_CASES.md
# Usage: run_tests.sh <junit-output.xml>
# =============================================================================
set -uo pipefail

JUNIT_OUT="${1:-junit-unit.xml}"
IMAGE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0; FAIL=0; CASES=""

record() { # name, status(0/1), message
  local name="$1" status="$2" msg="${3:-}"
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS+1)); CASES+="    <testcase classname=\"unit\" name=\"${name}\"/>\n"
    echo "PASS: ${name}"
  else
    FAIL=$((FAIL+1)); CASES+="    <testcase classname=\"unit\" name=\"${name}\"><failure message=\"${msg}\"/></testcase>\n"
    echo "FAIL: ${name} — ${msg}"
  fi
}

# TC-U01 — no :latest base images
if grep -qE '^FROM .+:latest' "${IMAGE_DIR}/Dockerfile"; then
  record "dockerfile_no_latest_tag" 1 "Base image uses :latest tag"
else
  record "dockerfile_no_latest_tag" 0
fi

# TC-U02 — HEALTHCHECK present
grep -q '^HEALTHCHECK' "${IMAGE_DIR}/Dockerfile"
record "dockerfile_has_healthcheck" $? "No HEALTHCHECK instruction"

# TC-U03 — non-root USER
grep -qE '^USER [^r]' "${IMAGE_DIR}/Dockerfile"
record "dockerfile_non_root_user" $? "No non-root USER instruction"

# TC-U04 — spark-defaults.conf syntax (key value per non-comment line)
BAD=$(grep -vE '^\s*(#|$)' "${IMAGE_DIR}/conf/spark-defaults.conf" | grep -cvE '^\S+\s+\S+' || true)
[ "${BAD}" -eq 0 ]
record "spark_defaults_syntax" $? "${BAD} malformed line(s)"

# TC-U05 — Kyuubi Thrift port configured
grep -q 'kyuubi.frontend.thrift.binary.bind.port' "${IMAGE_DIR}/conf/kyuubi-defaults.conf"
record "kyuubi_defaults_thrift_port" $? "Thrift bind port not configured"

# TC-U06 — sample dataset present with headers
DATA_OK=0
for f in stores.csv products.csv retail_sales.csv; do
  if [ ! -s "${IMAGE_DIR}/sample-data/${f}" ] || ! head -1 "${IMAGE_DIR}/sample-data/${f}" | grep -q ','; then
    DATA_OK=1
  fi
done
record "sample_data_present" ${DATA_OK} "Missing or headerless CSV in sample-data/"

TOTAL=$((PASS+FAIL))
mkdir -p "$(dirname "${JUNIT_OUT}")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"unit-tests\" tests=\"${TOTAL}\" failures=\"${FAIL}\">"
  printf "%b" "${CASES}"
  echo "</testsuite>"
} > "${JUNIT_OUT}"

echo "Unit tests: ${PASS}/${TOTAL} passed (${JUNIT_OUT})"
[ "${FAIL}" -eq 0 ]
