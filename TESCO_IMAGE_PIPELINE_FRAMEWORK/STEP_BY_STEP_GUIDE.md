# STEP-BY-STEP GUIDE — From Zero to a Green Pipeline

This guide takes you from an empty machine to a fully working image-testing
pipeline, first **locally** (10 minutes, Docker only), then on **GitHub
Actions**, then shows how to read results, handle failures, and extend the
framework. No accounts, tokens, or testing-team inputs are required.

---

## PART 1 — Run the Whole Pipeline Locally (10 minutes)

### Step 1.1 — Prerequisites (the only hard requirement is Docker)

| Tool | Needed for | Check |
|---|---|---|
| Docker Desktop / Engine 24+ with Compose v2 | everything | `docker version && docker compose version` |
| Bash shell (Linux, macOS, WSL2, or Git Bash on Windows) | running the scripts | `bash --version` |

> 🪟 **Windows:** open **Git Bash** or a **WSL2** terminal in this folder.
> All scanners (Hadolint, Trivy, Dockle, Syft) run as Docker containers, so
> nothing else needs installing.

### Step 1.2 — Run it

```bash
cd TESCO_IMAGE_PIPELINE_FRAMEWORK
bash scripts/run_local_pipeline.sh
```

What happens, in order (mirrors the CI pipeline exactly):

1. **Lint** — Hadolint checks `spark-kyuubi-image/Dockerfile`.
2. **Build** — Buildx builds the multi-stage Spark+Kyuubi image
   (`spark-kyuubi:local`). First build downloads ~700 MB of Spark/Kyuubi —
   later builds are cached and take seconds.
3. **Unit tests** — static validation of Dockerfile/configs → `reports/stage1/`.
4. **Trivy** — CVE + secret scan → `reports/stage2/trivy-results.json`.
5. **Dockle** — CIS Docker Benchmark → `reports/stage2/dockle-results.json`.
6. **Syft** — SBOM (SPDX + CycloneDX) → `reports/stage2/sbom.*.json`.
7. **Quality Gate** — thresholds from `config/pipeline-config.yml`; prints a
   pass/fail table. Failure stops here (exactly like CI).
8. **Dynamic tests** — starts the container with the **sample retail data**
   mounted, waits for healthy, runs smoke + integration suites (JDBC, SQL
   joins, data-quality, performance budget) → `reports/stage3/`.
9. **Summary** — one table with every stage result; exit code 0 = all green.

### Step 1.3 — Look at what it produced

```text
reports/
├── stage1/junit-unit.xml            # unit checks (TC-U01..)
├── stage2/trivy-results.json        # every CVE found, with severity + fix version
├── stage2/dockle-results.json/.txt  # CIS benchmark results
├── stage2/sbom.spdx.json            # full component inventory (compliance-ready)
├── stage2/sbom.cyclonedx.json
├── stage3/junit-smoke.xml           # liveness checks (TC-S01..)
├── stage3/junit-integration.xml     # functional/data-quality/perf (TC-I01..)
└── stage3/container-logs.txt        # full Kyuubi/Spark logs from the test run
```

Compare with `samples/sample-run-summary.md` to see what a healthy run looks
like. Every JUnit `<testcase name>` matches a test-case ID documented in
`spark-kyuubi-image/tests/testcases/TEST_CASES.md`.

---

## PART 2 — Run It on GitHub Actions (CI)

### Step 2.1 — Create the repository

```bash
cd TESCO_IMAGE_PIPELINE_FRAMEWORK
git init -b main
git add -A
# Linux runners need the exec bit on shell scripts (important when pushing from Windows):
git update-index --chmod=+x scripts/*.sh spark-kyuubi-image/tests/*/*.sh
git commit -m "TESCO image testing pipeline framework"
git remote add origin https://github.com/<org>/<repo>.git
git push -u origin main
```

> ⚠️ This folder must be the **repository root** — GitHub only discovers
> workflows at `.github/workflows/` of the root.

### Step 2.2 — First run (zero configuration)

Repo → **Actions** → *Docker Image Testing & Scanning Pipeline* →
**Run workflow** → `main`. The push in Step 2.1 also triggers it automatically.

You get, with **no secrets configured at all**:

- ✅ all three stages + quality gate,
- ✅ Trivy findings in the repo **Security → Code scanning** tab (SARIF),
- ✅ all reports as downloadable artifacts,
- ✅ a result table on the run's **Summary** page,
- ⏭️ notifications and S3 upload steps log "not configured — skipping".

### Step 2.3 — (Optional) turn on notifications and archival

Add these when ready — each activates automatically on the next run:

| Setting | Type | Effect |
|---|---|---|
| `SLACK_WEBHOOK_URL` | secret | Slack message on every run (see `samples/sample-notification-*.json`) |
| `TEAMS_WEBHOOK_URL` | secret | Teams MessageCard on every run |
| `S3_BUCKET` | variable | reports archived to `s3://<bucket>/<image>/<git-sha>/…` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | secrets | S3 credentials (or switch to OIDC later) |
| `S3_ENDPOINT_URL` | variable | set only for Ceph RGW; empty = AWS S3 |

### Step 2.4 — (Recommended) protect `main`

Settings → Branches → protection rule on `main`: require pull requests and
require all four pipeline jobs as passing status checks. From then on, no
image change can merge without a fully green pipeline.

---

## PART 3 — Understand the Enterprise Sample Scenario

### The data (`spark-kyuubi-image/sample-data/`)

A retail star schema — small enough for CI, shaped like production:

| File | Contents | Role |
|---|---|---|
| `stores.csv` | 5 UK stores across 3 regions | dimension |
| `products.csv` | 8 grocery SKUs in 4 categories | dimension |
| `retail_sales.csv` | 20 sales transactions | fact |

### The test cases (`tests/testcases/TEST_CASES.md`)

A sample **enterprise Manual Test Case Document** — the artifact the real
testing team would normally supply — already fully automated:

| ID range | Suite | Covers |
|---|---|---|
| TC-U01…U06 | unit | Dockerfile hygiene: pinned versions, non-root, HEALTHCHECK, config syntax |
| TC-S01…S05 | smoke | container healthy in time, REST ping, Thrift port, process up, clean logs |
| TC-I01…I09 | integration | engine startup, CSV ingestion, 3-way join analytics, data quality (null keys, negative quantities, referential integrity), performance budget, non-root runtime check |

When the real checklist eventually arrives, you edit **only** the test
scripts and `TEST_CASES.md` — the pipeline machinery does not change.

---

## PART 4 — Read Results & Handle Failures

### Where to look first

1. Run page → **Summary** tab: stage table + quality-gate table.
2. The failed job's log: the failing step is expanded automatically.
3. The stage's artifact: JUnit XML names the exact failing check;
   `container-logs.txt` has the root cause for Stage 3.

### Failure playbook

| Failure | Meaning | Fix |
|---|---|---|
| Hadolint step red | Dockerfile violates a lint rule | fix the reported line; only ignore rules in `.hadolint.yaml` with a written justification |
| Build step red | download/checksum/syntax error | check `ARG` versions in the Dockerfile; Apache archive URLs must match the version |
| Unit test red (TC-U*) | image hygiene regression (e.g., `USER` removed) | restore the required property — don't delete the test |
| **Quality gate red** | CVEs/secrets over threshold | prefer upgrading the base image or package (Trivy JSON shows `FixedVersion`); for genuine accepted risks add a **time-boxed** entry to `config/allowlist.yml`; never bump thresholds casually |
| Secret found | credential baked into a layer | **rotate the credential first**, then remove it from the build |
| TC-S01 (health timeout) | slow start or crash loop | read `container-logs.txt`; only raise `startup_timeout_seconds` in `config/pipeline-config.yml` if it is genuinely just slow |
| TC-I01 (engine startup) | Spark SQL engine failed under Kyuubi | usually memory/config — check `conf/spark-defaults.conf` and engine logs |
| TC-I05/06/07 (data quality) | the image mangles data | a real regression — bisect the Dockerfile/config change that caused it |
| TC-I08 (performance) | join exceeded 60 s budget | check resource configs; compare with a previous green run's timing |
| Notify/S3 step warning | optional integration misconfigured | non-blocking; fix webhook/bucket settings |

### Reproduce any Stage 3 failure locally

```bash
cd spark-kyuubi-image
docker buildx build -t spark-kyuubi:local --load .
TEST_IMAGE=spark-kyuubi:local docker compose -f docker-compose.test.yml up -d
bash tests/smoke/smoke_test.sh /tmp/junit-smoke.xml
bash tests/integration/integration_test.sh /tmp/junit-int.xml
docker compose -f docker-compose.test.yml down -v
```

---

## PART 5 — Operate & Extend

### Tuning thresholds
All in `config/pipeline-config.yml` (`quality_gate:` block). Changes are code:
raise a PR, and treat loosening as a security decision needing review.

### Risk-accepting a CVE
Add to `config/allowlist.yml` with `id`, `reason`, `approved_by`, `expires`.
Expired entries automatically count again. A worked example is in the file.

### Adding a test case
1. Document it in `TEST_CASES.md` with the next TC-I number.
2. Add a `run_case` block in `tests/integration/integration_test.sh`
   (copy an existing one — JUnit reporting is automatic).

### Weekly CVE re-scans
`.github/workflows/periodic-rescan.yml` re-scans listed image references every
Monday and fails loudly on new criticals. Add production image refs to its
`matrix.image` list as images are released.

### Onboarding the next image
Copy `spark-kyuubi-image/` as a template: new Dockerfile + compose file +
sample data + tests. Point the workflow at it via the `image_dir` /
`image_name` inputs on *Run workflow*, or duplicate the workflow per image.

### Swapping in Snyk (TESCO's existing tool) later
Trivy was chosen so the framework runs with zero accounts. To add Snyk:
add a `SNYK_TOKEN` secret and drop the commented **Snyk (optional)** step in
`.github/workflows/image-pipeline.yml` back in — the gate then evaluates both
scanners' outputs.

### Routine calendar

| Cadence | Task |
|---|---|
| every PR | review code + run Summary; security-sensitive files need security review |
| weekly | triage periodic re-scan findings; check allowlist entries expiring soon |
| monthly | bump pinned scanner/action versions via PR |
| quarterly | re-baseline thresholds and test coverage |
