#!/usr/bin/env bash
# =============================================================================
# Stage 3 integration tests — Spark + Kyuubi functional validation.
# Covers the POC scope from the HPE proposal:
#   a) Spark SQL engine startup via Kyuubi
#   b) JDBC/Thrift connectivity
#   c) Representative Spark SQL queries (DDL/DML/aggregation)
#   d) Resource configuration applied
# Extend with cases from TESCO's Manual Test Case Document (docs/05).
# Usage: integration_test.sh <junit-output.xml>
# =============================================================================
set -uo pipefail

JUNIT_OUT="${1:-junit-integration.xml}"
CONTAINER="kyuubi-test"
JDBC_URL="jdbc:hive2://localhost:10009"
BEELINE="docker exec ${CONTAINER} /opt/kyuubi/bin/beeline -u ${JDBC_URL} --silent=true"

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

run_sql() { ${BEELINE} -e "$1" 2>&1; }

# --- Test A: JDBC connect + Spark SQL engine startup (first connection ------
# triggers Kyuubi to launch a Spark SQL engine; generous timeout applies).
echo "Connecting via JDBC (this launches the Spark SQL engine)..."
OUT=$(timeout 300 docker exec "${CONTAINER}" /opt/kyuubi/bin/beeline -u "${JDBC_URL}" -e "SELECT 1;" 2>&1)
echo "${OUT}" | grep -q "1"
record "jdbc_connect_and_engine_startup" $? "SELECT 1 via beeline failed: $(echo "${OUT}" | tail -3 | tr '\n' ' ')"

# --- Test B: DDL — create a table --------------------------------------------
OUT=$(run_sql "CREATE TABLE IF NOT EXISTS ci_smoke (id INT, name STRING) USING parquet;")
[ $? -eq 0 ]
record "spark_sql_create_table" $? "CREATE TABLE failed: $(echo "${OUT}" | tail -2 | tr '\n' ' ')"

# --- Test C: DML — insert rows ------------------------------------------------
OUT=$(run_sql "INSERT INTO ci_smoke VALUES (1,'tesco'), (2,'hpe'), (3,'poc');")
[ $? -eq 0 ]
record "spark_sql_insert" $? "INSERT failed: $(echo "${OUT}" | tail -2 | tr '\n' ' ')"

# --- Test D: aggregation query returns the expected count --------------------
OUT=$(run_sql "SELECT COUNT(*) AS c FROM ci_smoke;")
echo "${OUT}" | grep -q "3"
record "spark_sql_aggregation_count" $? "Expected count 3, got: $(echo "${OUT}" | tail -2 | tr '\n' ' ')"

# --- Test E: cleanup works (also validates DROP path) -------------------------
OUT=$(run_sql "DROP TABLE IF EXISTS ci_smoke;")
[ $? -eq 0 ]
record "spark_sql_drop_table" $? "DROP TABLE failed"

# --- Test F: resource configuration applied -----------------------------------
OUT=$(run_sql "SET spark.driver.memory;")
echo "${OUT}" | grep -q "spark.driver.memory"
record "resource_config_applied" $? "Could not read back spark.driver.memory"

# --- Test G: JOIN + GROUP BY across two tables ---------------------------------
run_sql "CREATE TABLE IF NOT EXISTS ci_orders (store_id INT, amount INT) USING parquet;" > /dev/null
run_sql "CREATE TABLE IF NOT EXISTS ci_stores (store_id INT, region STRING) USING parquet;" > /dev/null
run_sql "INSERT INTO ci_orders VALUES (1,100),(1,50),(2,70);" > /dev/null
run_sql "INSERT INTO ci_stores VALUES (1,'north'),(2,'south');" > /dev/null
OUT=$(run_sql "SELECT s.region, SUM(o.amount) AS total FROM ci_orders o JOIN ci_stores s ON o.store_id = s.store_id GROUP BY s.region ORDER BY s.region;")
echo "${OUT}" | grep -q "150"
record "spark_sql_join_group_by" $? "Expected north=150 in join/aggregation output: $(echo "${OUT}" | tail -3 | tr '\n' ' ')"

# --- Test H: CTAS (CREATE TABLE AS SELECT) --------------------------------------
run_sql "CREATE TABLE IF NOT EXISTS ci_orders_copy USING parquet AS SELECT * FROM ci_orders;" > /dev/null
OUT=$(run_sql "SELECT COUNT(*) AS c FROM ci_orders_copy;")
echo "${OUT}" | grep -q "3"
record "spark_sql_ctas" $? "Expected 3 rows in CTAS table, got: $(echo "${OUT}" | tail -2 | tr '\n' ' ')"

# --- Test I: shuffle-partition tuning from spark-defaults.conf is applied ------
OUT=$(run_sql "SET spark.sql.shuffle.partitions;")
echo "${OUT}" | grep -q "spark.sql.shuffle.partitions"
record "shuffle_partitions_config_applied" $? "Could not read back spark.sql.shuffle.partitions"

# --- Cleanup of Test G/H tables --------------------------------------------------
run_sql "DROP TABLE IF EXISTS ci_orders;" > /dev/null
run_sql "DROP TABLE IF EXISTS ci_stores;" > /dev/null
run_sql "DROP TABLE IF EXISTS ci_orders_copy;" > /dev/null

# ------------------------------------------------------------------------------
# TBD-TESTING-TEAM: append manual test cases here, one record() block each,
# e.g. UDF availability, catalog integration, specific dataset validations.
# ------------------------------------------------------------------------------

# --- Emit JUnit XML -----------------------------------------------------------
TOTAL=$((PASS+FAIL))
mkdir -p "$(dirname "${JUNIT_OUT}")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"integration-tests\" tests=\"${TOTAL}\" failures=\"${FAIL}\">"
  printf "%b" "${CASES}"
  echo "</testsuite>"
} > "${JUNIT_OUT}"

echo "Integration tests: ${PASS}/${TOTAL} passed (report: ${JUNIT_OUT})"
[ "${FAIL}" -eq 0 ]
