#!/usr/bin/env bash
# Export a CI instance TLS secret to a directory for GHA artifact upload.
# Required env:
#   INSTANCE       instance id (e.g. 2a0d55eb59 or nt-fpm-st)
#   PRESERVE_TLS_DIR  directory to write tls.crt / tls.key [/ ca.crt]
# Exits 0 always. Creates PRESERVE_TLS_DIR/stashed when a usable cert was exported.
set -u

INSTANCE="${INSTANCE:-}"
PRESERVE_TLS_DIR="${PRESERVE_TLS_DIR:-}"
NAMESPACE="ci-${INSTANCE}-ns-pm4"
SECRET="ci-${INSTANCE}-tls-secret"

if [ -z "${INSTANCE}" ] || [ -z "${PRESERVE_TLS_DIR}" ]; then
  echo "WARN: INSTANCE and PRESERVE_TLS_DIR are required; skipping TLS export"
  exit 0
fi

rm -rf "${PRESERVE_TLS_DIR}"
mkdir -p "${PRESERVE_TLS_DIR}"

if ! kubectl get "namespace/${NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace ${NAMESPACE} not found; nothing to stash"
  exit 0
fi

if ! kubectl get "secret/${SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Secret ${SECRET} not found in ${NAMESPACE}; nothing to stash"
  exit 0
fi

if ! kubectl get "secret/${SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >"${PRESERVE_TLS_DIR}/tls.crt"; then
  echo "WARN: Failed reading tls.crt from ${SECRET}"
  rm -rf "${PRESERVE_TLS_DIR}"
  mkdir -p "${PRESERVE_TLS_DIR}"
  exit 0
fi

if ! kubectl get "secret/${SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d >"${PRESERVE_TLS_DIR}/tls.key"; then
  echo "WARN: Failed reading tls.key from ${SECRET}"
  rm -rf "${PRESERVE_TLS_DIR}"
  mkdir -p "${PRESERVE_TLS_DIR}"
  exit 0
fi

# Optional CA bundle (present for some issuers; harmless if missing).
kubectl get "secret/${SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"${PRESERVE_TLS_DIR}/ca.crt" || true
if [ ! -s "${PRESERVE_TLS_DIR}/ca.crt" ]; then
  rm -f "${PRESERVE_TLS_DIR}/ca.crt"
fi

if [ ! -s "${PRESERVE_TLS_DIR}/tls.crt" ] || [ ! -s "${PRESERVE_TLS_DIR}/tls.key" ]; then
  echo "WARN: Exported tls.crt/tls.key empty; not stashing"
  rm -rf "${PRESERVE_TLS_DIR}"
  mkdir -p "${PRESERVE_TLS_DIR}"
  exit 0
fi

if command -v openssl >/dev/null 2>&1; then
  if ! openssl x509 -in "${PRESERVE_TLS_DIR}/tls.crt" -noout -checkend 86400 >/dev/null 2>&1; then
    echo "WARN: Certificate expired or expires within 24h; not stashing"
    rm -rf "${PRESERVE_TLS_DIR}"
    mkdir -p "${PRESERVE_TLS_DIR}"
    exit 0
  fi
  echo "Stashing TLS cert:"
  openssl x509 -in "${PRESERVE_TLS_DIR}/tls.crt" -noout -subject -issuer -dates 2>/dev/null || true
else
  echo "openssl not available; skipping expiry check"
fi

chmod 600 "${PRESERVE_TLS_DIR}/tls.key"
# Non-dot marker so actions/upload-artifact reliably includes it.
touch "${PRESERVE_TLS_DIR}/stashed"
echo "TLS secret ${SECRET} exported to ${PRESERVE_TLS_DIR}"
exit 0
