#!/usr/bin/env bash
# Delete a CI Helm release, namespace, and RDS databases for one instance.
# Required env:
#   INSTANCE          instance id (not an image tag)
#   USER_MYSQL_ENG, PASS_MYSQL_ENG, RDS_ENG
# Optional:
#   DELETE_HARBOR     true to delete the Harbor artifact (default false)
#   IMAGE_TAG         Harbor tag to delete when DELETE_HARBOR=true
#   REGISTRY_USERNAME, REGISTRY_PASSWORD, REGISTRY_HOST
set -u

FAILED=0
DELETE_HARBOR="${DELETE_HARBOR:-false}"

if [ -z "${INSTANCE:-}" ]; then
  echo "ERROR: INSTANCE is required"
  exit 1
fi

NAMESPACE="ci-${INSTANCE}-ns-pm4"
RELEASE="ci-${INSTANCE}"
deploy_db="pm4_ci-${INSTANCE}%"
deploy_ai="pm4_ci-${INSTANCE}_ai"

if [ ${#deploy_db} -lt 12 ]; then
  echo "ERROR: deploy_db safety check failed (length ${#deploy_db})"
  exit 1
fi

set +e

if kubectl get "namespace/${NAMESPACE}" >/dev/null 2>&1; then
  echo "Deleting Instance :: ${RELEASE}"
  helm delete "${RELEASE}" || true
  kubectl delete namespace "${NAMESPACE}" || true

  set -o pipefail
  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -N -e "SHOW DATABASES LIKE '${deploy_db}'" \
    | xargs -r -I{} mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP DATABASE IF EXISTS \`{}\`;"
  if [ $? -ne 0 ]; then
    echo "WARN: Failed dropping databases matching ${deploy_db}"
    FAILED=1
  fi
  set +o pipefail

  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP DATABASE IF EXISTS \`${deploy_ai}\`;"
  if [ $? -ne 0 ]; then
    echo "WARN: Failed dropping AI database ${deploy_ai}"
    FAILED=1
  fi

  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP USER IF EXISTS 'user_ci-${INSTANCE}'@'%'"
  if [ $? -ne 0 ]; then
    echo "WARN: Failed dropping user user_ci-${INSTANCE}"
    FAILED=1
  fi

  mysql -u"${USER_MYSQL_ENG}" -p"${PASS_MYSQL_ENG}" -h "${RDS_ENG}" -e "DROP USER IF EXISTS 'user_ci-${INSTANCE}_ai'@'%'"
  if [ $? -ne 0 ]; then
    echo "WARN: Failed dropping user user_ci-${INSTANCE}_ai"
    FAILED=1
  fi

  echo "The instance [https://ci-${INSTANCE}.engk8s.processmaker.net] was deleted."
else
  echo "Namespace ${NAMESPACE} not found; nothing to delete on the cluster."
fi

if [ "${DELETE_HARBOR}" = "true" ]; then
  if [ -z "${IMAGE_TAG:-}" ]; then
    echo "ERROR: IMAGE_TAG is required when DELETE_HARBOR=true"
    exit 1
  fi
  echo "Deleting image from Harbor: ${IMAGE_TAG}"
  HTTP_CODE=$(curl -s -o /tmp/harbor_delete_out -w "%{http_code}" -X DELETE \
    -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" \
    "https://${REGISTRY_HOST}/api/v2.0/projects/processmaker/repositories/enterprise/artifacts/${IMAGE_TAG}")
  if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ]; then
    echo "Harbor image deleted (HTTP ${HTTP_CODE})"
  elif [ "${HTTP_CODE}" = "404" ]; then
    echo "Harbor image not found (already deleted)"
  else
    echo "WARN: Failed deleting Harbor image ${IMAGE_TAG} (HTTP ${HTTP_CODE})"
    cat /tmp/harbor_delete_out || true
    FAILED=1
  fi
else
  echo "Skipping Harbor image delete"
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "One or more delete operations failed"
  exit 1
fi

echo "Delete completed successfully"
