#!/usr/bin/env bash
# =============================================================================
# QUALITY GATE — decides whether the image may proceed to dynamic testing.
# Usage: quality_gate.sh <trivy.json> <dockle.json|""> <pipeline-config.yml> <allowlist.yml>
# Thresholds come from config/pipeline-config.yml; unexpired vulnerability IDs
# in config/allowlist.yml are excluded. Exit 0 = pass, 1 = fail (blocks Stage 3).
# Works without local jq (falls back to a containerized jq).
# =============================================================================
set -uo pipefail

TRIVY_JSON="${1:?trivy json path required}"
DOCKLE_JSON="${2:-}"
CONFIG_YML="${3:-config/pipeline-config.yml}"
ALLOWLIST_YML="${4:-config/allowlist.yml}"

if command -v jq >/dev/null 2>&1; then
  JQ() { jq "$@"; }
else
  JQ() { docker run --rm -i ghcr.io/jqlang/jq:1.7.1 "$@"; }
fi

get_cfg() { grep -E "^\s*$1:" "${CONFIG_YML}" 2>/dev/null | head -1 | sed -E 's/.*:\s*//; s/\s*#.*//' | tr -d '"'; }
MAX_CRITICAL=$(get_cfg max_critical); MAX_CRITICAL=${MAX_CRITICAL:-0}
MAX_HIGH=$(get_cfg max_high);         MAX_HIGH=${MAX_HIGH:-10}
MAX_SECRETS=0

# Unexpired allowlisted vulnerability IDs
TODAY=$(date +%Y-%m-%d)
ALLOWED_IDS=$(awk -v today="${TODAY}" '
  /^\s*- id:/     { id=$3 }
  /^\s*expires:/  { if ($2 >= today && id != "") print id; id="" }
' "${ALLOWLIST_YML}" 2>/dev/null | tr '\n' ' ')
echo "Allowlisted (unexpired) IDs: ${ALLOWED_IDS:-none}"

if [ -s "${TRIVY_JSON}" ]; then
  ALLOW_JSON=$(printf '%s\n' ${ALLOWED_IDS:-} | JQ -R . | JQ -s 'map(select(length>0))')
  CRITICAL=$(JQ --argjson allow "${ALLOW_JSON}" \
    '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")
      | select((.VulnerabilityID as $i | $allow | index($i)) | not)] | length' \
    < "${TRIVY_JSON}" 2>/dev/null || echo 999)
  HIGH=$(JQ --argjson allow "${ALLOW_JSON}" \
    '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")
      | select((.VulnerabilityID as $i | $allow | index($i)) | not)] | length' \
    < "${TRIVY_JSON}" 2>/dev/null || echo 999)
  SECRETS=$(JQ '[.Results[]?.Secrets[]?] | length' < "${TRIVY_JSON}" 2>/dev/null || echo 999)
else
  echo "WARNING: Trivy JSON missing/empty — failing gate (no scan evidence)."
  CRITICAL=999; HIGH=999; SECRETS=999
fi

DOCKLE_FATAL=0
if [ -n "${DOCKLE_JSON}" ] && [ -s "${DOCKLE_JSON}" ]; then
  DOCKLE_FATAL=$(JQ '[.details[]? | select(.level=="FATAL")] | length' < "${DOCKLE_JSON}" 2>/dev/null || echo 0)
fi

echo ""
echo "### Quality Gate"
echo ""
echo "| Check | Found | Threshold | Result |"
echo "|-------|-------|-----------|--------|"
GATE_FAIL=0
check() { local res="PASS"; [ "$2" -gt "$3" ] && { res="FAIL"; GATE_FAIL=1; }; echo "| $1 | $2 | <= $3 | ${res} |"; }
check "Critical vulnerabilities" "${CRITICAL}" "${MAX_CRITICAL}"
check "High vulnerabilities"     "${HIGH}"     "${MAX_HIGH}"
check "Embedded secrets"         "${SECRETS}"  "${MAX_SECRETS}"
check "Dockle FATAL (CIS)"       "${DOCKLE_FATAL}" 0

echo ""
if [ "${GATE_FAIL}" -eq 1 ]; then
  echo "QUALITY GATE: **FAILED** — pipeline blocked before dynamic testing."
  echo "Remediation: prefer upgrading base image/packages (Trivy JSON shows FixedVersion);"
  echo "for accepted risks add a time-boxed entry to config/allowlist.yml."
  exit 1
fi
echo "QUALITY GATE: **PASSED** — proceeding to dynamic testing."
