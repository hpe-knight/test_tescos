# 02 — Configuration Guide

How every tunable in the framework works, where it lives, and how to change it
safely. **All functional changes go through pull requests** — the pipeline
config is code.

---

## 1. Configuration Map

| What | File | Reviewed by |
|---|---|---|
| Quality-gate thresholds, timeouts, routing, storage | `config/pipeline-config.yml` | Security + DevOps |
| Approved vulnerability exceptions | `config/allowlist.yml` | Security (CODEOWNERS-enforced) |
| Dockerfile lint rules | `spark-kyuubi-image/.hadolint.yaml` | DevOps |
| Pipeline triggers, jobs, tool versions | `.github/workflows/image-pipeline.yml` | DevOps |
| Re-scan schedule + image list | `.github/workflows/periodic-rescan.yml` | Security + DevOps |
| Spark/Kyuubi runtime settings | `spark-kyuubi-image/conf/*.conf` | Data Engineering |
| Test cases | `spark-kyuubi-image/tests/**` | Testing team + Data Engineering |
| Secrets / variables | GitHub repo settings (not in git) | DevOps |

## 2. Quality Gate Thresholds

In `config/pipeline-config.yml`:

```yaml
quality_gate:
  max_critical: 0        # any critical CVE fails the gate
  max_high: 5            # more than 5 high CVEs fails the gate
  fail_on_secrets: true
  dockle_exit_level: fatal
```

- `scripts/quality_gate.sh` reads these values at run time — no workflow edit
  needed to tune thresholds.
- Loosening a threshold is a **security decision**: raise a PR, tag the
  Security team, document why in the PR description.

## 3. Vulnerability Allowlist (Risk Acceptance)

When a finding is a genuine accepted risk (e.g., no upstream fix, component
unreachable at runtime), do **not** raise thresholds — add a scoped, expiring
exception in `config/allowlist.yml`:

```yaml
allowlist:
  - id: SNYK-UBUNTU2204-OPENSSL-1234567     # exact Snyk vulnerability ID
    reason: "No fix available; module not loaded at runtime"
    approved_by: "security-compliance-team"
    expires: 2026-12-31                      # counts again after this date
```

Rules enforced by design:
- Only **unexpired** entries are excluded by the gate.
- CODEOWNERS forces Security review on every change.
- Expired entries silently re-activate the finding — review before expiry.

## 4. Notification Routing

`config/pipeline-config.yml → notifications` records the agreed escalation
matrix (currently `TBD-TESTING-TEAM`). To wire additional channels:

1. Create one webhook per team channel (Dev / DevOps / Security / Data Eng).
2. Add each as a secret (e.g., `SLACK_WEBHOOK_SECURITY`).
3. Extend `scripts/notify.sh` to pick the webhook by failed stage — the stage
   detection logic (`FAILED_STAGE`) is already in place.

## 5. Storage Configuration

| Setting | Where | Value |
|---|---|---|
| Bucket | repo variable `S3_BUCKET` | e.g. `tesco-image-testing` |
| Region | repo variable `AWS_REGION` | e.g. `eu-west-1` |
| Ceph endpoint | repo variable `S3_ENDPOINT_URL` | only for Ceph RGW; unset = AWS |
| Key layout | fixed in `scripts/upload_to_s3.sh` | `<image>/<git-sha>/<stage>/<file>` |

The layout gives you a complete audit trail: for any image digest you can
retrieve exactly which scans ran, what they found, and which tests passed.

## 6. Scanning Tool Configuration

**Snyk** — behaviour set via workflow `args`; severity threshold and SARIF
publishing are on. Organization-level ignore policies can also be managed in
the Snyk UI, but prefer `allowlist.yml` for pipeline decisions (git-audited).

**Dockle** — checks CIS Docker Benchmark. To ignore a specific checkpoint
(with justification), add to the Dockle step: `--ignore CIS-DI-0009`.

**Hadolint** — rules in `.hadolint.yaml`. Every `ignored:` rule requires a
justification comment; treat additions like allowlist entries.

**Syft** — emits both SPDX-JSON and CycloneDX. Formats are listed in
`pipeline-config.yml → scanning.syft.sbom_formats`; if a regulator/customer
needs a different format, Syft supports many (`syft <image> -o <format>`).

## 7. Dynamic Test Configuration

- Startup budgets: `dynamic_testing.startup_timeout_seconds` (container
  healthy) and `engine_startup_timeout_seconds` (first JDBC connection spawns
  the Spark SQL engine). Spark images are slow to boot — raise these before
  assuming failure.
- The compose file `docker-compose.test.yml` is the single definition of the
  test environment. Add sidecars (e.g., a Postgres metastore, MinIO) there and
  the pipeline picks them up automatically.
- New test cases: add `record()` blocks in
  `tests/integration/integration_test.sh` — the JUnit output and reporting
  come for free.

## 8. Large Image Strategy (Spark images are big)

Current prototype hands the image between jobs as a **tar artifact** — simple,
zero extra infrastructure, fine up to a few GB. When TESCO's real images
exceed that:

1. Push after Stage 1 to a registry with a `ci-<sha>` tag
   (`docker/build-push-action` with `push: true`).
2. Replace the `download-artifact`/`docker load` steps in Stage 2/3 with
   `docker pull`.
3. Keep `cache-from/cache-to: type=gha` — layer caching is what actually
   controls build time for Spark images; order Dockerfile layers so the Spark
   distro download stays cached across builds.
4. Consider larger or self-hosted runners (see docs/01 §8).

## 9. Optional: Cosign Image Signing (if confirmed)

Add after the quality gate passes, before archive/push:

```yaml
- name: Sign image
  env:
    COSIGN_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
  run: |
    cosign sign --yes --key env://COSIGN_KEY ${IMAGE_NAME}@${DIGEST}
    cosign attest --yes --key env://COSIGN_KEY \
      --predicate reports/stage2/sbom.spdx.json --type spdxjson \
      ${IMAGE_NAME}@${DIGEST}
```

Deployment environments then verify with `cosign verify` before running.

## 10. Items Awaiting the Testing Team

Search the repository for **`TBD-TESTING-TEAM`** — every placeholder is
tagged. Master list: `docs/05_DISCOVERY_CHECKLIST_FOR_TESTING_TEAM.md`.
When an answer arrives: update the config/test file, raise a PR, and the
change is live on merge.
