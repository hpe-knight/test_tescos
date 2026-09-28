# Sample Run Summary — what a healthy pipeline run looks like

## Pipeline Result: PASSED

| Stage | Result |
|-------|--------|
| 1 — Build & Lint | success |
| 2 — Security Scan & Gate | success |
| 3 — Dynamic Testing | success |

Image: `spark-kyuubi:9f2c1a7e3b4d5f6a7b8c9d0e1f2a3b4c5d6e7f80`

### Quality Gate

| Check | Found | Threshold | Result |
|-------|-------|-----------|--------|
| Critical vulnerabilities | 0 | <= 0 | PASS |
| High vulnerabilities | 6 | <= 10 | PASS |
| Embedded secrets | 0 | <= 0 | PASS |
| Dockle FATAL (CIS) | 0 | <= 0 | PASS |

QUALITY GATE: **PASSED** — proceeding to dynamic testing.

### Test results (from JUnit artifacts)

| Suite | Tests | Failures |
|-------|-------|----------|
| unit-tests (TC-U01..U06) | 6 | 0 |
| smoke-tests (TC-S01..S05) | 5 | 0 |
| integration-tests (TC-I01..I09) | 9 | 0 |

INFO: revenue-per-region join took 11s (budget 60s)

### Artifacts produced

- `stage1-build-reports/` — build.log, junit-unit.xml
- `stage2-security-reports/` — trivy-results.json, trivy-results.sarif,
  dockle-results.json/.txt, sbom.spdx.json, sbom.cyclonedx.json
- `stage3-test-reports/` — junit-smoke.xml, junit-integration.xml,
  container-logs.txt
