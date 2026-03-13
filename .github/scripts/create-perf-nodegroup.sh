#!/usr/bin/env bash
# Create a dedicated EKS node group for performance tests.
# Usage: INSTANCE=<10-char-id> [EKS_CLUSTER_NAME=pm4-eng] [AWS_REGION=us-east-1] ./create-perf-nodegroup.sh
# Requires: aws CLI, credentials with eks:CreateNodegroup and eks:DescribeCluster, eks:ListNodegroups, eks:DescribeNodegroup
set -euo pipefail

INSTANCE="${INSTANCE:?INSTANCE is required (10-char instance id)}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-pm4-eng}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NODEGROUP_NAME="perf-ci-${INSTANCE}"
TAINT_KEY="performance"
TAINT_VALUE="ci-${INSTANCE}"
INSTANCE_TYPE="${INSTANCE_TYPE:-r6a.xlarge}"

echo "Creating performance node group: ${NODEGROUP_NAME} (cluster=${EKS_CLUSTER_NAME}, region=${AWS_REGION})"

# Get subnets from cluster
SUBNETS=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ' ')
if [ -z "${SUBNETS}" ]; then
  echo "ERROR: Could not get subnets from cluster ${EKS_CLUSTER_NAME}"
  exit 1
fi
echo "Using subnets: ${SUBNETS}"

# Get node role from an existing nodegroup (same role for worker nodes)
FIRST_NODEGROUP=$(aws eks list-nodegroups --cluster-name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'nodegroups[0]' --output text)
if [ -z "${FIRST_NODEGROUP}" ] || [ "${FIRST_NODEGROUP}" = "None" ]; then
  echo "ERROR: No existing node group in cluster ${EKS_CLUSTER_NAME} to copy node role from"
  exit 1
fi
NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "${EKS_CLUSTER_NAME}" --nodegroup-name "${FIRST_NODEGROUP}" \
  --region "${AWS_REGION}" --query 'nodegroup.nodeRole' --output text)
if [ -z "${NODE_ROLE}" ]; then
  echo "ERROR: Could not get node role from nodegroup ${FIRST_NODEGROUP}"
  exit 1
fi
echo "Using node role: ${NODE_ROLE}"

# Create node group with taint and matching label so pods with nodeSelector can schedule
# Taint: performance=ci-INSTANCE:NoSchedule
# Label: performance=ci-INSTANCE (for nodeSelector in helm values)
aws eks create-nodegroup \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --node-role "${NODE_ROLE}" \
  --subnets ${SUBNETS} \
  --scaling-config minSize=1,maxSize=1,desiredSize=1 \
  --instance-types "${INSTANCE_TYPE}" \
  --taints "key=${TAINT_KEY},value=${TAINT_VALUE},effect=NO_SCHEDULE" \
  --labels "performance=${TAINT_VALUE}" \
  --region "${AWS_REGION}"

echo "Node group ${NODEGROUP_NAME} creation started. Waiting for ACTIVE status..."
aws eks wait nodegroup-active \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${AWS_REGION}"
echo "Node group ${NODEGROUP_NAME} is ACTIVE."
