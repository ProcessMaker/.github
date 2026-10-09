#!/bin/bash
# Prepare an existing in-cluster testbench relay for a local/CI runner join (no Helm).
# Run before the runner Tailscale node comes up (start.sh with ENSURE_TESTBENCH_RELAY_SCRIPT).
set -euo pipefail

INSTANCE="${1:?INSTANCE id required (e.g. nt-amd64 or 10-char md5)}"
RELEASE="ci-${INSTANCE}"
NAMESPACE="${RELEASE}-ns-pm4"
DEPLOYMENT="${RELEASE}-testbench-runner-relay"
RELAY_DEPLOY="deploy/${DEPLOYMENT}"
CONFIGMAP="${RELEASE}-testbench-runner-relay"
SECRET="${RELEASE}-testbench-relay-tailscale"
UPSTREAM_HOST="tb-ci-${INSTANCE}"
ROLLOUT_TIMEOUT_SEC="${RELAY_ROLLOUT_TIMEOUT_SEC:-180}"
RELAY_HAPROXY_CHECK_INTER="${RELAY_HAPROXY_CHECK_INTER:-60s}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required to ensure the testbench runner relay"
  exit 1
fi

if ! kubectl get "${RELAY_DEPLOY}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Relay deployment not found: ${DEPLOYMENT} in namespace ${NAMESPACE}."
  echo ""
  echo "The testbench runner relay was never enabled for this CI instance."
  echo "Run a CI testbench job once (enable-testbench-relay.sh), or use Helm with"
  echo "enable-testbench-relay.sh when HELM credentials are available."
  exit 1
fi

echo "Ensuring testbench runner relay for ${RELEASE} (upstream ${UPSTREAM_HOST})..."

if kubectl get configmap "${CONFIGMAP}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  haproxy_cfg="$(kubectl get configmap "${CONFIGMAP}" -n "${NAMESPACE}" -o jsonpath='{.data.haproxy\.cfg}')"
  patched_cfg="$(printf '%s' "${haproxy_cfg}" \
    | sed -E "s/server runner [^:]+:/server runner ${UPSTREAM_HOST}:/g" \
    | sed -E "s/check inter [0-9]+[smhd]+/check inter ${RELAY_HAPROXY_CHECK_INTER}/g")"
  if [ "${patched_cfg}" = "${haproxy_cfg}" ]; then
    echo "ConfigMap upstream (${UPSTREAM_HOST}) and health check interval (${RELAY_HAPROXY_CHECK_INTER}) already set."
  else
    echo "Patching ConfigMap ${CONFIGMAP} (upstream ${UPSTREAM_HOST}, check inter ${RELAY_HAPROXY_CHECK_INTER})..."
    kubectl create configmap "${CONFIGMAP}" -n "${NAMESPACE}" \
      --from-literal=haproxy.cfg="${patched_cfg}" \
      --dry-run=client -o yaml \
      | kubectl apply -f -
  fi
else
  echo "WARNING: ConfigMap ${CONFIGMAP} not found; skipping HAProxy patch"
fi

if [ -n "${TAILSCALE_AUTH_KEY_CI_RELAY:-}" ]; then
  if kubectl get secret "${SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Refreshing relay Tailscale auth key secret ${SECRET}..."
    kubectl create secret generic "${SECRET}" -n "${NAMESPACE}" \
      --from-literal=TS_AUTHKEY="${TAILSCALE_AUTH_KEY_CI_RELAY}" \
      --dry-run=client -o yaml \
      | kubectl apply -f -
  else
    echo "WARNING: Secret ${SECRET} not found; skipping auth key refresh"
  fi
fi

echo "Restarting relay deployment (refresh HAProxy / MagicDNS for ${UPSTREAM_HOST})..."
kubectl rollout restart "${RELAY_DEPLOY}" -n "${NAMESPACE}"
if ! kubectl rollout status "${RELAY_DEPLOY}" -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT_SEC}s"; then
  echo "Relay rollout failed after restart."
  kubectl get pods -n "${NAMESPACE}" -l service=testbench-runner-relay -o wide || true
  kubectl logs -n "${NAMESPACE}" -l service=testbench-runner-relay --tail=100 || true
  exit 1
fi

echo "Testbench runner relay is ready for runner ${UPSTREAM_HOST}."
