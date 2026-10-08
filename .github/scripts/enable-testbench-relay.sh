#!/bin/bash
set -euo pipefail

INSTANCE="${1:?INSTANCE id required (e.g. nt-amd64 or 10-char md5)}"
RELEASE="ci-${INSTANCE}"
NAMESPACE="${RELEASE}-ns-pm4"
DEPLOYMENT="${RELEASE}-testbench-runner-relay"

if [ -z "${TAILSCALE_AUTH_KEY_CI_RELAY:-}" ]; then
  echo "TAILSCALE_AUTH_KEY_CI_RELAY is required"
  exit 1
fi

if [ -z "${versionHelm:-}" ]; then
  echo "versionHelm is required"
  exit 1
fi

if [ -z "${HELM_REPO:-}" ] || [ -z "${HELM_USERNAME:-}" ] || [ -z "${HELM_PASSWORD:-}" ]; then
  echo "HELM_REPO, HELM_USERNAME, and HELM_PASSWORD are required"
  exit 1
fi

RELAY_VALUES="${RELAY_VALUES_FILE:-.github/templates/testbench-relay.yaml}"
if [ ! -f "${RELAY_VALUES}" ]; then
  echo "Relay values file not found: ${RELAY_VALUES}"
  exit 1
fi

RELAY_VALUES_RENDERED=$(mktemp)
sed "s#{{INSTANCE}}#${INSTANCE}#g" "${RELAY_VALUES}" > "${RELAY_VALUES_RENDERED}"
trap 'rm -f "${RELAY_VALUES_RENDERED}"' EXIT

helm repo add processmaker "${HELM_REPO}" --username "${HELM_USERNAME}" --password "${HELM_PASSWORD}" 2>/dev/null || true
helm repo update

echo "Enabling testbench runner relay for release ${RELEASE} (upstream tb-ci-${INSTANCE})..."
helm upgrade --timeout 15m "${RELEASE}" processmaker/enterprise \
  --reuse-values \
  -f "${RELAY_VALUES_RENDERED}" \
  --set testbenchRunnerRelay.enable=true \
  --set "testbenchRunnerRelay.upstreamHost=tb-ci-${INSTANCE}" \
  --set "testbenchRunnerRelay.tailscale.authKey=${TAILSCALE_AUTH_KEY_CI_RELAY}" \
  --version "${versionHelm}"

if kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=180s
else
  echo "Warning: deployment ${DEPLOYMENT} not found after upgrade"
  kubectl get pods -n "${NAMESPACE}" -l service=testbench-runner-relay || true
  exit 1
fi

echo "Testbench runner relay is ready."
