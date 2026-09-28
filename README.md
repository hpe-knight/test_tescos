# TESCO — Automated Docker Image Testing & Scanning Pipeline (Prototype Framework)

End-to-end, production-grade **prototype** CI/CD framework for automated building,
security scanning, and dynamic testing of Docker container images, per the HPE
proposal to TESCO. POC target: **Apache Spark + Kyuubi** stack.

> ⚠️ **Status: PROTOTYPE.** Everything marked `TBD-TESTING-TEAM` in
> `config/pipeline-config.yml` and `docs/05_DISCOVERY_CHECKLIST_FOR_TESTING_TEAM.md`
> must be collected from the TESCO testing team, after which the framework is
> tuned accordingly. The pipeline runs end to end today with safe defaults.

---

## Repository Layout

```text
TESCO_CICD/
├── README.md                          <- You are here
├── .github/
│   └── workflows/
│       ├── image-pipeline.yml         <- Main pipeline (Stages 1-3 + gate + reports)
│       └── periodic-rescan.yml        <- Scheduled vulnerability re-scan
├── spark-kyuubi-image/                <- POC image: Apache Spark + Kyuubi
│   ├── Dockerfile                     <- Multi-stage, non-root, HEALTHCHECK
│   ├── .dockerignore
│   ├── .hadolint.yaml                 <- Dockerfile lint rules
│   ├── docker-compose.test.yml        <- Stage 3 dynamic test environment
│   ├── conf/
│   │   ├── spark-defaults.conf
│   │   └── kyuubi-defaults.conf
│   └── tests/
│       ├── unit/run_tests.sh          <- Config/script validation (JUnit output)
│       ├── smoke/smoke_test.sh        <- Health, ports, process checks
│       └── integration/integration_test.sh  <- JDBC/Thrift + Spark SQL tests
├── scripts/
│   ├── quality_gate.sh                <- Enforces security thresholds
│   ├── notify.sh                      <- Slack/Teams success & failure alerts
│   └── upload_to_s3.sh                <- Archive reports/SBOM to S3 or Ceph
├── config/
│   ├── pipeline-config.yml            <- Central config + TBD placeholders
│   └── allowlist.yml                  <- Security-approved vulnerability exceptions
└── docs/
    ├── 01_PREREQUISITES_AND_TOOLS_SETUP.md
    ├── 02_CONFIGURATION_GUIDE.md
    ├── 03_PIPELINE_MANAGEMENT_GUIDE.md    <- Step-by-step CI/CD operations guide
    ├── 04_ONBOARDING_NEW_IMAGES.md
    └── 05_DISCOVERY_CHECKLIST_FOR_TESTING_TEAM.md
```

## Pipeline at a Glance

```mermaid
flowchart LR
    A[Push / PR] --> B[Stage 1<br/>Build & Lint]
    B --> C[Stage 2<br/>Snyk + Dockle + Syft]
    C --> D{Quality Gate}
    D -->|pass| E[Stage 3<br/>Dynamic Testing]
    D -->|fail| F[Notify + Reports]
    E --> F
    F --> G[(S3 / Ceph archive)]
```

| Stage | Job in workflow | Tools | Blocks pipeline on |
|-------|-----------------|-------|--------------------|
| 1. Build & Lint | `build-and-lint` | Buildx, Hadolint, unit tests | Lint errors, build failure, unit test failure |
| 2. Security Scan | `security-scan` | Snyk, Dockle, Syft | — (reports only; gate decides) |
| Quality Gate | `security-scan` (last step) | `scripts/quality_gate.sh` | Critical CVEs, secrets, fatal CIS violations |
| 3. Dynamic Test | `dynamic-test` | docker compose, beeline, spark-sql | Health/smoke/integration failures |
| Report & Notify | `report-and-notify` | Slack/Teams webhook, S3 sync | Never (runs `always()`) |

## Quick Start

1. Read **`docs/01_PREREQUISITES_AND_TOOLS_SETUP.md`** — install tools, create
   GitHub secrets, connect Snyk / S3 / Slack.
2. Push this folder to a GitHub repository (this directory is the repo root —
   `.github/workflows/` must sit at the root).
3. Open **Actions → Docker Image Testing & Scanning Pipeline → Run workflow**
   to trigger the first run manually, or push any change under
   `spark-kyuubi-image/`.
4. Review artifacts and the Security tab; then follow
   **`docs/03_PIPELINE_MANAGEMENT_GUIDE.md`** for day-to-day operation.

## Design Principles

- **Fail fast, report always** — every stage uploads its reports even on failure;
  the notify job runs unconditionally.
- **Gate is code** — thresholds live in `config/pipeline-config.yml` and
  `scripts/quality_gate.sh`, reviewed like any other change.
- **Exceptions are auditable** — accepted risks go in `config/allowlist.yml`
  with owner + expiry, never as silent flag changes.
- **Everything TBD is explicit** — placeholders reference the discovery
  checklist so nothing from the testing team gets lost.
