#!/bin/bash
set -euo pipefail

INSTANCE="${1:?INSTANCE id required}"
RELEASE="ci-${INSTANCE}"

if [ -z "${versionHelm:-}" ]; then
  echo "versionHelm is required"
  exit 1
fi

if [ -z "${HELM_REPO:-}" ] || [ -z "${HELM_USERNAME:-}" ] || [ -z "${HELM_PASSWORD:-}" ]; then
  echo "HELM_REPO, HELM_USERNAME, and HELM_PASSWORD are required"
  exit 1
fi

helm repo add processmaker "${HELM_REPO}" --username "${HELM_USERNAME}" --password "${HELM_PASSWORD}" 2>/dev/null || true
helm repo update

echo "Disabling testbench runner relay for release ${RELEASE}..."
# --no-hooks: relay-only change; skip post-upgrade update-pm4 (and other hooks).
helm upgrade --timeout 10m "${RELEASE}" processmaker/enterprise \
  --reuse-values \
  --no-hooks \
  --set testbenchRunnerRelay.enable=false \
  --set testbenchRunnerRelay.tailscale.authKey= \
  --version "${versionHelm}"

echo "Relay disabled."
