#!/usr/bin/env bash
# Deploy (or upgrade) one CI instance. Placeholders {{INSTANCE}} are sed-substituted
# by the workflow before this script runs.
set -euo pipefail

NAMESPACE="ci-{{INSTANCE}}-ns-pm4"
RELEASE="ci-{{INSTANCE}}"
HELM_CHART_ARGS=()

echo "NAMESPACE : ${NAMESPACE}"

# Prefer the chart cloned by the Common action (ci:k8s-branch) so unpublished
# template fixes are picked up without waiting on a Harbor chart publish.
resolve_chart_args() {
  local chart_ref="${PM4_K8S_CHART:-}"
  if [ -z "${chart_ref}" ] && [ -f pm4-k8s-distribution/charts/enterprise/Chart.yaml ]; then
    chart_ref="pm4-k8s-distribution/charts/enterprise"
  fi
  if [ -z "${chart_ref}" ] && [ -f ../pm4-k8s-distribution/charts/enterprise/Chart.yaml ]; then
    chart_ref="../pm4-k8s-distribution/charts/enterprise"
  fi

  if [ -n "${chart_ref}" ]; then
    echo "Using local enterprise chart: ${chart_ref}"
    HELM_CHART_ARGS=("${chart_ref}")
    return 0
  fi

  if [ -z "${versionHelm:-}" ]; then
    echo "versionHelm is required when no local chart is available"
    exit 1
  fi
  if [ -z "${HELM_REPO:-}" ] || [ -z "${HELM_USERNAME:-}" ] || [ -z "${HELM_PASSWORD:-}" ]; then
    echo "HELM_REPO, HELM_USERNAME, and HELM_PASSWORD are required when no local chart is available"
    exit 1
  fi
  helm repo add processmaker "${HELM_REPO}" --username "${HELM_USERNAME}" --password "${HELM_PASSWORD}"
  helm repo update
  echo "Using published enterprise chart version ${versionHelm}"
  HELM_CHART_ARGS=(processmaker/enterprise --version "${versionHelm}")
}

resolve_chart_args

helm_common_sets() {
  echo \
    --set "deploy.web.octane.enable=${OCTANE:-false}" \
    --set "deploy.pmai.openaiApiKey=${OPENAI_API_KEY:-}" \
    --set "analytics.awsAccessKey=${ANALYTICS_AWS_ACCESS_KEY:-}" \
    --set "analytics.awsSecretKey=${ANALYTICS_AWS_SECRET_KEY:-}" \
    --set "dockerRegistry.password=${REGISTRY_PASSWORD:-}" \
    --set "dockerRegistry.url=${REGISTRY_HOST:-}" \
    --set "dockerRegistry.username=${REGISTRY_USERNAME:-}" \
    --set "twilio.sid=${TWILIO_SID:-}" \
    --set "twilio.token=${TWILIO_TOKEN:-}" \
    --set "appVersion=${APP_VERSION}"
}

# Optional: TLS_SECRET_DIR with a stashed LE cert from a prior delete (GHA artifact).
# Restore before helm install so cert-manager does not burn a new Let's Encrypt issuance.
restore_stashed_tls() {
  if [ -z "${TLS_SECRET_DIR:-}" ]; then
    return 0
  fi
  export INSTANCE="{{INSTANCE}}"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "${SCRIPT_DIR}/restore-tls-secret.sh"
}

# Annotate a pre-created namespace and tell the chart not to render its
# Namespace pre-install hook (that hook's before-hook-creation delete would
# terminate this namespace mid-install; resource-policy keep does not apply
# on Helm's hook Delete path).
protect_precreated_namespace() {
  kubectl annotate "namespace/${NAMESPACE}" \
    "helm.sh/resource-policy=keep" \
    --overwrite >/dev/null
  HELM_CHART_ARGS+=(--set "namespace.create=false")
}

wait_for_namespace_active() {
  local phase
  phase="$(kubectl get "namespace/${NAMESPACE}" -o jsonpath='{.status.phase}')"
  if [ "${phase}" != "Active" ]; then
    echo "ERROR: namespace ${NAMESPACE} phase is ${phase}, expected Active"
    exit 1
  fi
}

APP_VERSION=$(echo "$CI_PROJECT-$CI_PACKAGE_BRANCH" | sed "s;/;-;g" | sed "s/refs-heads-//g")

if ! kubectl get "namespace/${NAMESPACE}" >/dev/null 2>&1; then
  echo "New instance. Creating Namespace"
  kubectl create namespace "${NAMESPACE}"
  protect_precreated_namespace
  restore_stashed_tls
  wait_for_namespace_active

  echo "Creating DB"
  echo "Update instance yamls"
  echo "Creating DB :: pm4_ci-{{INSTANCE}}"
  cat .github/templates/db.yaml
  kubectl apply -f .github/templates/db.yaml --v=4

  while true; do
    DBSTATUS=$(kubectl get job "mysql-setup-job-ci-{{INSTANCE}}" -o jsonpath='{.status.succeeded}')
    if [[ "$DBSTATUS" == "1" ]]; then
      echo "MySQL Setup Job has completed."
      break
    else
      echo "MySQL Setup Job is still running. Checking again in 10 seconds..."
      sleep 10
    fi
  done

  echo "Removing Job"
  kubectl delete job "mysql-setup-job-ci-{{INSTANCE}}"
  echo "Deploying Instance :: {{INSTANCE}}"
  echo "OCTANE: ${OCTANE}"
  cat .github/templates/instance.yaml

  wait_for_namespace_active
  # shellcheck disable=SC2046
  helm install --timeout 75m -f .github/templates/instance.yaml "${RELEASE}" \
    "${HELM_CHART_ARGS[@]}" \
    $(helm_common_sets)
else
  echo "Instance exists. Running upgrade and bouncing pods"
  # shellcheck disable=SC2046
  helm upgrade --timeout 60m -f .github/templates/instance.yaml "${RELEASE}" \
    "${HELM_CHART_ARGS[@]}" \
    $(helm_common_sets)

  # Bounce pods (ignore missing roles)
  webPod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '/web/{print $1; exit}' || true)
  schedulerPod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '/scheduler/{print $1; exit}' || true)
  queuePod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '/queue/{print $1; exit}' || true)
  to_delete=()
  [ -n "${webPod}" ] && to_delete+=("${webPod}")
  [ -n "${schedulerPod}" ] && to_delete+=("${schedulerPod}")
  [ -n "${queuePod}" ] && to_delete+=("${queuePod}")
  if [ "${#to_delete[@]}" -gt 0 ]; then
    kubectl delete pod "${to_delete[@]}" -n "${NAMESPACE}"
  fi
fi

if [ "${MULTITENANCY}" = "true" ]; then
  export INSTANCE_URL="https://tenant-1.ci-{{INSTANCE}}${DOM_EKS}"
else
  export INSTANCE_URL="https://ci-{{INSTANCE}}${DOM_EKS}"
fi
echo "INSTANCE_URL=${INSTANCE_URL}" >> "${GITHUB_ENV}"
./pm4-k8s-distribution/images/pm4-tools/pm wait-for-instance-ready
