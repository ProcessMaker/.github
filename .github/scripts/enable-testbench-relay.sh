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

RELAY_VALUES="${RELAY_VALUES_FILE:-.github/templates/testbench-relay.yaml}"
if [ ! -f "${RELAY_VALUES}" ]; then
  echo "Relay values file not found: ${RELAY_VALUES}"
  exit 1
fi

RELAY_VALUES_RENDERED=$(mktemp)
sed "s#{{INSTANCE}}#${INSTANCE}#g" "${RELAY_VALUES}" > "${RELAY_VALUES_RENDERED}"
trap 'rm -f "${RELAY_VALUES_RENDERED}"' EXIT

# Prefer the chart cloned by the Common action (ci:k8s-branch) so unpublished
# template fixes are picked up without waiting on a Harbor chart publish.
CHART_REF="${PM4_K8S_CHART:-}"
if [ -z "${CHART_REF}" ] && [ -f ../pm4-k8s-distribution/charts/enterprise/Chart.yaml ]; then
  CHART_REF="../pm4-k8s-distribution/charts/enterprise"
fi
if [ -z "${CHART_REF}" ] && [ -f pm4-k8s-distribution/charts/enterprise/Chart.yaml ]; then
  CHART_REF="pm4-k8s-distribution/charts/enterprise"
fi

HELM_CHART_ARGS=()
if [ -n "${CHART_REF}" ]; then
  echo "Using local enterprise chart: ${CHART_REF}"
  HELM_CHART_ARGS=("${CHART_REF}")
else
  if [ -z "${versionHelm:-}" ]; then
    echo "versionHelm is required when no local chart is available"
    exit 1
  fi
  if [ -z "${HELM_REPO:-}" ] || [ -z "${HELM_USERNAME:-}" ] || [ -z "${HELM_PASSWORD:-}" ]; then
    echo "HELM_REPO, HELM_USERNAME, and HELM_PASSWORD are required when no local chart is available"
    exit 1
  fi
  helm repo add processmaker "${HELM_REPO}" --username "${HELM_USERNAME}" --password "${HELM_PASSWORD}" 2>/dev/null || true
  helm repo update
  HELM_CHART_ARGS=(processmaker/enterprise --version "${versionHelm}")
fi

echo "Enabling testbench runner relay for release ${RELEASE} (upstream tb-ci-${INSTANCE})..."
# --no-hooks: instance is already ready; skip post-upgrade update-pm4 (and other hooks).
helm upgrade --timeout 15m "${RELEASE}" "${HELM_CHART_ARGS[@]}" \
  --reuse-values \
  --no-hooks \
  -f "${RELAY_VALUES_RENDERED}" \
  --set testbenchRunnerRelay.enable=true \
  --set "testbenchRunnerRelay.upstreamHost=tb-ci-${INSTANCE}" \
  --set "testbenchRunnerRelay.tailscale.authKey=${TAILSCALE_AUTH_KEY_CI_RELAY}"

if kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  if ! kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=180s; then
    echo "Relay rollout failed; collecting diagnostics..."
    kubectl get pods -n "${NAMESPACE}" -l service=testbench-runner-relay -o wide || true
    kubectl describe pods -n "${NAMESPACE}" -l service=testbench-runner-relay || true
    kubectl logs -n "${NAMESPACE}" -l service=testbench-runner-relay --tail=200 || true
    kubectl logs -n "${NAMESPACE}" -l service=testbench-runner-relay --previous --tail=200 || true
    exit 1
  fi
else
  echo "Warning: deployment ${DEPLOYMENT} not found after upgrade"
  kubectl get pods -n "${NAMESPACE}" -l service=testbench-runner-relay || true
  exit 1
fi

echo "Testbench runner relay is ready."
