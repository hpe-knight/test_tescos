# 01 — Prerequisites & Tools Setup

Everything that must exist **before** the pipeline can run. Work through this
top to bottom once; afterwards the pipeline is fully automatic.

---

## 1. Accounts & Access

| Requirement | Who provides it | Notes |
|---|---|---|
| GitHub organization/repo with **Actions enabled** | TESCO DevOps | GitHub Actions is the confirmed CI platform |
| **Snyk account + API token** | TESCO Security (existing tool) | Org-level token preferred over personal |
| **AWS S3 bucket** or **Ceph RGW** (S3-compatible) | TESCO Platform | For report/SBOM/image archival |
| **Slack and/or Teams incoming webhook** | TESCO DevOps + team owners | One per notification channel (routing TBD) |
| Container registry (optional, recommended for large images) | TESCO Platform | GHCR / ECR / internal registry |

## 2. Create the GitHub Repository

1. Create a repository (e.g., `tesco/image-testing-pipeline`).
2. Copy the contents of this `TESCO_CICD/` folder to the **repository root**
   (`.github/workflows/` must be at the root or workflows won't trigger).
3. On Windows the `.sh` scripts need the executable bit for Linux runners.
   After the first commit, run once:
   ```bash
   git update-index --chmod=+x scripts/*.sh spark-kyuubi-image/tests/*/*.sh
   git commit -m "Mark shell scripts executable"
   ```
4. Enable **branch protection** on `main`
   (Settings → Branches → Add rule):
   - ✅ Require a pull request before merging
   - ✅ Require status checks to pass — select all four pipeline jobs
   - ✅ Require review from Code Owners (see §6)

## 3. Configure Secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Required | Purpose |
|---|---|---|
| `SNYK_TOKEN` | ✅ Yes | Snyk CLI authentication (Snyk → Account Settings → API Token) |
| `AWS_ACCESS_KEY_ID` | For archival | S3/Ceph credentials (prefer OIDC — see below) |
| `AWS_SECRET_ACCESS_KEY` | For archival | Pairs with the above |
| `SLACK_WEBHOOK_URL` | Optional | Slack incoming webhook for notifications |
| `TEAMS_WEBHOOK_URL` | Optional | Teams incoming webhook for notifications |
| `COSIGN_PRIVATE_KEY` | Only if signing confirmed | Cosign image signing key |

And **repository variables** (`Variables` tab, not secrets):

| Variable | Example | Purpose |
|---|---|---|
| `S3_BUCKET` | `tesco-image-testing` | Archive bucket name |
| `AWS_REGION` | `eu-west-1` | Bucket region |
| `S3_ENDPOINT_URL` | `https://ceph-rgw.tesco.internal` | **Only for Ceph**; leave unset for AWS |

> 🔐 **Production recommendation:** replace static AWS keys with **GitHub OIDC
> federation** (`aws-actions/configure-aws-credentials` with a `role-to-assume`).
> No long-lived credentials stored in GitHub at all.

## 4. Set Up S3 / Ceph Storage

**AWS S3:**
```bash
aws s3 mb s3://tesco-image-testing --region eu-west-1
aws s3api put-bucket-versioning --bucket tesco-image-testing \
  --versioning-configuration Status=Enabled
# Block all public access
aws s3api put-public-access-block --bucket tesco-image-testing \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Ceph RGW (S3-compatible):** create the bucket via `radosgw-admin`/dashboard,
then set `S3_ENDPOINT_URL` — the pipeline's `aws s3 sync` works unchanged.

Retention/lifecycle rules: apply per compliance requirements (**TBD — discovery**).

## 5. Set Up Notification Webhooks

**Slack:** Slack App → Incoming Webhooks → Add to the target channel → copy URL
into `SLACK_WEBHOOK_URL`.
**Teams:** Channel → Connectors → Incoming Webhook → copy URL into
`TEAMS_WEBHOOK_URL`.

Final channel-per-team routing is configured after the escalation matrix is
confirmed (`config/pipeline-config.yml → notifications.routing`).

## 6. Protect Security-Sensitive Files (CODEOWNERS)

Create `.github/CODEOWNERS` so gate/allowlist changes require Security review:

```text
/config/allowlist.yml        @tesco/security-compliance-team
/config/pipeline-config.yml  @tesco/security-compliance-team @tesco/devops-team
/scripts/quality_gate.sh     @tesco/security-compliance-team
```

## 7. Local Developer Tooling (optional but recommended)

For running checks locally before pushing (Linux/macOS/WSL):

```bash
# Hadolint (Dockerfile lint)
docker run --rm -i hadolint/hadolint < spark-kyuubi-image/Dockerfile

# Dockle (CIS benchmark)
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  goodwithtech/dockle:latest spark-kyuubi:dev

# Syft (SBOM)
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
syft spark-kyuubi:dev -o spdx-json > sbom.json

# Snyk CLI
npm install -g snyk && snyk auth
snyk container test spark-kyuubi:dev --file=spark-kyuubi-image/Dockerfile

# Full local dry run of the image + tests
cd spark-kyuubi-image
docker buildx build -t spark-kyuubi:dev --load .
TEST_IMAGE=spark-kyuubi:dev docker compose -f docker-compose.test.yml up -d
bash tests/smoke/smoke_test.sh /tmp/junit-smoke.xml
bash tests/integration/integration_test.sh /tmp/junit-int.xml
docker compose -f docker-compose.test.yml down -v
```

## 8. Runner Sizing (large Spark images)

GitHub-hosted `ubuntu-latest` (4 vCPU / 16 GB / 14 GB SSD) handles the POC
image. If builds hit disk/time limits on real TESCO images:

- Use **larger GitHub-hosted runners** (8–16 vCPU) — a repo settings change, or
- Register **self-hosted runners** near the registry/storage, and
- Switch image hand-off between jobs from tar-artifact to **registry push/pull**
  (see `docs/02` → *Large image strategy*).

## ✅ Setup Completion Checklist

- [ ] Repo created, framework files at root, scripts executable
- [ ] Branch protection + CODEOWNERS active
- [ ] `SNYK_TOKEN` secret set and valid (`snyk auth` test)
- [ ] S3/Ceph bucket created; `S3_BUCKET` (+ `S3_ENDPOINT_URL` for Ceph) variables set
- [ ] Slack/Teams webhook secrets set; test message received
- [ ] First manual run (`workflow_dispatch`) completes all four jobs
- [ ] SARIF findings visible under repo **Security → Code scanning**
