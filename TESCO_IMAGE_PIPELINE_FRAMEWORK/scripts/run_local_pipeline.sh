#!/usr/bin/env bash
# =============================================================================
# RUN THE FULL PIPELINE LOCALLY — one command, Docker is the only prerequisite.
# Mirrors .github/workflows/image-pipeline.yml stage by stage.
#   Usage:  bash scripts/run_local_pipeline.sh
#   Output: ./reports/ + a final summary table; exit 0 = fully green.
# All scanners run as containers (Hadolint, Trivy, Dockle, Syft) — nothing to
# install. Works in Linux, macOS, WSL2, and Git Bash on Windows.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

IMAGE_NAME="spark-kyuubi"
IMAGE_TAG="local"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
IMAGE_DIR="spark-kyuubi-image"
REPORTS="${ROOT}/reports"

# MSYS (Git Bash) mangles container paths like /var/run/docker.sock — disable.
export MSYS_NO_PATHCONV=1

S1="skipped"; S2="skipped"; GATE="skipped"; S3="skipped"
banner() { echo ""; echo "==============================================================="; echo " $1"; echo "==============================================================="; }
die_summary() { summary; exit 1; }
summary() {
  banner "PIPELINE SUMMARY"
  printf "%-38s %s\n" "Stage 1 — Build & Lint:" "${S1}"
  printf "%-38s %s\n" "Stage 2 — Security Scan:" "${S2}"
  printf "%-38s %s\n" "Quality Gate:" "${GATE}"
  printf "%-38s %s\n" "Stage 3 — Dynamic Testing:" "${S3}"
  echo ""
  echo "Reports: ${REPORTS}/"
}

command -v docker >/dev/null || { echo "ERROR: docker not found — install Docker Desktop/Engine first."; exit 1; }
rm -rf "${REPORTS}"; mkdir -p "${REPORTS}/stage1" "${REPORTS}/stage2" "${REPORTS}/stage3"

# ----------------------------- STAGE 1 ---------------------------------------
banner "STAGE 1 — BUILD & LINT"

echo "--- Hadolint (Dockerfile lint) ---"
docker run --rm -i -v "${ROOT}/${IMAGE_DIR}/.hadolint.yaml:/.hadolint.yaml:ro" \
  hadolint/hadolint:v2.12.0 hadolint --config /.hadolint.yaml - \
  < "${IMAGE_DIR}/Dockerfile"
[ $? -eq 0 ] || { S1="FAILED (hadolint)"; die_summary; }

echo "--- Docker build (first run downloads Spark/Kyuubi, be patient) ---"
docker buildx build -t "${IMAGE_REF}" --load "${IMAGE_DIR}" \
  2>&1 | tee "${REPORTS}/stage1/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { S1="FAILED (build)"; die_summary; }

echo "--- Unit tests (TC-U01..TC-U06) ---"
bash "${IMAGE_DIR}/tests/unit/run_tests.sh" "${REPORTS}/stage1/junit-unit.xml" \
  || { S1="FAILED (unit tests)"; die_summary; }
S1="PASSED"

# ----------------------------- STAGE 2 ---------------------------------------
banner "STAGE 2 — SECURITY SCANNING"

echo "--- Trivy (CVEs + secrets) ---"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${REPORTS}/stage2:/out" aquasec/trivy:0.58.1 image \
  --scanners vuln,secret --format json --output /out/trivy-results.json \
  --exit-code 0 "${IMAGE_REF}"

echo "--- Dockle (CIS Docker Benchmark) ---"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  goodwithtech/dockle:v0.4.14 --format json "${IMAGE_REF}" \
  > "${REPORTS}/stage2/dockle-results.json" || true
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  goodwithtech/dockle:v0.4.14 "${IMAGE_REF}" \
  | tee "${REPORTS}/stage2/dockle-results.txt" || true

echo "--- Syft (SBOM: SPDX + CycloneDX) ---"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  anchore/syft:v1.18.1 "${IMAGE_REF}" -o spdx-json > "${REPORTS}/stage2/sbom.spdx.json"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  anchore/syft:v1.18.1 "${IMAGE_REF}" -o cyclonedx-json > "${REPORTS}/stage2/sbom.cyclonedx.json"
S2="PASSED (reports generated)"

# --------------------------- QUALITY GATE -------------------------------------
banner "QUALITY GATE"
if bash scripts/quality_gate.sh \
     "${REPORTS}/stage2/trivy-results.json" \
     "${REPORTS}/stage2/dockle-results.json" \
     config/pipeline-config.yml config/allowlist.yml; then
  GATE="PASSED"
else
  GATE="FAILED — see reports/stage2/"; S3="blocked by gate"; die_summary
fi

# ----------------------------- STAGE 3 ---------------------------------------
banner "STAGE 3 — DYNAMIC TESTING (sample retail dataset)"
cleanup() { (cd "${IMAGE_DIR}" && docker compose -f docker-compose.test.yml down -v) >/dev/null 2>&1 || true; }
trap cleanup EXIT

( cd "${IMAGE_DIR}" && TEST_IMAGE="${IMAGE_REF}" docker compose -f docker-compose.test.yml up -d )

echo "--- Smoke tests (TC-S01..TC-S05) ---"
if ! bash "${IMAGE_DIR}/tests/smoke/smoke_test.sh" "${REPORTS}/stage3/junit-smoke.xml"; then
  S3="FAILED (smoke)"
  docker logs kyuubi-test > "${REPORTS}/stage3/container-logs.txt" 2>&1 || true
  die_summary
fi

echo "--- Integration tests (TC-I01..TC-I09) ---"
if ! bash "${IMAGE_DIR}/tests/integration/integration_test.sh" "${REPORTS}/stage3/junit-integration.xml"; then
  S3="FAILED (integration)"
  docker logs kyuubi-test > "${REPORTS}/stage3/container-logs.txt" 2>&1 || true
  die_summary
fi

docker logs kyuubi-test > "${REPORTS}/stage3/container-logs.txt" 2>&1 || true
S3="PASSED"

summary
echo "RESULT: ALL STAGES GREEN ✔"
