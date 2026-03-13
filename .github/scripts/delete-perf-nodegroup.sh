#!/usr/bin/env bash
# Delete the dedicated EKS node group for performance tests.
# Usage: INSTANCE=<10-char-id> [EKS_CLUSTER_NAME=pm4-eng] [AWS_REGION=us-east-1] ./delete-perf-nodegroup.sh
# Idempotent: no-op if node group does not exist.
set -euo pipefail

INSTANCE="${INSTANCE:?INSTANCE is required (10-char instance id)}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-pm4-eng}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NODEGROUP_NAME="perf-ci-${INSTANCE}"

if ! aws eks describe-nodegroup \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${AWS_REGION}" &>/dev/null; then
  echo "Node group ${NODEGROUP_NAME} does not exist; nothing to delete."
  exit 0
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
