#!/usr/bin/env bash
# Delete a CI Helm release, namespace, and RDS databases for one instance.
#
# Idempotent: "already gone" is success. Unexpected errors are recorded and the
# script still attempts later phases, then exits non-zero if anything failed.
#
# Required env:
#   INSTANCE          instance id (not an image tag)
#   USER_MYSQL_ENG, PASS_MYSQL_ENG, RDS_ENG
# Optional:
#   DELETE_HARBOR     true to delete the Harbor artifact (default false)
#   IMAGE_TAG         Harbor tag to delete when DELETE_HARBOR=true
#   REGISTRY_USERNAME, REGISTRY_PASSWORD, REGISTRY_HOST
#   PRESERVE_TLS_DIR  if set, export TLS secret here before wiping the namespace
#                     (for GHA artifact restore on redeploy)
#   HELM_UNINSTALL_TIMEOUT   helm uninstall --timeout (default 10m)
#   NAMESPACE_DELETE_TIMEOUT kubectl delete ns --timeout (default 600s)
set -u

FAILED=0
DELETE_HARBOR="${DELETE_HARBOR:-false}"
HELM_UNINSTALL_TIMEOUT="${HELM_UNINSTALL_TIMEOUT:-10m}"
NAMESPACE_DELETE_TIMEOUT="${NAMESPACE_DELETE_TIMEOUT:-600s}"

if [ -z "${INSTANCE:-}" ]; then
  echo "ERROR: INSTANCE is required"
  exit 1
fi

NAMESPACE="ci-${INSTANCE}-ns-pm4"
RELEASE="ci-${INSTANCE}"
deploy_db="pm4_ci-${INSTANCE}%"
deploy_ai="pm4_ci-${INSTANCE}_ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ${#deploy_db} -lt 12 ]; then
  echo "ERROR: deploy_db safety check failed (length ${#deploy_db})"
  exit 1
fi

set +e

mark_failed() {
  echo "ERROR: $*"
  FAILED=1
}

is_not_found() {
  # helm/kubectl stderr for missing resources
  printf '%s' "$1" | grep -Eiq 'not found|release: not found|Error: release: not found'
}

preserve_tls() {
  if [ -z "${PRESERVE_TLS_DIR:-}" ]; then
    return 0
  fi
  echo "Preserving TLS secret before delete (PRESERVE_TLS_DIR=${PRESERVE_TLS_DIR})"
  # shellcheck disable=SC1091
  bash "${SCRIPT_DIR}/export-tls-secret.sh"
}

uninstall_helm() {
  echo "Deleting Helm release :: ${RELEASE}"

  # Release metadata lives in the kube-context namespace (default for CI runners).
  # Always attempt uninstall so orphaned releases cannot block the next install.
  status_out="$(helm status "${RELEASE}" 2>&1)"
  status_rc=$?
  if [ "${status_rc}" -ne 0 ]; then
    if is_not_found "${status_out}"; then
      echo "Helm release ${RELEASE} not found; skipping uninstall"
      return 0
    fi
    mark_failed "helm status ${RELEASE} failed unexpectedly: ${status_out}"
    return 1
  fi

  echo "Uninstalling Helm release ${RELEASE} (timeout ${HELM_UNINSTALL_TIMEOUT})"
  uninstall_out="$(helm uninstall "${RELEASE}" --wait --timeout "${HELM_UNINSTALL_TIMEOUT}" 2>&1)"
  uninstall_rc=$?
  echo "${uninstall_out}"

  if [ "${uninstall_rc}" -eq 0 ]; then
    echo "Helm release ${RELEASE} uninstalled"
    return 0
  fi

  # Race: another delete finished it
  if ! helm status "${RELEASE}" >/dev/null 2>&1; then
    echo "Helm release ${RELEASE} already gone after uninstall attempt"
    return 0
  fi

  mark_failed "helm uninstall ${RELEASE} failed"
  return 1
}

delete_namespace() {
  echo "Deleting namespace :: ${NAMESPACE}"

  if ! kubectl get "namespace/${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace ${NAMESPACE} not found; skipping namespace delete"
    return 0
  fi

  echo "Deleting namespace ${NAMESPACE} (timeout ${NAMESPACE_DELETE_TIMEOUT})"
  delete_out="$(kubectl delete "namespace/${NAMESPACE}" --timeout="${NAMESPACE_DELETE_TIMEOUT}" 2>&1)"
  delete_rc=$?
  echo "${delete_out}"

  if [ "${delete_rc}" -eq 0 ]; then
    echo "Namespace ${NAMESPACE} deleted"
    echo "The instance [https://ci-${INSTANCE}.engk8s.processmaker.net] was removed from the cluster."
    return 0
  fi

  if is_not_found "${delete_out}"; then
    echo "Namespace ${NAMESPACE} already gone"
    return 0
  fi

  if ! kubectl get "namespace/${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace ${NAMESPACE} already gone after delete attempt"
    return 0
  fi

  mark_failed "kubectl delete namespace ${NAMESPACE} failed (still present or timed out)"
  kubectl get "namespace/${NAMESPACE}" -o wide 2>&1 || true
  return 1
}

delete_rds() {
  echo "Cleaning RDS for instance ${INSTANCE} (always runs, even when the namespace is already gone)."
  local rds_failed=0

  set -o pipefail
  matching_dbs=$(
    mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -N -e "SHOW DATABASES LIKE '${deploy_db}'"
  )
  list_status=$?
  set +o pipefail

  if [ "${list_status}" -ne 0 ]; then
    mark_failed "Failed listing databases matching ${deploy_db}"
    return 1
  fi

  if [ -z "${matching_dbs}" ]; then
    echo "No databases matching ${deploy_db} on RDS (already clean)."
  else
    echo "Dropping databases matching ${deploy_db}:"
    echo "${matching_dbs}"
    set -o pipefail
    echo "${matching_dbs}" | xargs -r -I{} mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP DATABASE IF EXISTS \`{}\`;"
    if [ $? -ne 0 ]; then
      mark_failed "Failed dropping databases matching ${deploy_db}"
      rds_failed=1
    fi
    set +o pipefail
  fi

  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP DATABASE IF EXISTS \`${deploy_ai}\`;"
  if [ $? -ne 0 ]; then
    mark_failed "Failed dropping AI database ${deploy_ai}"
    rds_failed=1
  fi

  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP USER IF EXISTS 'user_ci-${INSTANCE}'@'%'"
  if [ $? -ne 0 ]; then
    mark_failed "Failed dropping user user_ci-${INSTANCE}"
    rds_failed=1
  fi

  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP USER IF EXISTS 'user_ci-${INSTANCE}_ai'@'%'"
  if [ $? -ne 0 ]; then
    mark_failed "Failed dropping user user_ci-${INSTANCE}_ai"
    rds_failed=1
  fi

  return "${rds_failed}"
}

delete_harbor() {
  if [ "${DELETE_HARBOR}" != "true" ]; then
    echo "Skipping Harbor image delete"
    return 0
  fi

  if [ -z "${IMAGE_TAG:-}" ]; then
    mark_failed "IMAGE_TAG is required when DELETE_HARBOR=true"
    return 1
  fi

  echo "Deleting image from Harbor: ${IMAGE_TAG}"
  HTTP_CODE=$(curl -s -o /tmp/harbor_delete_out -w "%{http_code}" -X DELETE \
    -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" \
    "https://${REGISTRY_HOST}/api/v2.0/projects/processmaker/repositories/enterprise/artifacts/${IMAGE_TAG}")
  if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ]; then
    echo "Harbor image deleted (HTTP ${HTTP_CODE})"
    return 0
  fi
  if [ "${HTTP_CODE}" = "404" ]; then
    echo "Harbor image not found (already deleted)"
    return 0
  fi

  mark_failed "Failed deleting Harbor image ${IMAGE_TAG} (HTTP ${HTTP_CODE})"
  cat /tmp/harbor_delete_out || true
  return 1
}

# Always attempt every phase so a retry can finish leftover work from a partial delete.
preserve_tls
uninstall_helm
delete_namespace
delete_rds
delete_harbor

if [ "${FAILED}" -ne 0 ]; then
  echo "One or more delete operations failed (see ERROR lines above)"
  exit 1
fi

echo "Delete completed successfully"
