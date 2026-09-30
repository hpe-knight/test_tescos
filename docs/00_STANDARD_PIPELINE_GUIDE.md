# TESCO Image Testing & Scanning Pipeline — Standard Engineer's Guide

> **Audience:** any engineer joining this project. Reading this one document should
> be enough to understand what the pipeline does, run it, read its results,
> tune every parameter, onboard a new image, and troubleshoot failures.
>
> Repo: `hpe-knight/test_tescos` · Branch: `main` · CI: GitHub Actions
> Status: both workflows green end-to-end as of 2026-09-30.

---

## 1. What this pipeline does

Every change to the image sources is automatically **built, linted, security-scanned,
gated against thresholds, and functionally tested** before it can be considered
releasable. Reports are archived and teams notified on every run, pass or fail.

```
 push / PR / manual
        │
        ▼
┌─────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────┐
│ STAGE 1             │   │ STAGE 2                  │   │ STAGE 3             │
│ Build & Lint        │──▶│ Security Scan +          │──▶│ Dynamic Testing     │
│ · Hadolint          │   │ Quality Gate             │   │ · container spin-up │
│ · docker build      │   │ · Snyk (CVEs)            │   │ · smoke tests       │
│ · unit tests        │   │ · Dockle (CIS bench)     │   │ · integration tests │
│ · save image.tar    │   │ · Syft (SBOM)            │   │   (Spark SQL/JDBC)  │
└─────────────────────┘   │ · GATE: pass/block ──────┤   └──────────┬──────────┘
                          └──────────────────────────┘              │
        ┌───────────────────────────────────────────────────────────┤
        ▼                                                           ▼
┌──────────────────────────────┐      ┌────────────────────────────────────────┐
│ REPORTS, NOTIFY & ARCHIVE    │      │ PUBLISH (main branch only, all stages  │
│ (always runs, even on fail)  │      │ green): push <ns>/spark-kyuubi:<sha>   │
│ · collect all reports        │      │ and :latest to Docker Hub              │
│ · S3/Ceph archival           │      └───────────────────┬────────────────────┘
│ · Slack/Teams notification   │                          ▼
│ · run summary                │      ┌────────────────────────────────────────┐
└──────────────────────────────┘      │ PERIODIC VULNERABILITY RE-SCAN         │
                                      │ (weekly + manual) re-pulls & re-scans  │
                                      │ the published :latest for NEW CVEs     │
                                      └────────────────────────────────────────┘
```

The gate is the control point: **Stage 3 only runs if Stage 2's quality gate
passes** (thresholds in `config/pipeline-config.yml`).

---

## 2. Repository layout

| Path | Purpose |
|------|---------|
| `.github/workflows/image-pipeline.yml` | Main 3-stage pipeline (this guide, §4) |
| `.github/workflows/periodic-rescan.yml` | Scheduled re-scan of approved images (§5) |
| `spark-kyuubi-image/` | The POC image: Dockerfile, configs, tests |
| `spark-kyuubi-image/Dockerfile` | Multi-stage build (downloader → minimal JRE runtime) |
| `spark-kyuubi-image/.hadolint.yaml` | Dockerfile lint rules |
| `spark-kyuubi-image/docker-compose.test.yml` | Stage 3 test environment |
| `spark-kyuubi-image/tests/{unit,smoke,integration}/` | Test suites (§7) |
| `scripts/quality_gate.sh` | Pass/fail decision from scan results (§6) |
| `scripts/notify.sh` | Slack/Teams webhooks |
| `scripts/upload_to_s3.sh` | S3/Ceph archival |
| `config/pipeline-config.yml` | **Central tunables** (§8) |
| `config/allowlist.yml` | Time-boxed, approved vulnerability exceptions (§9) |
| `docs/01–05_*.md` | Prerequisites, configuration, management, onboarding, discovery checklist |
| `TESCO_IMAGE_PIPELINE_FRAMEWORK/` | Self-contained sample copy of the framework (not run by CI) |

---

## 3. Credentials & settings (GitHub → repo → Settings)

| Name | Kind | Currently set? | Used for |
|------|------|----------------|----------|
| `SNYK_TOKEN` | **Secret** | ✅ | Snyk authentication. Workflows read `secrets.SNYK_TOKEN \|\| vars.SNYK_TOKEN`. Without either, the Snyk steps are skipped and the gate warns instead of failing. |
| `DOCKERHUB_USERNAME` | Variable | ✅ (`hpeknight`) | Docker Hub login user (not sensitive). Login and publish steps are skipped entirely when unset. |
| `DOCKERHUB_TOKEN` | **Secret** | ✅ | Docker Hub password/PAT for login and publish (`secrets.DOCKERHUB_TOKEN \|\| vars.DOCKERHUB_TOKEN`). Must have **write** scope for the publish job to push. |
| `DOCKERHUB_NAMESPACE` | Variable | ❌ (optional) | Overrides the Hub namespace for pushed images when it differs from the login user (e.g. an organization). Defaults to `DOCKERHUB_USERNAME`. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Secrets | ❌ | S3/Ceph archival. Upload self-skips when `S3_BUCKET` is unset. |
| `S3_BUCKET`, `S3_ENDPOINT_URL`, `AWS_REGION` | Variables | ❌ | Bucket name; endpoint (set only for Ceph RGW); region (default `eu-west-1`). |
| `SLACK_WEBHOOK_URL` / `TEAMS_WEBHOOK_URL` | Secrets | ❌ | Notifications. Each channel self-skips when unset. |

> **Security note:** `SNYK_TOKEN` and `DOCKERHUB_TOKEN` were migrated from
> Actions variables to encrypted secrets (variables are not masked in logs;
> secrets are). Rotate both tokens periodically. GitHub secrets are created via
> the API using libsodium sealed-box encryption or simply via the repo UI:
> Settings → Secrets and variables → Actions.

---

## 4. Workflow 1 — `image-pipeline.yml` (Docker Image Testing & Scanning Pipeline)

### Triggers

| Trigger | When |
|---------|------|
| `push` to `main` | Only when files under `spark-kyuubi-image/**`, `scripts/**`, `config/**`, or the workflow file change |
| `pull_request` to `main` | Every PR |
| `workflow_dispatch` | Manual run — Actions tab → *Docker Image Testing & Scanning Pipeline* → *Run workflow*. Optional input `image_dir` (default `spark-kyuubi-image`) selects which image directory to build |

### Global environment

| Variable | Value | Meaning |
|----------|-------|---------|
| `IMAGE_NAME` | `spark-kyuubi` | Local tag name for the built image |
| `IMAGE_DIR` | `github.event.inputs.image_dir` or `spark-kyuubi-image` | Repo-relative directory containing the Dockerfile, configs and tests |
| `IMAGE_TAG` | `${{ github.sha }}` | Commit SHA — every run tests a uniquely-tagged image |

Permissions: `contents: read`, `security-events: write` (SARIF upload to the
Security tab), `actions: read`.

### Stage 1 — Build & Lint (job `build-and-lint`)

1. **Hadolint** lints `<IMAGE_DIR>/Dockerfile` against `<IMAGE_DIR>/.hadolint.yaml`. Lint errors fail the run immediately.
2. **Login to Docker Hub** *(skipped when `DOCKERHUB_USERNAME` unset)* — authenticated base-image pulls.
3. **docker build** via Buildx with the **GitHub Actions layer cache** (`cache-from/to: type=gha`). First build ≈ 15 min (Apache archive downloads); cached builds ≈ 1–2 min.
4. **Unit tests** (`tests/unit/run_tests.sh`) validate the Dockerfile and configs *before* anything runs: no `:latest` base, `HEALTHCHECK` present, non-root `USER`, config file syntax, test scripts present. Emits JUnit XML.
5. The image is exported (`docker save`) and handed to later jobs as the **`docker-image` artifact** (1-day retention). For very large images switch to a registry push/pull — see `docs/02`, "Large image strategy".

### Stage 2 — Security Scan & Quality Gate (job `security-scan`, needs Stage 1)

1. Loads `image.tar`.
2. **Snyk container scan** — vulnerabilities in OS packages *and* bundled application dependencies. Produces `snyk-results.json`, SARIF (uploaded to the **GitHub Security tab**, category `snyk-container`), and a stakeholder-readable HTML report. Runs `continue-on-error` so all reports are always produced; the *gate* makes the pass/fail decision. Skipped (with a warning) when no Snyk token is configured.
3. **Dockle** — CIS Docker Benchmark check of the final image (JSON + text output).
4. **Syft** — SBOM generation in SPDX-JSON and CycloneDX-JSON.
5. **Quality Gate** (`scripts/quality_gate.sh`, §6) — the only step here allowed to fail the job. `set -o pipefail` is required on this step: it pipes through `tee` into the run summary, and without pipefail `tee` would mask the gate's exit code (this was a real bug — do not remove it).

### Stage 3 — Dynamic Testing (job `dynamic-test`, needs Stage 2)

1. Loads the image and starts it with `docker-compose.test.yml` (`TEST_IMAGE=spark-kyuubi:<sha>`).
2. **Smoke tests** (`tests/smoke/smoke_test.sh`): container reaches Docker-healthy within **300 s**, REST `/api/v1/ping` answers on 10099, Thrift port 10009 listening, kyuubi process running, no FATAL/OOM in logs.
3. **Integration tests** (`tests/integration/integration_test.sh`): first JDBC connection via beeline (launches the Spark SQL engine, 300 s budget), then `CREATE TABLE` / `INSERT` / `COUNT(*)` / `DROP TABLE` / `SET spark.driver.memory` — DDL, DML, aggregation and resource-config verification.
4. Container logs are always collected and uploaded; the compose environment is torn down.

### Publish (job `publish`, needs all three stages)

Runs **only on non-PR events** (pushes to `main`, manual dispatches) and only when
`DOCKERHUB_USERNAME` is configured — pull requests never publish. Loads the tested
`image.tar`, logs in to Docker Hub, and pushes two tags to
`<DOCKERHUB_NAMESPACE|DOCKERHUB_USERNAME>/spark-kyuubi`:

- `:<git-sha>` — immutable, traceable back to the exact commit and CI run;
- `:latest` — rolling pointer to the newest fully tested image; this is what the
  periodic re-scan workflow pulls and re-scans.

The published references are written to the run summary.

### Reports, Notify & Archive (job `report-and-notify`, `if: always()`)

Runs on success **and** failure: downloads all `stage*-*` artifacts, computes the
overall result, archives everything to S3/Ceph
(layout `s3://<bucket>/<image>/<sha>/<stage>/…`), sends Slack/Teams notifications
(first failed stage is identified in the alert), and writes the run summary table.

### Artifacts produced per run

| Artifact | Contents |
|----------|----------|
| `docker-image` | `image.tar` (1-day retention, internal hand-off) |
| `stage1-build-reports` | `junit-unit.xml` |
| `stage2-security-reports` | `snyk-results.json/.sarif`, `snyk-report.html`, `dockle-results.json/.txt`, `sbom.spdx.json`, `sbom.cyclonedx.json` |
| `stage3-test-reports` | `junit-smoke.xml`, `junit-integration.xml`, `container-logs.txt` |

---

## 5. Workflow 2 — `periodic-rescan.yml` (Periodic Vulnerability Re-Scan)

**Why it exists:** new CVEs are published daily — an image that passed last month
may be vulnerable today, with zero code changes.

- **Triggers:** cron `23 4 * * 1` (Mondays 04:23 UTC) + `workflow_dispatch` for on-demand re-scans.
- **Matrix `image:` list** — currently `hpeknight/spark-kyuubi:latest`, which the main pipeline's publish job refreshes on every successful main-branch run. Add further references as images are onboarded.
- Flow per image: Docker Hub login (optional) → pull → Snyk re-scan → evaluate with the same `quality_gate.sh` and thresholds → archive report → **alert the Security team** (Slack/Teams) if thresholds are breached or the pull failed.

---

## 6. The Quality Gate — `scripts/quality_gate.sh`

**Usage:** `quality_gate.sh <snyk.json> <dockle.json|""> <pipeline-config.yml> <allowlist.yml>`
Exit 0 = proceed to Stage 3; exit 1 = pipeline blocked.

Decision logic, in order:

1. Read `max_critical` / `max_high` from `config/pipeline-config.yml` (values are validated as numbers; bad values fall back to 0/5 with a warning).
2. Collect **unexpired** allowlist IDs from `config/allowlist.yml` and exclude them from counting.
3. Count **unique** Snyk vulnerability IDs by severity for the **OS-level project** (base image packages — what the image owner can actually fix). Snyk repeats one ID per dependency path, so counting unique IDs avoids e.g. one openssl CVE showing up as 7 findings.
4. Bundled **application dependencies** (Spark/Kyuubi jars): counted the same way (unique IDs, allowlist applied). By default they are only *reported* as an informational row; set `quality_gate.gate_app_dependencies: true` in the config to enforce `max_app_critical` / `max_app_high` once TESCO agrees the policy. Roughly 11 critical / 103 high unique IDs exist today; fixing them means moving to newer Spark/Kyuubi releases, not changing the image.
5. Count Dockle `FATAL` findings — threshold is always 0.
6. Special cases: Snyk skipped for lack of token → warn, don't fail. Snyk *ran* but produced no JSON → **fail** (no scan evidence is treated as unsafe).

Result table (also appears in the run summary):

```
| Check                          | Found | Threshold | Result |
| Critical vulnerabilities (OS)  |   0   |  <= 0     | PASS   |
| High vulnerabilities (OS)      |   0   |  <= 5     | PASS   |
| Dockle FATAL (CIS)             |   0   |  <= 0     | PASS   |
| App deps critical/high (informational, policy TBD) | 11/103 | n/a | INFO |
```

---

## 7. Test suites — where to add test cases

| Suite | File | Runs | Add cases for |
|-------|------|------|---------------|
| Unit | `tests/unit/run_tests.sh` | Stage 1, before build artifacts move on | Config/Dockerfile invariants (each check is a `record "name" <0/1> "msg"` block) |
| Smoke | `tests/smoke/smoke_test.sh` | Stage 3, against the running container | Liveness: ports, endpoints, processes, log hygiene |
| Integration | `tests/integration/integration_test.sh` | Stage 3 | Functional SQL/JDBC cases: JDBC connect + engine startup, `CREATE`/`INSERT`/`COUNT`/`DROP`, JOIN + GROUP BY across tables, CTAS, resource & shuffle-partition config checks. Append one `record()` block per case from TESCO's Manual Test Case Document (see marker `TBD-TESTING-TEAM` in the file) |

All three emit JUnit XML, so results integrate with any JUnit-aware tooling.

---

## 8. Central tunables — `config/pipeline-config.yml`

| Key | Default | Effect |
|-----|---------|--------|
| `quality_gate.max_critical` | `0` | Max allowed **unique, unallowlisted** critical OS CVEs. Exceeding blocks Stage 3. |
| `quality_gate.max_high` | `5` | Same for high severity. |
| `quality_gate.fail_on_secrets` | `true` | Any detected secret blocks the pipeline. |
| `quality_gate.dockle_exit_level` | `fatal` | Dockle level that counts against the gate. |
| `quality_gate.gate_app_dependencies` | `false` | `true` = enforce the app-dependency thresholds below; `false` = report app-dependency counts informationally only (policy pending TESCO sign-off). |
| `quality_gate.max_app_critical` | `0` | Max unique critical CVEs in bundled app dependencies (only when gating enabled). |
| `quality_gate.max_app_high` | `10` | Same for high severity. |
| `scanning.snyk.severity_threshold` | `high` | Snyk reporting threshold. |
| `scanning.snyk.sarif_to_security_tab` | `true` | Upload SARIF to the GitHub Security tab. |
| `dynamic_testing.startup_timeout_seconds` | `300` | Container health budget (Spark+Kyuubi needs ~3 min on 2-core runners; 180 was too tight). Mirrored in `smoke_test.sh`. |
| `dynamic_testing.engine_startup_timeout_seconds` | `300` | First-JDBC-connection budget (Spark engine launch). |
| `dynamic_testing.jdbc_url` | `jdbc:hive2://localhost:10009` | Beeline target for integration tests. |
| `notifications.*` | see file | Channel routing per failure type (escalation matrix TBD). |
| `storage.*` | see file | S3/Ceph layout and retention (retention policy TBD). |
| `periodic_rescan.schedule_cron` | `23 4 * * 1` | Documenting value; the effective schedule lives in `periodic-rescan.yml`. |
| `image_signing.cosign_enabled` | `false` | Cosign signing — pending TESCO confirmation. |

> Keys marked `TBD-TESTING-TEAM` in the file are collected via
> `docs/05_DISCOVERY_CHECKLIST_FOR_TESTING_TEAM.md`.

---

## 9. Handling a gate failure — decision tree

1. **Read the run summary** (Actions → the run → Summary): the gate table shows exactly which check failed and the counts.
2. **Critical/High OS vulnerabilities over threshold?**
   - Check `snyk-report.html` in `stage2-security-reports` for the package and whether a fixed version exists (`fixedIn`).
   - Fixed version available → it usually arrives via `apt-get upgrade`, already part of the final image stage; rebuild. Or bump the base image tag.
   - No fix available and risk accepted → add a **time-boxed allowlist entry** (below). Never raise thresholds as a shortcut.
3. **Dockle FATAL?** Look at `dockle-results.txt` for the CIS code. Fix the image (preferred — e.g. we removed Kyuubi's bundled `docker/playground/.env` demo file that tripped CIS-DI-0010) rather than suppressing the check.
4. **Snyk JSON missing but token configured?** The scan itself broke — check the Snyk step log (auth failure, rate limit). This is intentionally a gate failure.

**Allowlist entry format** (`config/allowlist.yml`) — every field is mandatory,
entries expire automatically, and changes must be reviewed by Security/Compliance
(protect via CODEOWNERS):

```yaml
allowlist:
  - id: SNYK-UBUNTU2204-OPENSSL-1234567
    reason: "No fix available upstream; component not reachable at runtime"
    approved_by: "security-compliance-team"
    expires: 2026-12-31
```

---

## 10. Onboarding a new image (summary of `docs/04`)

1. Create `<new-image-dir>/` mirroring `spark-kyuubi-image/`: `Dockerfile`, `.hadolint.yaml`, `.dockerignore`, `conf/`, `docker-compose.test.yml`, `tests/{unit,smoke,integration}/`.
2. Dockerfile requirements enforced by unit tests + scanners: pinned base tags (no `:latest`), multi-stage build, non-root `USER`, `HEALTHCHECK`, verified downloads (keep the archive's **original filename** when checking `sha512sum -c` — see §11), no demo/sample files carrying credential-looking content.
3. Add the directory to the workflow `push.paths` filter, or simply run manually with the `image_dir` input.
4. When the image is released to a registry, add its reference to the `matrix.image` list in `periodic-rescan.yml`.

---

## 11. Troubleshooting — failure modes actually seen in this repo

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| Build fails at `sha512sum -c`: "FAILED open or read" | Apache `.sha512` files reference the **original archive filename**; downloading as `spark.tgz` breaks verification | Download using the original filename (current Dockerfile does this) |
| Stage 3: container `unhealthy`, yet service reachable from the host | Kyuubi binds frontends to the **container hostname**, so the in-container `curl localhost` health probe never succeeds | `kyuubi.frontend.{rest,thrift.binary}.bind.host 0.0.0.0` in `kyuubi-defaults.conf` |
| Stage 3: health times out but every other check passes right after | Startup budget too small for 2-core runners | 300 s budget (config + `smoke_test.sh`) |
| Gate prints FAILED but Stage 3 ran anyway | `\| tee` masked the gate's exit code | `set -o pipefail` on the gate steps — **do not remove** |
| Gate thresholds show garbage like `<= confirm.` | Config comments containing colons corrupted value parsing | Fixed in `get_cfg`; values are validated numeric |
| One CVE counted many times | Snyk repeats an ID per dependency path | Gate counts **unique** IDs |
| Dockle FATAL `CIS-DI-0010` on a fresh Kyuubi image | Upstream tarball ships `docker/playground/.env` demo file | Downloader stage strips demo/sample dirs |
| Intermittent base-image pull failures | Docker Hub anonymous rate limits on shared runner IPs | Docker Hub login step (configured) |
| First build extremely slow (~15 min) | Apache archive throttling | Expected once; GHA layer cache makes later builds ~1–2 min. Downloads retry+resume (`curl --retry -C -`) |

General debugging: Actions → run → failed job → step log; download the stage
artifacts (JUnit XML, `container-logs.txt`, scan JSONs) for detail. Snyk findings
also appear under **Security → Code scanning** (category `snyk-container`).

---

## 12. Known limitations / recommended next steps

Already implemented: tokens live as encrypted **secrets**; the pipeline
**publishes** tested images to Docker Hub (`:<sha>` + `:latest`); the weekly
re-scan checks the **real published image**; app-dependency gating is a
one-line config switch; the integration suite covers JOIN/CTAS/config cases.

Still open:

1. **Rotate `SNYK_TOKEN` and `DOCKERHUB_TOKEN`** (they transited chat/plaintext during setup). Update the secret values in Settings → Secrets and variables → Actions; no workflow changes needed. The Docker Hub token needs **read/write** scope for publishing.
2. **Decide the app-dependency vulnerability policy** and, when agreed, set `quality_gate.gate_app_dependencies: true` (+ thresholds) in `config/pipeline-config.yml`. Owner: TESCO testing/security team.
3. **Configure archival & notifications** (`S3_BUCKET` + AWS secrets, Slack/Teams webhooks) — the plumbing is in place and self-skips today.
4. **Automate more manual test cases** from TESCO's Manual Test Case Document into the integration suite.
5. **Image signing (cosign)** and PR-based allowlist review via CODEOWNERS are scaffolded but pending TESCO decisions.
