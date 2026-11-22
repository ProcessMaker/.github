#!/usr/bin/env bash
# Deploy a single performance Helm release (baseline or update).
# Only one release should exist at a time; run cleanup before deploying the other.
# Usage: RELEASE_NAME=<e.g. ci-INSTANCE-perf-baseline> APP_VERSION=<develop|IMAGE_TAG> INSTANCE=<10-char> \
#        [versionHelm=...] [env vars for secrets] ./deploy-perf-instance.sh
# Expects: .github/templates/instance-perf.yaml with {{INSTANCE}}, {{APP_VERSION}}, {{CUSTOMER_LICENSES_PAT}}, {{KEYCLOAK_*}} substituted.
set -euo pipefail

RELEASE_NAME="${RELEASE_NAME:?RELEASE_NAME is required (e.g. ci-abc123-perf-baseline)}"
APP_VERSION="${APP_VERSION:?APP_VERSION is required (e.g. develop or IMAGE_TAG)}"
INSTANCE="${INSTANCE:?INSTANCE is required (10-char id)}"
NAMESPACE="${NAMESPACE:-default}"

echo "Deploying performance release: ${RELEASE_NAME} (appVersion=${APP_VERSION}) in namespace ${NAMESPACE}"

helm repo add processmaker "${HELM_REPO}" --username "${HELM_USERNAME}" --password "${HELM_PASSWORD}" && helm repo update

# Always try to uninstall from the target namespace so re-run can reuse the release name (no longer gated on old namespace existing).
echo "Cleaning up any existing release ${RELEASE_NAME} in ${NAMESPACE}..."
helm uninstall "${RELEASE_NAME}" --namespace "${NAMESPACE}" 2>/dev/null || true
if [ "${NAMESPACE}" != "default" ]; then
  if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    kubectl delete namespace "${NAMESPACE}" --timeout=120s || true
    sleep 5
  fi
  kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
else
  sleep 2
fi

echo "Installing Helm release ${RELEASE_NAME}..."
helm install --timeout 75m -f .github/templates/instance-perf.yaml "${RELEASE_NAME}" processmaker/enterprise \
  --namespace "${NAMESPACE}" \
  --set deploy.pmai.openaiApiKey="${OPENAI_API_KEY}" \
  --set analytics.awsAccessKey="${ANALYTICS_AWS_ACCESS_KEY}" \
  --set analytics.awsSecretKey="${ANALYTICS_AWS_SECRET_KEY}" \
  --set dockerRegistry.password="${REGISTRY_PASSWORD}" \
  --set dockerRegistry.url="${REGISTRY_HOST}" \
  --set dockerRegistry.username="${REGISTRY_USERNAME}" \
  --set twilio.sid="${TWILIO_SID}" \
  --set twilio.token="${TWILIO_TOKEN}" \
  --set appVersion="${APP_VERSION}" \
  --version "${versionHelm}"

export INSTANCE_URL="https://${RELEASE_NAME}.engk8s.processmaker.net"
echo "INSTANCE_URL=${INSTANCE_URL}" >> "${GITHUB_ENV:-/dev/stdout}"
echo "Waiting for instance to be ready at ${INSTANCE_URL}"
./pm4-k8s-distribution/images/pm4-tools/pm wait-for-instance-ready || true