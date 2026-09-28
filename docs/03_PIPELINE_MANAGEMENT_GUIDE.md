# 03 — Step-by-Step Guide: Managing the Complete CI/CD Process

The operations manual for running this pipeline day to day: how a change flows
through, how to read every report, what to do at each kind of failure, and the
routine duties per team.

---

## Part 1 — How a Change Flows Through the Pipeline

### Step 1: Developer makes a change
Any change to `spark-kyuubi-image/**`, `scripts/**`, `config/**`, or the
workflow itself is made **on a branch**, never directly on `main`
(branch protection enforces this).

```bash
git checkout -b feature/update-spark-version
# ... edit files ...
git commit -m "Bump Spark to 3.5.2"
git push -u origin feature/update-spark-version
```

### Step 2: Open a Pull Request → pipeline runs automatically
The `pull_request` trigger starts the full pipeline. The PR shows four checks:

| Check | What it proves |
|---|---|
| Stage 1 — Build & Lint | Dockerfile is clean, image builds, unit tests pass |
| Stage 2 — Security Scan & Quality Gate | No blocking CVEs/secrets/CIS violations |
| Stage 3 — Dynamic Testing | The image actually works (Spark SQL, JDBC) |
| Reports, Notify & Archive | Always runs; publishes results |

### Step 3: Review & merge
- Reviewer checks the code **and** the run summary (Actions → run →
  Summary tab shows the quality-gate table and stage results).
- Changes to `config/allowlist.yml`, `quality_gate.sh`, or thresholds
  additionally require Security approval (CODEOWNERS).
- Merge to `main` re-runs the pipeline on the merged state — this run's
  artifacts are the **authoritative record** for that image version.

### Step 4: Automatic aftermath
- Reports archived to S3/Ceph under `<image>/<git-sha>/…`.
- Slack/Teams notification sent (success summary or failure alert).
- Snyk SARIF findings appear in **Security → Code scanning**.
- The image version is now a candidate for release/onboarding into the
  periodic re-scan list.

---

## Part 2 — Running and Monitoring

### Manually triggering a run
Actions → *Docker Image Testing & Scanning Pipeline* → **Run workflow** →
choose branch (and optionally an image directory) → Run.

### Where every output lives

| Output | Location |
|---|---|
| Stage summaries + quality-gate table | Run page → **Summary** |
| Build logs, unit JUnit | Artifact `stage1-build-reports` |
| Snyk JSON/SARIF/HTML, Dockle, SBOMs | Artifact `stage2-security-reports` |
| Smoke/integration JUnit, container logs | Artifact `stage3-test-reports` |
| Security findings UI | Repo → **Security → Code scanning** (SARIF) |
| Long-term audit copies | `s3://<bucket>/<image>/<git-sha>/…` |
| Human notification | Slack/Teams channel |

### Reading the reports
- **`snyk-report.html`** — stakeholder-readable vulnerability report; open in
  a browser. Sort by severity; check "fixed in" column for upgrade paths.
- **`dockle-results.txt`** — CIS findings; `FATAL` entries block the gate,
  `WARN`/`INFO` are advisory.
- **`sbom.spdx.json` / `sbom.cyclonedx.json`** — complete component inventory;
  this is what you hand to compliance/auditors.
- **JUnit XMLs** — each `<testcase>` maps to one named check in the test
  scripts; a `<failure>` element carries the exact reason.

---

## Part 3 — Failure Playbooks (by stage)

### 🔴 Stage 1 failed — Build & Lint  → owner: Development team

| Symptom | Action |
|---|---|
| Hadolint rule violation | Fix the Dockerfile line it names. Only if the rule is genuinely inapplicable, add it to `.hadolint.yaml → ignored` **with a justification comment** via PR |
| Build failure (download, checksum, syntax) | Read the Buildx step log; checksum mismatches on Spark/Kyuubi archives usually mean a version bump with a stale URL — update `ARG` versions consistently |
| Unit test failure | The JUnit artifact names the failing check (e.g., `dockerfile_non_root_user`) — fix the underlying file, don't delete the test |

### 🔴 Stage 2 failed — Security Scan / Quality Gate  → owner: Security + image owner

1. Open the run **Summary** — the quality-gate table shows exactly which
   threshold was breached (critical count, high count, Dockle FATAL).
2. Open `snyk-report.html` from the `stage2-security-reports` artifact.
3. Decide per finding, in this order of preference:
   - **Upgrade** the base image or package (Snyk shows the fixed version) —
     the right fix ~90% of the time.
   - **Rebuild** — base images get patched continuously; a plain re-run may
     already pull a fixed layer if versions float within the pinned tag.
   - **Risk-accept** — only with Security approval: add an expiring entry to
     `config/allowlist.yml` (see docs/02 §3). Never raise `max_critical`.
4. If **secrets** were detected: rotate the credential FIRST (it's in a layer
   forever), then remove it from the build (use build secrets / runtime env).

### 🔴 Stage 3 failed — Dynamic Testing  → owner: Data Engineering + Dev

1. Download `stage3-test-reports`; open the JUnit file to find the failing
   check, then `container-logs.txt` for the cause.
2. Common causes:

| Failing check | Usual cause | Fix |
|---|---|---|
| `container_healthy_within_…` | Slow start / crash loop | Check logs for stack traces; raise `startup_timeout_seconds` only if it's genuinely just slow |
| `jdbc_connect_and_engine_startup` | Spark SQL engine failed to launch | Look for engine errors in logs; often memory config or missing dirs — check `spark-defaults.conf` |
| `thrift_port_…_listening` | Kyuubi bound to wrong port/interface | Verify `kyuubi-defaults.conf` frontend settings |
| SQL test failures | Regression in image contents | Reproduce locally (docs/01 §7 dry-run) and bisect the Dockerfile change |

3. Reproduce locally before pushing fixes — the compose file gives you the
   identical environment.

### 🔴 Notify/Archive job failed  → owner: DevOps

Non-blocking by design (`continue-on-error`), but fix promptly:
- S3 upload errors → credentials/variables (`S3_BUCKET`, endpoint) or bucket
  policy.
- Webhook errors → webhook revoked/rotated; send a manual test `curl` first.

### 🔴 Re-scan alert fired (periodic-rescan.yml)  → owner: Security

A previously approved image now breaches thresholds because of newly published
CVEs. Triage as Stage 2 step 3; then rebuild + re-run the main pipeline for
that image so the archive holds fresh evidence.

---

## Part 4 — Routine Operations Calendar

| Cadence | Task | Owner |
|---|---|---|
| Every PR | Review code + run summary; Security reviews gate/allowlist changes | Reviewers / Security |
| Weekly | Check periodic re-scan results; triage new findings | Security |
| Weekly | Review `allowlist.yml` entries expiring within 30 days | Security |
| Monthly | Bump pinned tool/action versions (Hadolint, Dockle, Syft, actions) via PR | DevOps |
| Monthly | Verify S3 archive integrity + lifecycle rules doing what compliance expects | DevOps |
| Quarterly | Re-baseline thresholds and test coverage with the testing team | All teams |
| When testing team delivers inputs | Replace `TBD-TESTING-TEAM` placeholders (see docs/05) | DevOps + Testing |

## Part 5 — Change-Management Rules

1. **Everything via PR.** Workflow, thresholds, allowlist, tests — no direct
   pushes to `main`; the pipeline validates its own changes.
2. **Thresholds only move with Security sign-off**; exceptions go in the
   allowlist with an expiry, never as threshold bumps.
3. **Never delete a failing test to make a run green.** Fix the image, or get
   the test's owner (testing team / Data Eng) to agree the expectation changed.
4. **Artifacts are the audit trail.** Do not delete run artifacts or S3
   objects inside the retention window.
5. **Rotate any secret that ever appears in a scan finding or a log**, even if
   the exposure looks theoretical.

## Part 6 — Roles & Responsibilities (RACI summary)

| Activity | Dev/App | DevOps | Security | Data Eng |
|---|---|---|---|---|
| Dockerfile & app changes | **R/A** | C | C | C |
| Pipeline/workflow maintenance | C | **R/A** | C | I |
| Quality-gate thresholds & allowlist | I | C | **R/A** | I |
| Spark/Kyuubi test cases & configs | C | I | I | **R/A** |
| Failure triage — Stage 1 | **R** | C | I | I |
| Failure triage — Stage 2 / re-scans | C | C | **R** | I |
| Failure triage — Stage 3 | C | C | I | **R** |
| Storage, retention, notifications infra | I | **R/A** | C | I |

*(R = Responsible, A = Accountable, C = Consulted, I = Informed — to be
ratified with the escalation matrix during discovery.)*
