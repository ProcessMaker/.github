#!/bin/bash
# Fail-fast: prove PM → in-cluster relay → Tailscale → runner mail ports.
# Run after the runner has joined the tailnet as tb-ci-<INSTANCE> (start.sh).
#
# Restarts the relay Deployment first so HAProxy/MagicDNS pick up the current
# ephemeral runner IP (same hostname tb-ci-* can point at a dead peer from a
# previous testbench run if the relay pod was left running).
set -euo pipefail

INSTANCE="${1:?INSTANCE id required (e.g. nt-amd64 or 10-char md5)}"
RELEASE="ci-${INSTANCE}"
NAMESPACE="${RELEASE}-ns-pm4"
RELAY_DEPLOY="deploy/${RELEASE}-testbench-runner-relay"
WEB_DEPLOY="deploy/${RELEASE}-processmaker-web"
UPSTREAM_HOST="tb-ci-${INSTANCE}"
RELAY_SVC="${RELEASE}-testbench-relay"
NC_TIMEOUT_SEC="${RELAY_NC_TIMEOUT_SEC:-5}"
# Allow MagicDNS / DERP / HAProxy health to settle after runner joins / relay restart.
WAIT_SEC="${RELAY_VERIFY_WAIT_SEC:-90}"
POLL_SEC="${RELAY_VERIFY_POLL_SEC:-5}"
ROLLOUT_TIMEOUT_SEC="${RELAY_ROLLOUT_TIMEOUT_SEC:-180}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required to verify the testbench runner relay"
  exit 1
fi

dump_diagnostics() {
  echo ""
  echo "======== testbench runner relay diagnostics ========"
  echo "--- pods ---"
  kubectl get pods -n "${NAMESPACE}" -l service=testbench-runner-relay -o wide || true
  echo ""
  echo "--- relay deploy / svc ---"
  kubectl get deploy,svc -n "${NAMESPACE}" -l service=testbench-runner-relay 2>/dev/null || \
    kubectl get deploy "${RELEASE}-testbench-runner-relay" -n "${NAMESPACE}" 2>/dev/null || true
  kubectl get svc "${RELAY_SVC}" -n "${NAMESPACE}" 2>/dev/null || true
  echo ""
  echo "--- relay: tailscale status ---"
  kubectl exec -n "${NAMESPACE}" "${RELAY_DEPLOY}" -- tailscale status 2>&1 || true
  echo ""
  echo "--- relay: peer ${UPSTREAM_HOST} (json) ---"
  kubectl exec -n "${NAMESPACE}" "${RELAY_DEPLOY}" -- tailscale status --json 2>&1 \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('failed to parse status json:', e)
    sys.exit(0)
self = d.get('Self') or {}
print('Self:', self.get('HostName'), 'Tags:', self.get('Tags'), 'Online:', self.get('Online'))
for p in (d.get('Peer') or {}).values():
    host = p.get('HostName') or ''
    if host == '${UPSTREAM_HOST}' or '${INSTANCE}' in host:
        print(
            'Peer:', host,
            'Tags:', p.get('Tags'),
            'Online:', p.get('Online'),
            'RxBytes:', p.get('RxBytes'),
            'TxBytes:', p.get('TxBytes'),
            'LastSeen:', p.get('LastSeen'),
            'Relay:', p.get('Relay'),
            'CurAddr:', p.get('CurAddr'),
        )
" 2>&1 || true
  echo ""
  echo "--- relay logs (tail 100) ---"
  kubectl logs -n "${NAMESPACE}" -l service=testbench-runner-relay --tail=100 2>&1 || true
  echo ""
  echo "--- previous relay logs (if restarted) ---"
  kubectl logs -n "${NAMESPACE}" -l service=testbench-runner-relay --previous --tail=50 2>&1 || true
  echo ""
  echo "Hints:"
  echo "  - Confirm Tailscale ACL allows tag:ci-relay -> tag:ci-runner:587 and :993"
  echo "  - Confirm runner auth key has tag:ci-runner and relay key has tag:ci-relay"
  echo "  - Confirm runner hostname is ${UPSTREAM_HOST} (TS_HOSTNAME / start.sh)"
  echo "  - HAProxy 'no server available' / stale IP: relay must restart after runner joins"
  echo "  - Exit 137 on relay often means OOM; check memory limits"
  echo "===================================================="
}

echo "Verifying testbench runner relay path for ${RELEASE} (upstream ${UPSTREAM_HOST})..."

if ! kubectl get "${RELAY_DEPLOY}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Relay deployment not found: ${RELAY_DEPLOY} in ${NAMESPACE}"
  dump_diagnostics
  exit 1
fi

echo "--- restart relay (refresh HAProxy upstream for ${UPSTREAM_HOST}) ---"
kubectl rollout restart "${RELAY_DEPLOY}" -n "${NAMESPACE}"
if ! kubectl rollout status "${RELAY_DEPLOY}" -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT_SEC}s"; then
  echo "FAIL: relay rollout after restart did not complete"
  dump_diagnostics
  exit 1
fi

echo "--- web -> ${RELAY_SVC}:587 ---"
if ! kubectl exec -n "${NAMESPACE}" "${WEB_DEPLOY}" -c pm4-app-ui -- \
  sh -c "timeout ${NC_TIMEOUT_SEC} nc -zv ${RELAY_SVC} 587"; then
  echo "FAIL: web pod cannot reach relay Service :587"
  dump_diagnostics
  exit 1
fi

echo "--- web -> ${RELAY_SVC}:993 ---"
if ! kubectl exec -n "${NAMESPACE}" "${WEB_DEPLOY}" -c pm4-app-ui -- \
  sh -c "timeout ${NC_TIMEOUT_SEC} nc -zv ${RELAY_SVC} 993"; then
  echo "FAIL: web pod cannot reach relay Service :993"
  dump_diagnostics
  exit 1
fi

deadline=$((SECONDS + WAIT_SEC))
attempt=0
while true; do
  attempt=$((attempt + 1))
  echo "--- relay -> ${UPSTREAM_HOST}:587 (attempt ${attempt}, ${NC_TIMEOUT_SEC}s) ---"
  if kubectl exec -n "${NAMESPACE}" "${RELAY_DEPLOY}" -- \
    sh -c "timeout ${NC_TIMEOUT_SEC} nc -zv ${UPSTREAM_HOST} 587"; then
    echo "--- relay -> ${UPSTREAM_HOST}:993 ---"
    if kubectl exec -n "${NAMESPACE}" "${RELAY_DEPLOY}" -- \
      sh -c "timeout ${NC_TIMEOUT_SEC} nc -zv ${UPSTREAM_HOST} 993"; then
      echo "OK: cluster relay path is reachable (web -> relay svc -> ${UPSTREAM_HOST}:587/993)."
      exit 0
    fi
    echo "SMTP OK but IMAP :993 failed; will retry if time remains..."
  else
    echo "SMTP :587 not reachable yet..."
  fi

  if [ "${SECONDS}" -ge "${deadline}" ]; then
    break
  fi
  sleep "${POLL_SEC}"
done

echo "FAIL: relay pod cannot reach ${UPSTREAM_HOST}:587/993 over Tailscale within ${WAIT_SEC}s"
dump_diagnostics
exit 1
