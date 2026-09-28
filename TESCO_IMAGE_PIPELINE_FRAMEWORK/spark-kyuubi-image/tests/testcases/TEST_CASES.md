# Sample Enterprise Test Case Document — Spark + Kyuubi Image

This is the **sample equivalent of the "Manual Test Case Document"** the
proposal expects from the testing team. Every case below is already automated;
the *Automated in* column names the script and the JUnit test name, so results
in CI trace back to this document 1:1. When real test cases arrive, extend or
replace rows here and mirror the change in the scripts.

**Test data:** `sample-data/` — a retail star schema
(5 stores / 8 products / 20 sales transactions) mounted read-only at
`/data/sample` during Stage 3.

---

## Suite U — Unit / Static Validation (Stage 1, `tests/unit/run_tests.sh`)

| ID | Test case | Expected result | Automated in |
|----|-----------|-----------------|--------------|
| TC-U01 | Base images are version-pinned | No `FROM …:latest` in Dockerfile | `dockerfile_no_latest_tag` |
| TC-U02 | Image declares a health probe | `HEALTHCHECK` present | `dockerfile_has_healthcheck` |
| TC-U03 | Image does not run as root | non-root `USER` instruction present | `dockerfile_non_root_user` |
| TC-U04 | Spark config file is syntactically valid | every non-comment line is `key value` | `spark_defaults_syntax` |
| TC-U05 | Kyuubi Thrift port explicitly configured | `kyuubi.frontend.thrift.binary.bind.port` set | `kyuubi_defaults_thrift_port` |
| TC-U06 | Sample dataset shipped and complete | 3 CSVs present with header rows | `sample_data_present` |

## Suite S — Smoke / Liveness (Stage 3, `tests/smoke/smoke_test.sh`)

| ID | Test case | Expected result | Automated in |
|----|-----------|-----------------|--------------|
| TC-S01 | Container reaches HEALTHY within budget | healthy ≤ 180 s | `container_healthy_within_180s` |
| TC-S02 | REST health endpoint responds | HTTP 200 from `/api/v1/ping` | `rest_ping_endpoint` |
| TC-S03 | JDBC/Thrift port accepting connections | TCP connect to 10009 succeeds | `thrift_port_10009_listening` |
| TC-S04 | Kyuubi server process running | `kyuubi` process visible | `kyuubi_process_running` |
| TC-S05 | Clean startup logs | no `FATAL` / `OutOfMemoryError` entries | `no_fatal_errors_in_logs` |

## Suite I — Integration / Functional / Data Quality (Stage 3, `tests/integration/integration_test.sh`)

| ID | Test case | Expected result | Automated in |
|----|-----------|-----------------|--------------|
| TC-I01 | Spark SQL engine startup via first JDBC connection | `SELECT 1` returns within 300 s | `jdbc_connect_and_engine_startup` |
| TC-I02 | CSV ingestion — dimension tables | stores=5 rows, products=8 rows | `ingest_dimension_tables` |
| TC-I03 | CSV ingestion — fact table | retail_sales=20 rows | `ingest_fact_table` |
| TC-I04 | Analytics: revenue per region (3-way join) | 3 regions; London revenue = 35.75 | `analytics_revenue_per_region` |
| TC-I05 | Data quality: no null business keys | 0 sales rows with null store/product id | `dq_no_null_keys` |
| TC-I06 | Data quality: no negative quantities/prices | 0 rows with quantity ≤ 0 or price < 0 | `dq_no_negative_values` |
| TC-I07 | Data quality: referential integrity | 0 sales referencing unknown store/product | `dq_referential_integrity` |
| TC-I08 | Performance budget | 3-way join aggregation completes ≤ 60 s | `perf_join_within_60s` |
| TC-I09 | Runtime security posture | container process UID ≠ 0 (non-root) | `runtime_non_root_user` |

## Pass/Fail Criteria

- A suite passes only if **all** of its cases pass (JUnit `failures="0"`).
- Stage 3 runs only after the security **Quality Gate** passes
  (0 critical CVEs, ≤ 10 high, no secrets, no Dockle FATAL — see
  `config/pipeline-config.yml`).
- The pipeline is green only when Suites U, S, and I all pass.
