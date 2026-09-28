#!/usr/bin/env bash
# =============================================================================
# ARCHIVE TO S3 / CEPH — long-term, auditable storage of all pipeline outputs.
# Usage: upload_to_s3.sh <local-report-dir> <image-name> <tag-or-sha>
# Env:   S3_BUCKET (required), S3_ENDPOINT_URL (set for Ceph RGW; empty = AWS),
#        AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION
# Layout: s3://<bucket>/<image-name>/<sha>/<subdirs from local layout>
# =============================================================================
set -uo pipefail

SRC_DIR="${1:?local report dir required}"
IMAGE_NAME="${2:?image name required}"
IMAGE_TAG="${3:?image tag/sha required}"

if [ -z "${S3_BUCKET:-}" ]; then
  echo "S3_BUCKET not configured — skipping archival (set repo variable S3_BUCKET)."
  exit 0
fi
if [ ! -d "${SRC_DIR}" ]; then
  echo "Nothing to upload: ${SRC_DIR} does not exist."
  exit 0
fi

ENDPOINT_ARGS=()
[ -n "${S3_ENDPOINT_URL:-}" ] && ENDPOINT_ARGS=(--endpoint-url "${S3_ENDPOINT_URL}")

DEST="s3://${S3_BUCKET}/${IMAGE_NAME}/${IMAGE_TAG}/"
echo "Uploading ${SRC_DIR} -> ${DEST}"
aws s3 sync "${SRC_DIR}" "${DEST}" --no-progress "${ENDPOINT_ARGS[@]}"
echo "Archive complete: ${DEST}"
