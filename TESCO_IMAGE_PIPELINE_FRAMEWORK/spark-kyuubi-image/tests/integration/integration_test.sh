#!/usr/bin/env bash
# =============================================================================
# Suite I — integration / functional / data-quality / performance
# (TC-I01..TC-I09). See tests/testcases/TEST_CASES.md for the case definitions.
# Exercises the ENTERPRISE SAMPLE DATASET mounted at /data/sample:
#   stores.csv (5 rows) x products.csv (8 rows) x retail_sales.csv (20 rows)
# Usage: integration_test.sh <junit-output.xml>
# =============================================================================
set -uo pipefail

JUNIT_OUT="${1:-junit-integration.xml}"
CONTAINER="kyuubi-test"
JDBC_URL="jdbc:hive2://localhost:10009"

PASS=0; FAIL=0; CASES=""

record() {
  local name="$1" status="$2" msg="${3:-}"
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS+1)); CASES+="    <testcase classname=\"integration\" name=\"${name}\"/>\n"
    echo "PASS: ${name}"
  else
    FAIL=$((FAIL+1)); CASES+="    <testcase classname=\"integration\" name=\"${name}\"><failure message=\"${msg}\"/></testcase>\n"
    echo "FAIL: ${name} — ${msg}"
  fi
}

sql() { # run SQL via beeline inside the container, echo output
  docker exec "${CONTAINER}" /opt/kyuubi/bin/beeline \
    -u "${JDBC_URL}" --silent=true --outputformat=csv2 -e "$1" 2>&1
}

# --- TC-I01: JDBC connect; first connection launches the Spark SQL engine ---
echo "TC-I01: connecting via JDBC (launches Spark SQL engine, up to 300s)..."
OUT=$(timeout 300 docker exec "${CONTAINER}" /opt/kyuubi/bin/beeline \
  -u "${JDBC_URL}" --silent=true --outputformat=csv2 -e "SELECT 1 AS ok;" 2>&1)
echo "${OUT}" | grep -q "^1$"
record "jdbc_connect_and_engine_startup" $? "SELECT 1 failed: $(echo "${OUT}" | tail -3 | tr '\n' ' ')"

# --- Register the sample dataset as tables ------------------------------------
sql "CREATE TABLE IF NOT EXISTS stores   USING csv OPTIONS (path '/data/sample/stores.csv',       header 'true', inferSchema 'true');" >/dev/null
sql "CREATE TABLE IF NOT EXISTS products USING csv OPTIONS (path '/data/sample/products.csv',     header 'true', inferSchema 'true');" >/dev/null
sql "CREATE TABLE IF NOT EXISTS sales    USING csv OPTIONS (path '/data/sample/retail_sales.csv', header 'true', inferSchema 'true');" >/dev/null

# --- TC-I02: dimension ingestion ----------------------------------------------
OUT=$(sql "SELECT COUNT(*) FROM stores;");   S_CNT=$(echo "${OUT}" | tail -1)
OUT=$(sql "SELECT COUNT(*) FROM products;"); P_CNT=$(echo "${OUT}" | tail -1)
[ "${S_CNT}" = "5" ] && [ "${P_CNT}" = "8" ]
record "ingest_dimension_tables" $? "stores=${S_CNT} (want 5), products=${P_CNT} (want 8)"

# --- TC-I03: fact ingestion -----------------------------------------------------
OUT=$(sql "SELECT COUNT(*) FROM sales;"); F_CNT=$(echo "${OUT}" | tail -1)
[ "${F_CNT}" = "20" ]
record "ingest_fact_table" $? "sales=${F_CNT} (want 20)"

# --- TC-I04: analytics — revenue per region (3-way join) -----------------------
# Expected: 3 regions; London = 27.35 (S001) + 8.40 (S005) = 35.75
T_START=${SECONDS}
OUT=$(sql "SELECT st.region, ROUND(SUM(sa.quantity * sa.unit_price), 2) AS revenue
           FROM sales sa
           JOIN stores st   ON sa.store_id   = st.store_id
           JOIN products pr ON sa.product_id = pr.product_id
           GROUP BY st.region ORDER BY revenue DESC;")
T_JOIN=$(( SECONDS - T_START ))
REGIONS=$(echo "${OUT}" | grep -cE '^(London|North|South West),' || true)
echo "${OUT}" | grep -q "^London,35.75$"
LONDON_OK=$?
[ "${REGIONS}" = "3" ] && [ "${LONDON_OK}" -eq 0 ]
record "analytics_revenue_per_region" $? "regions=${REGIONS} (want 3), London row: $(echo "${OUT}" | grep '^London' || echo missing)"

# --- TC-I05: data quality — no null business keys -------------------------------
OUT=$(sql "SELECT COUNT(*) FROM sales WHERE store_id IS NULL OR product_id IS NULL;")
[ "$(echo "${OUT}" | tail -1)" = "0" ]
record "dq_no_null_keys" $? "null-key rows: $(echo "${OUT}" | tail -1)"

# --- TC-I06: data quality — no negative quantities or prices --------------------
OUT=$(sql "SELECT COUNT(*) FROM sales WHERE quantity <= 0 OR unit_price < 0;")
[ "$(echo "${OUT}" | tail -1)" = "0" ]
record "dq_no_negative_values" $? "invalid rows: $(echo "${OUT}" | tail -1)"

# --- TC-I07: data quality — referential integrity --------------------------------
OUT=$(sql "SELECT COUNT(*) FROM sales sa
           LEFT JOIN stores st   ON sa.store_id = st.store_id
           LEFT JOIN products pr ON sa.product_id = pr.product_id
           WHERE st.store_id IS NULL OR pr.product_id IS NULL;")
[ "$(echo "${OUT}" | tail -1)" = "0" ]
record "dq_referential_integrity" $? "orphan rows: $(echo "${OUT}" | tail -1)"

# --- TC-I08: performance budget — join finished within 60s -----------------------
[ "${T_JOIN}" -le 60 ]
record "perf_join_within_60s" $? "3-way join took ${T_JOIN}s (budget 60s)"
echo "INFO: revenue-per-region join took ${T_JOIN}s"

# --- TC-I09: runtime security — container runs as non-root -----------------------
UID_IN=$(docker exec "${CONTAINER}" id -u | tr -d '[:space:]')
[ -n "${UID_IN}" ] && [ "${UID_IN}" != "0" ]
record "runtime_non_root_user" $? "container UID=${UID_IN:-unknown} (must not be 0)"

# --- Cleanup ----------------------------------------------------------------------
sql "DROP TABLE IF EXISTS sales; DROP TABLE IF EXISTS products; DROP TABLE IF EXISTS stores;" >/dev/null || true

# --- Emit JUnit XML ----------------------------------------------------------------
TOTAL=$((PASS+FAIL))
mkdir -p "$(dirname "${JUNIT_OUT}")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"integration-tests\" tests=\"${TOTAL}\" failures=\"${FAIL}\">"
  printf "%b" "${CASES}"
  echo "</testsuite>"
} > "${JUNIT_OUT}"

echo "Integration tests: ${PASS}/${TOTAL} passed (${JUNIT_OUT})"
[ "${FAIL}" -eq 0 ]
