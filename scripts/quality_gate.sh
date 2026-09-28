#!/usr/bin/env bash
# =============================================================================
# QUALITY GATE — decides whether the image may proceed to dynamic testing.
# Usage: quality_gate.sh <snyk.json> <dockle.json|""> <pipeline-config.yml> <allowlist.yml>
#
# Rules (thresholds read from config/pipeline-config.yml):
#   - FAIL if critical vulnerabilities > max_critical (default 0)
#   - FAIL if high vulnerabilities     > max_high     (default configurable)
#   - FAIL if Dockle reports FATAL CIS violations
# Vulnerability IDs listed in config/allowlist.yml (unexpired) are excluded.
# Exit 0 = gate passed; exit 1 = gate failed (blocks Stage 3).
# =============================================================================
set -uo pipefail

SNYK_JSON="${1:?snyk json path required}"
DOCKLE_JSON="${2:-}"
CONFIG_YML="${3:-config/pipeline-config.yml}"
ALLOWLIST_YML="${4:-config/allowlist.yml}"

command -v jq >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq jq; }

# --- Read thresholds from config (simple grep-based YAML lookup) --------------
get_cfg() { grep -E "^\s*$1:" "${CONFIG_YML}" 2>/dev/null | head -1 | sed -E 's/.*:\s*//; s/\s*#.*//'; }
MAX_CRITICAL=$(get_cfg max_critical); MAX_CRITICAL=${MAX_CRITICAL:-0}
MAX_HIGH=$(get_cfg max_high);         MAX_HIGH=${MAX_HIGH:-5}

# --- Collect unexpired allowlisted vulnerability IDs --------------------------
TODAY=$(date +%Y-%m-%d)
ALLOWED_IDS=$(awk -v today="${TODAY}" '
  /^\s*- id:/     { id=$3 }
  /^\s*expires:/  { if ($2 >= today && id != "") print id; id="" }
' "${ALLOWLIST_YML}" 2>/dev/null | tr '\n' ' ')
echo "Allowlisted (unexpired) vulnerability IDs: ${ALLOWED_IDS:-none}"

# --- Count Snyk findings by severity, excluding allowlisted -------------------
if [ -s "${SNYK_JSON}" ]; then
  ALLOW_JSON=$(printf '%s\n' ${ALLOWED_IDS} | jq -R . | jq -s .)
  CRITICAL=$(jq --argjson allow "${ALLOW_JSON}" \
    '[.vulnerabilities[]? | select(.severity=="critical") | select((.id as $i | $allow | index($i)) | not)] | length' \
    "${SNYK_JSON}" 2>/dev/null || echo 0)
  HIGH=$(jq --argjson allow "${ALLOW_JSON}" \
    '[.vulnerabilities[]? | select(.severity=="high") | select((.id as $i | $allow | index($i)) | not)] | length' \
    "${SNYK_JSON}" 2>/dev/null || echo 0)
else
  echo "WARNING: Snyk JSON missing/empty — treating as gate failure (no scan evidence)."
  CRITICAL=999; HIGH=999
fi

# --- Count Dockle FATAL findings ----------------------------------------------
DOCKLE_FATAL=0
if [ -n "${DOCKLE_JSON}" ] && [ -s "${DOCKLE_JSON}" ]; then
  DOCKLE_FATAL=$(jq '[.details[]? | select(.level=="FATAL")] | length' "${DOCKLE_JSON}" 2>/dev/null || echo 0)
fi

# --- Verdict -------------------------------------------------------------------
echo ""
echo "### Quality Gate"
echo ""
echo "| Check | Found | Threshold | Result |"
echo "|-------|-------|-----------|--------|"
GATE_FAIL=0
check() { # label, found, max
  local res="PASS"
  if [ "$2" -gt "$3" ]; then res="FAIL"; GATE_FAIL=1; fi
  echo "| $1 | $2 | <= $3 | ${res} |"
}
check "Critical vulnerabilities" "${CRITICAL}" "${MAX_CRITICAL}"
check "High vulnerabilities"     "${HIGH}"     "${MAX_HIGH}"
check "Dockle FATAL (CIS)"       "${DOCKLE_FATAL}" 0

echo ""
if [ "${GATE_FAIL}" -eq 1 ]; then
  echo "QUALITY GATE: **FAILED** — pipeline blocked before dynamic testing."
  exit 1
fi
echo "QUALITY GATE: **PASSED** — proceeding to dynamic testing."
