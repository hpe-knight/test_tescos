#!/usr/bin/env bash
# =============================================================================
# NOTIFICATIONS — Slack / Teams. Skips cleanly when webhooks are not set, so
# the pipeline stays green with zero configuration.
# Env in: PIPELINE_STATUS, STAGE1_RESULT, STAGE2_RESULT, STAGE3_RESULT,
#         RUN_URL, IMAGE_REF, SLACK_WEBHOOK_URL?, TEAMS_WEBHOOK_URL?
# Sample payloads: samples/sample-notification-*.json
# =============================================================================
set -uo pipefail

STATUS="${PIPELINE_STATUS:-UNKNOWN}"
if [ "${STATUS}" = "PASSED" ]; then
  EMOJI=":white_check_mark:"; COLOR="#2eb886"
  HEADLINE="All tests PASSED for ${IMAGE_REF:-image}"
else
  EMOJI=":rotating_light:"; COLOR="#d00000"
  FAILED_STAGE="unknown"
  [ "${STAGE3_RESULT:-}" != "success" ] && FAILED_STAGE="Stage 3 — Dynamic Testing"
  [ "${STAGE2_RESULT:-}" != "success" ] && FAILED_STAGE="Stage 2 — Security Scan / Quality Gate"
  [ "${STAGE1_RESULT:-}" != "success" ] && FAILED_STAGE="Stage 1 — Build & Lint"
  HEADLINE="Pipeline ${STATUS} at ${FAILED_STAGE} for ${IMAGE_REF:-image}"
fi

BODY="Stage 1 (Build & Lint): ${STAGE1_RESULT:-n/a}\nStage 2 (Security Scan & Gate): ${STAGE2_RESULT:-n/a}\nStage 3 (Dynamic Testing): ${STAGE3_RESULT:-n/a}\nLogs & reports: ${RUN_URL:-n/a}"

if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  PAYLOAD=$(cat <<EOF
{
  "attachments": [{
    "color": "${COLOR}",
    "blocks": [
      { "type": "section",
        "text": { "type": "mrkdwn", "text": "${EMOJI} *${HEADLINE}*\n${BODY}" } }
    ]
  }]
}
EOF
)
  curl -sf -X POST -H 'Content-Type: application/json' -d "${PAYLOAD}" "${SLACK_WEBHOOK_URL}" \
    && echo "Slack notification sent." || echo "WARNING: Slack notification failed."
else
  echo "SLACK_WEBHOOK_URL not configured — skipping Slack."
fi

if [ -n "${TEAMS_WEBHOOK_URL:-}" ]; then
  PAYLOAD=$(cat <<EOF
{
  "@type": "MessageCard", "@context": "https://schema.org/extensions",
  "themeColor": "${COLOR#\#}",
  "summary": "${HEADLINE}",
  "title": "${HEADLINE}",
  "text": "$(echo -e "${BODY}" | sed ':a;N;$!ba;s/\n/<br>/g')"
}
EOF
)
  curl -sf -X POST -H 'Content-Type: application/json' -d "${PAYLOAD}" "${TEAMS_WEBHOOK_URL}" \
    && echo "Teams notification sent." || echo "WARNING: Teams notification failed."
else
  echo "TEAMS_WEBHOOK_URL not configured — skipping Teams."
fi
