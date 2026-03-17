#!/usr/bin/env bash
# Delete the dedicated EKS node group for performance tests.
# Usage: INSTANCE=<10-char-id> [EKS_CLUSTER_NAME=pm4-eng] [AWS_REGION=us-east-1] [EFS_SECURITY_GROUP_ID=sg-...] ./delete-perf-nodegroup.sh
# Idempotent: no-op if node group does not exist.
set -euo pipefail

INSTANCE="${INSTANCE:?INSTANCE is required (10-char instance id)}"
# Optional: baseline | update — must match the suffix used when creating the node group.
PERF_SUFFIX="${PERF_SUFFIX:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-pm4-eng}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EFS_SECURITY_GROUP_ID="${EFS_SECURITY_GROUP_ID:-sg-019a2068045d7a240}"
if [ -n "${PERF_SUFFIX}" ]; then
  NODEGROUP_NAME="perf-ci-${INSTANCE}-${PERF_SUFFIX}"
else
  NODEGROUP_NAME="perf-ci-${INSTANCE}"
fi

if ! aws eks describe-nodegroup \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${AWS_REGION}" &>/dev/null; then
  echo "Node group ${NODEGROUP_NAME} does not exist; nothing to delete."
  exit 0
fi

# Revoke NFS from perf node group in EFS SG before instances are gone
NODE_SGS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:nodegroup-name,Values=${NODEGROUP_NAME}" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u)
if [ -n "${NODE_SGS}" ]; then
  for sg in ${NODE_SGS}; do
    if [ "${sg}" = "${EFS_SECURITY_GROUP_ID}" ]; then
      continue
    fi
    echo "Revoking inbound rule from ${EFS_SECURITY_GROUP_ID}: TCP 2049 from ${sg}"
    aws ec2 revoke-security-group-ingress --region "${AWS_REGION}" \
      --group-id "${EFS_SECURITY_GROUP_ID}" \
      --protocol tcp --port 2049 \
      --source-group "${sg}" 2>/dev/null || true
  done
fi

echo "Deleting node group: ${NODEGROUP_NAME}"
aws eks delete-nodegroup \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${AWS_REGION}"

echo "Waiting for node group ${NODEGROUP_NAME} to be deleted..."
aws eks wait nodegroup-deleted \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${AWS_REGION}" || true
echo "Node group ${NODEGROUP_NAME} deleted."
