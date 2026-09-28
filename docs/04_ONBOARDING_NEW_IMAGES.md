# 04 — Onboarding a New Image onto the Pipeline

The POC covers `spark-kyuubi-image/`. This guide is the repeatable recipe for
bringing every additional TESCO image onto the same framework (the "rollout"
phase of the proposal).

---

## Step 1 — Create the image directory

Copy the POC directory as a template:

```text
<new-image-name>/
├── Dockerfile                  # multi-stage, pinned versions, non-root, HEALTHCHECK
├── .dockerignore
├── .hadolint.yaml              # start from the POC file; trim ignores
├── docker-compose.test.yml     # the image's test environment (+ any sidecars)
├── conf/                       # runtime configuration
└── tests/
    ├── unit/run_tests.sh       # static validation of Dockerfile/configs
    ├── smoke/smoke_test.sh     # health, ports, processes
    └── integration/integration_test.sh   # functional tests for THIS workload
```

Non-negotiables for every Dockerfile (the gate enforces most of these):
- Pinned base image (no `latest`), multi-stage build, non-root `USER`,
  `HEALTHCHECK`, no secrets in any layer.

## Step 2 — Write the tests for this workload

- **Smoke**: adapt ports/process names/health URL.
- **Integration**: automate the manual test checklist the testing team uses
  for this image today — one `record()` block per manual check, so the JUnit
  report mirrors the manual checklist 1:1.

## Step 3 — Wire the pipeline

Option A (quickest): run the existing workflow with
`workflow_dispatch → image_dir: <new-image-name>` and add the new path to the
`on.push.paths` list.

Option B (recommended at >2 images): convert `image-pipeline.yml` into a
**reusable workflow** (`workflow_call` with `image_dir`/`image_name` inputs)
and add a thin per-image caller workflow. One pipeline definition, N images.

## Step 4 — First run & tuning

1. Trigger manually; expect Stage 2 findings on first contact — triage per
   docs/03 Part 3.
2. Tune startup timeouts in the smoke test for the workload's real boot time.
3. Get sign-off from the owning team that the integration tests cover their
   manual checklist.

## Step 5 — Register for ongoing coverage

- Add the released image reference to the `matrix.image` list in
  `.github/workflows/periodic-rescan.yml`.
- Add the owning team's notification channel to the routing config.
- Record the image + owner in the onboarding table below.

## Onboarded Images Register

| Image | Directory | Owner team | Onboarded | Re-scan enrolled |
|---|---|---|---|---|
| spark-kyuubi (POC) | `spark-kyuubi-image/` | Data Engineering | ✅ prototype | ✅ (placeholder ref) |
| *(next image)* | | | | |
