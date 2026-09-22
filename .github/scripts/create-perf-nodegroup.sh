#!/usr/bin/env bash
# Create a dedicated EKS node group for performance tests.
# Usage: INSTANCE=<10-char-id> [EKS_CLUSTER_NAME=pm4-eng] [AWS_REGION=us-east-1] [EFS_SECURITY_GROUP_ID=sg-...] ./create-perf-nodegroup.sh
# Requires: aws CLI, credentials with eks:CreateNodegroup, eks:DescribeCluster, ec2:DescribeInstances, ec2:AuthorizeSecurityGroupIngress
set -euo pipefail

INSTANCE="${INSTANCE:?INSTANCE is required (10-char instance id)}"
# Optional: baseline | update — creates separate node groups for parallel perf tests.
PERF_SUFFIX="${PERF_SUFFIX:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-pm4-eng}"
AWS_REGION="${AWS_REGION:-us-east-1}"
# EFS mount target security group; must allow NFS (2049) from perf nodes so they can mount EFS.
EFS_SECURITY_GROUP_ID="${EFS_SECURITY_GROUP_ID:-sg-019a2068045d7a240}"

# Add inbound rule to EFS SG; exit 1 on failure unless error indicates rule already exists.
add_efs_ingress() {
  local protocol="$1"
  local port="$2"
  local source_sg="$3"
  local desc="$4"
  local err
  local rc
  set +e
  err=$(aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
    --group-id "${EFS_SECURITY_GROUP_ID}" \
    --protocol "${protocol}" --port "${port}" \
    --source-group "${source_sg}" 2>&1)
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "Added ${desc}: ${protocol} ${port} from ${source_sg}"
  else
    if echo "${err}" | grep -qi "Duplicate\|already exists"; then
      echo "Rule already exists for ${desc} (${protocol} ${port} from ${source_sg}); continuing."
    else
      echo "ERROR: Failed to add ${desc} to ${EFS_SECURITY_GROUP_ID}:" >&2
      echo "${err}" >&2
      exit 1
    fi
  fi
}

if [ -n "${PERF_SUFFIX}" ]; then
  NODEGROUP_NAME="perf-ci-${INSTANCE}-${PERF_SUFFIX}"
  TAINT_VALUE="ci-${INSTANCE}-${PERF_SUFFIX}"
else
  NODEGROUP_NAME="perf-ci-${INSTANCE}"
  TAINT_VALUE="ci-${INSTANCE}"
fi
TAINT_KEY="performance"
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

# Allow NFS (port 2049) from perf node group to EFS so pods can mount efs-sc volumes.
# Include pending instances so we get SGs as soon as nodes are launched (SGs are assigned at launch).
echo "Allowing NFS from perf node group into EFS security group ${EFS_SECURITY_GROUP_ID}..."
max_tries=24
for i in $(seq 1 "${max_tries}"); do
  NODE_SGS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:eks:nodegroup-name,Values=${NODEGROUP_NAME}" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u)
  if [ -n "${NODE_SGS}" ]; then
    echo "Found instance security group(s): ${NODE_SGS}"
    break
  fi
  echo "Waiting for instances in ${NODEGROUP_NAME} (attempt ${i}/${max_tries})..."
  sleep 10
done
if [ -z "${NODE_SGS}" ]; then
  echo "WARNING: No instances found in ${NODEGROUP_NAME}; skipping EFS SG rule. EFS mounts may fail."
  exit 0
fi

# Also allow from cluster security group (nodes may use it; ensures EFS is reachable).
CLUSTER_SG=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || true)
if [ -n "${CLUSTER_SG}" ] && [ "${CLUSTER_SG}" != "None" ]; then
  echo "Adding inbound rules to ${EFS_SECURITY_GROUP_ID}: NFS (TCP+UDP 2049) from cluster SG ${CLUSTER_SG}"
  add_efs_ingress tcp 2049 "${CLUSTER_SG}" "cluster SG (TCP)"
  add_efs_ingress udp 2049 "${CLUSTER_SG}" "cluster SG (UDP)"
fi

# Set EC2 Name tag so instances show as "Performance Tests - ci-{INSTANCE}" in the console
INSTANCE_IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:nodegroup-name,Values=${NODEGROUP_NAME}" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "${INSTANCE_IDS}" ]; then
  if [ -n "${PERF_SUFFIX}" ]; then
    NAME_TAG="Performance Tests - ci-${INSTANCE}-${PERF_SUFFIX}"
  else
    NAME_TAG="Performance Tests - ci-${INSTANCE}"
  fi
  echo "Tagging instances with Name=${NAME_TAG}"
  aws ec2 create-tags --region "${AWS_REGION}" --resources ${INSTANCE_IDS} --tags "Key=Name,Value=${NAME_TAG}"
fi

for sg in ${NODE_SGS}; do
  if [ "${sg}" = "${EFS_SECURITY_GROUP_ID}" ]; then
    continue
  fi
  echo "Adding inbound rules to ${EFS_SECURITY_GROUP_ID}: NFS (TCP+UDP 2049) from ${sg}"
  add_efs_ingress tcp 2049 "${sg}" "node SG (TCP)"
  add_efs_ingress udp 2049 "${sg}" "node SG (UDP)"
done
echo "EFS security group updated."
