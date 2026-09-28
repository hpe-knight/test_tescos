# 05 — Discovery Checklist: Inputs Required from the TESCO Testing Team

Master list of everything the framework needs from the testing/stakeholder
teams. Each item states **where the answer gets applied** — every open
placeholder in the repo is tagged `TBD-TESTING-TEAM` and traces back here.

Status legend: ⬜ open · ✅ collected & applied

---

## A. Current Manual Testing Process (highest priority)

| # | Question | Applied in | Status |
|---|---|---|---|
| A1 | Full step-by-step manual test checklist per image (the **Manual Test Case Document**) | `tests/integration/integration_test.sh` — one automated check per manual step | ⬜ |
| A2 | Success/failure criteria for each manual check | Same, as assertions | ⬜ |
| A3 | Tools currently used during manual testing | May add pipeline steps/sidecars | ⬜ |
| A4 | Teams involved and hand-off points | RACI in docs/03 Part 6 | ⬜ |
| A5 | How long each manual phase takes (baseline for the <1 hour target) | POC review metrics | ⬜ |

## B. Spark + Kyuubi Specifics

| # | Question | Applied in | Status |
|---|---|---|---|
| B1 | Exact Spark & Kyuubi versions (and Hadoop profile) used in production | `Dockerfile` ARGs | ⬜ |
| B2 | Production resource configuration (driver/executor memory, cores, shuffle) | `conf/spark-defaults.conf` + resource-config test | ⬜ |
| B3 | Engine deployment mode (local / YARN / Kubernetes) and share level | `conf/kyuubi-defaults.conf` | ⬜ |
| B4 | Authentication (LDAP / Kerberos / none) on Kyuubi frontends | `kyuubi-defaults.conf` + connectivity tests | ⬜ |
| B5 | Required catalogs/metastore (Hive metastore? which DB?) | `docker-compose.test.yml` sidecars | ⬜ |
| B6 | Representative SQL workloads/datasets for validation | Integration test cases | ⬜ |

## C. Security & Compliance

| # | Question | Applied in | Status |
|---|---|---|---|
| C1 | Acceptable vulnerability thresholds (critical/high budgets) | `config/pipeline-config.yml → quality_gate` | ⬜ |
| C2 | Risk-acceptance approval process & approvers | `config/allowlist.yml` + CODEOWNERS | ⬜ |
| C3 | Is image signing (Cosign) required? Key management approach? | docs/02 §9, workflow step | ⬜ |
| C4 | Compliance/regulatory requirements (SBOM sharing, formats, recipients) | Syft formats + archive retention | ⬜ |
| C5 | Report retention period in S3/Ceph | Bucket lifecycle rules | ⬜ |

## D. Notifications & Escalation

| # | Question | Applied in | Status |
|---|---|---|---|
| D1 | Channels: Slack, Email, Teams, Jira — which, and per team? | Secrets + `scripts/notify.sh` routing | ⬜ |
| D2 | Escalation matrix: who is paged per stage failure and severity | `pipeline-config.yml → notifications.routing`, docs/03 RACI | ⬜ |
| D3 | Which teams receive pass reports (vs. failure-only)? | `notify.sh` conditions | ⬜ |

## E. Infrastructure

| # | Question | Applied in | Status |
|---|---|---|---|
| E1 | Storage target: AWS S3 or Ceph? Bucket, endpoint, credentials/OIDC | Repo variables `S3_BUCKET`, `S3_ENDPOINT_URL` | ⬜ |
| E2 | Container registry for built images (and for large-image hand-off) | Workflow push steps, docs/02 §8 | ⬜ |
| E3 | GitHub runner strategy: hosted / larger / self-hosted | Workflow `runs-on`, docs/01 §8 | ⬜ |
| E4 | Frequency of periodic vulnerability re-scans | `periodic-rescan.yml` cron | ⬜ |
| E5 | List of production images to enroll in re-scans | `periodic-rescan.yml` matrix | ⬜ |

## F. Rollout

| # | Question | Applied in | Status |
|---|---|---|---|
| F1 | Priority order of remaining images to onboard after the POC | docs/04 register | ⬜ |
| F2 | Owning team per image | docs/04 register + routing | ⬜ |

---

## How to apply an answer

1. Find the placeholder: search the repo for `TBD-TESTING-TEAM`.
2. Update the referenced file(s) on a branch; flip the status here to ✅ in
   the same PR (this document doubles as the discovery log).
3. Merge — the pipeline validates the change automatically.
