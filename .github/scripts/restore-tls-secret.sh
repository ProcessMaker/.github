#!/usr/bin/env bash
# Restore a stashed CI TLS secret into the instance namespace before helm install
# so cert-manager does not request a new Let's Encrypt certificate.
# Required env:
#   INSTANCE         instance id
#   TLS_SECRET_DIR   directory with tls.crt / tls.key from export-tls-secret.sh
# Creates the namespace if missing. Exits 0 if there is nothing to restore.
set -u

INSTANCE="${INSTANCE:-}"
TLS_SECRET_DIR="${TLS_SECRET_DIR:-}"
NAMESPACE="ci-${INSTANCE}-ns-pm4"
SECRET="ci-${INSTANCE}-tls-secret"

if [ -z "${INSTANCE}" ] || [ -z "${TLS_SECRET_DIR}" ]; then
  echo "TLS restore skipped (INSTANCE or TLS_SECRET_DIR unset)"
  exit 0
fi

if [ ! -s "${TLS_SECRET_DIR}/tls.crt" ] || [ ! -s "${TLS_SECRET_DIR}/tls.key" ]; then
  echo "No stashed TLS secret at ${TLS_SECRET_DIR}; cert-manager will issue if needed"
  exit 0
fi

if command -v openssl >/dev/null 2>&1; then
  if ! openssl x509 -in "${TLS_SECRET_DIR}/tls.crt" -noout -checkend 86400 >/dev/null 2>&1; then
    echo "WARN: Stashed certificate expired or expires within 24h; not restoring"
    exit 0
  fi
fi

if ! kubectl get "namespace/${NAMESPACE}" >/dev/null 2>&1; then
  echo "Creating namespace ${NAMESPACE} for TLS restore"
  kubectl create namespace "${NAMESPACE}"
fi

echo "Restoring TLS secret ${SECRET} into ${NAMESPACE}"
kubectl create secret tls "${SECRET}" \
  --cert="${TLS_SECRET_DIR}/tls.crt" \
  --key="${TLS_SECRET_DIR}/tls.key" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -s "${TLS_SECRET_DIR}/ca.crt" ]; then
  # Attach ca.crt when present (create secret tls does not include it).
  CA_B64=$(base64 <"${TLS_SECRET_DIR}/ca.crt" | tr -d '\n')
  kubectl patch secret "${SECRET}" -n "${NAMESPACE}" --type merge -p "{\"data\":{\"ca.crt\":\"${CA_B64}\"}}"
fi

# Help cert-manager adopt the existing secret for the ingress-managed Certificate.
kubectl annotate secret "${SECRET}" -n "${NAMESPACE}" \
  "cert-manager.io/certificate-name=${SECRET}" \
  --overwrite >/dev/null

echo "TLS secret restored; cert-manager should adopt instead of re-issuing"
exit 0
