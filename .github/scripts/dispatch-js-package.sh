#!/usr/bin/env bash
# Dispatch js-package.yml on a target repo and wait until it finishes.
#
# Required env:
#   TARGET_REPO   owner/name (e.g. ProcessMaker/modeler)
#   BRANCH        git ref to run the workflow on
#   STACK_ID      stack id (matched in run-name / displayTitle)
#
# Optional env (passed as workflow_dispatch inputs):
#   SOURCE_REPO, SOURCE_RUN_ID, ORIGIN_BRANCH
#   BRANCH_MAP, CASCADE_STOP_BEFORE, TRIGGER_REPO, TRIGGER_HEAD_REF
#
# Prints run_id. Also writes run_id to GITHUB_OUTPUT when set.
set -euo pipefail

TARGET_REPO="${TARGET_REPO:?}"
BRANCH="${BRANCH:?}"
STACK_ID="${STACK_ID:?}"

args=(
  workflow run js-package.yml
  --repo "$TARGET_REPO"
  --ref "$BRANCH"
  -f "stack_id=${STACK_ID}"
)
if [ -n "${SOURCE_REPO:-}" ]; then
  args+=(-f "source_repo=${SOURCE_REPO}")
fi
if [ -n "${SOURCE_RUN_ID:-}" ]; then
  args+=(-f "source_run_id=${SOURCE_RUN_ID}")
fi
if [ -n "${ORIGIN_BRANCH:-}" ]; then
  args+=(-f "origin_branch=${ORIGIN_BRANCH}")
fi
if [ -n "${BRANCH_MAP:-}" ]; then
  args+=(-f "branch_map=${BRANCH_MAP}")
fi
if [ -n "${CASCADE_STOP_BEFORE:-}" ]; then
  args+=(-f "cascade_stop_before=${CASCADE_STOP_BEFORE}")
fi
if [ -n "${TRIGGER_REPO:-}" ]; then
  args+=(-f "trigger_repo=${TRIGGER_REPO}")
fi
if [ -n "${TRIGGER_HEAD_REF:-}" ]; then
  args+=(-f "trigger_head_ref=${TRIGGER_HEAD_REF}")
fi

echo "Dispatching ${TARGET_REPO} on ${BRANCH} (stack ${STACK_ID})"
gh "${args[@]}"

run_id=""
for _ in $(seq 1 36); do
  sleep 5
  gh run list --repo "$TARGET_REPO" --workflow js-package.yml --event workflow_dispatch --limit 10 \
    --json databaseId,displayTitle,createdAt > /tmp/js-stack-runs.json
  run_id=$(jq -r --arg sid "$STACK_ID" '
    map(select(.displayTitle | contains($sid))) | sort_by(.createdAt) | reverse | .[0].databaseId // empty
  ' /tmp/js-stack-runs.json)
  if [ -n "$run_id" ]; then
    break
  fi
done
if [ -z "$run_id" ]; then
  echo "::error::Timed out waiting for ${TARGET_REPO} workflow to start"
  exit 1
fi

echo "Watching ${TARGET_REPO} run ${run_id}"
gh run watch "$run_id" --repo "$TARGET_REPO" --exit-status

echo "$run_id" > /tmp/js-dispatch-run-id
echo "$TARGET_REPO" > /tmp/js-dispatch-repo
echo "run_id=$run_id"
if [ "${WRITE_GITHUB_OUTPUT:-}" = "true" ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "run_id=$run_id" >> "$GITHUB_OUTPUT"
  echo "repo=$TARGET_REPO" >> "$GITHUB_OUTPUT"
fi
