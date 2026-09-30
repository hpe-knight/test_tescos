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
# Strip the comment BEFORE extracting the value: comments may contain colons
# (e.g. "TBD-TESTING-TEAM: confirm."), which previously corrupted the value.
get_cfg() { grep -E "^\s*$1:" "${CONFIG_YML}" 2>/dev/null | head -1 | sed -E 's/#.*$//; s/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//'; }
MAX_CRITICAL=$(get_cfg max_critical); MAX_CRITICAL=${MAX_CRITICAL:-0}
MAX_HIGH=$(get_cfg max_high);         MAX_HIGH=${MAX_HIGH:-5}
GATE_APP_DEPS=$(get_cfg gate_app_dependencies); GATE_APP_DEPS=${GATE_APP_DEPS:-false}
MAX_APP_CRITICAL=$(get_cfg max_app_critical); MAX_APP_CRITICAL=${MAX_APP_CRITICAL:-0}
MAX_APP_HIGH=$(get_cfg max_app_high);         MAX_APP_HIGH=${MAX_APP_HIGH:-10}
case "${MAX_CRITICAL}" in *[!0-9]*|"") echo "WARNING: bad max_critical '${MAX_CRITICAL}' — defaulting to 0"; MAX_CRITICAL=0;; esac
case "${MAX_HIGH}"     in *[!0-9]*|"") echo "WARNING: bad max_high '${MAX_HIGH}' — defaulting to 5";     MAX_HIGH=5;; esac
case "${MAX_APP_CRITICAL}" in *[!0-9]*|"") MAX_APP_CRITICAL=0;;  esac
case "${MAX_APP_HIGH}"     in *[!0-9]*|"") MAX_APP_HIGH=10;; esac

# --- Collect unexpired allowlisted vulnerability IDs --------------------------
TODAY=$(date +%Y-%m-%d)
ALLOWED_IDS=$(awk -v today="${TODAY}" '
  /^\s*- id:/     { id=$3 }
  /^\s*expires:/  { if ($2 >= today && id != "") print id; id="" }
' "${ALLOWLIST_YML}" 2>/dev/null | tr '\n' ' ')
echo "Allowlisted (unexpired) vulnerability IDs: ${ALLOWED_IDS:-none}"

# --- Count Snyk findings by severity, excluding allowlisted -------------------
# Unique vulnerability IDs: Snyk repeats one ID per introduction path, which
# previously inflated the counts (one openssl CVE showed up as 7 highs).
SNYK_NOTE=""
APP_CRITICAL="n/a"; APP_HIGH="n/a"
if [ -s "${SNYK_JSON}" ]; then
  ALLOW_JSON=$(printf '%s\n' ${ALLOWED_IDS} | jq -R . | jq -s .)
  CRITICAL=$(jq --argjson allow "${ALLOW_JSON}" \
    '[.vulnerabilities[]? | select(.severity=="critical") | select((.id as $i | $allow | index($i)) | not) | .id] | unique | length' \
    "${SNYK_JSON}" 2>/dev/null || echo 0)
  HIGH=$(jq --argjson allow "${ALLOW_JSON}" \
    '[.vulnerabilities[]? | select(.severity=="high") | select((.id as $i | $allow | index($i)) | not) | .id] | unique | length' \
    "${SNYK_JSON}" 2>/dev/null || echo 0)
  # Bundled application dependencies (Spark/Kyuubi jars). Gated only when
  # gate_app_dependencies=true in the config; informational otherwise.
  # Allowlist exclusions apply here too.
  APP_CRITICAL=$(jq --argjson allow "${ALLOW_JSON}" '[.applications[]?.vulnerabilities[]? | select(.severity=="critical") | select((.id as $i | $allow | index($i)) | not) | .id] | unique | length' "${SNYK_JSON}" 2>/dev/null || echo "n/a")
  APP_HIGH=$(jq --argjson allow "${ALLOW_JSON}" '[.applications[]?.vulnerabilities[]? | select(.severity=="high") | select((.id as $i | $allow | index($i)) | not) | .id] | unique | length' "${SNYK_JSON}" 2>/dev/null || echo "n/a")
elif [ "${SNYK_SKIPPED:-false}" = "true" ]; then
  echo "WARNING: Snyk scan skipped (SNYK_TOKEN not configured) — vulnerability"
  echo "checks not enforced this run. Configure the SNYK_TOKEN secret to enable them."
  CRITICAL=0; HIGH=0
  SNYK_NOTE=" (Snyk skipped — no token)"
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
check "Critical vulnerabilities (OS)${SNYK_NOTE}" "${CRITICAL}" "${MAX_CRITICAL}"
check "High vulnerabilities (OS)${SNYK_NOTE}"     "${HIGH}"     "${MAX_HIGH}"
check "Dockle FATAL (CIS)"       "${DOCKLE_FATAL}" 0
if [ "${GATE_APP_DEPS}" = "true" ] && [ "${APP_CRITICAL}" != "n/a" ]; then
  check "App deps critical vulnerabilities" "${APP_CRITICAL}" "${MAX_APP_CRITICAL}"
  check "App deps high vulnerabilities"     "${APP_HIGH}"     "${MAX_APP_HIGH}"
else
  echo "| App deps critical/high (informational, policy TBD) | ${APP_CRITICAL}/${APP_HIGH} | n/a | INFO |"
fi

echo ""
if [ "${GATE_FAIL}" -eq 1 ]; then
  echo "QUALITY GATE: **FAILED** — pipeline blocked before dynamic testing."
  exit 1
fi
echo "QUALITY GATE: **PASSED** — proceeding to dynamic testing."
