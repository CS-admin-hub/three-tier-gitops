#!/bin/bash
# scripts/05-post-cluster-setup.sh
set -e
echo "=== Post Cluster Setup ==="

export CLUSTER_NAME=three-tier-cluster
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get OIDC URL
OIDC_URL=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')
echo "OIDC URL: ${OIDC_URL}"

# --- Tag subnets ---
echo ">>> Tagging subnets for Karpenter..."
for SUBNET in $(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text); do
  aws ec2 create-tags --resources ${SUBNET} \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
  echo "  Tagged subnet: ${SUBNET}"
done

# --- Tag security groups ---
echo ">>> Tagging security groups for Karpenter..."
for SG in $(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text); do
  aws ec2 create-tags --resources ${SG} \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
  echo "  Tagged SG: ${SG}"
done

# --- Replace placeholders in trust policies ---
echo ">>> Preparing trust policies..."
sed "s|851725602228|${AWS_ACCOUNT_ID}|g; s|<OIDC_URL>|${OIDC_URL}|g" \
  iam/backend-trust-policy.json > /tmp/backend-trust.json
sed "s|851725602228|${AWS_ACCOUNT_ID}|g; s|<OIDC_URL>|${OIDC_URL}|g" \
  iam/external-secrets-trust-policy.json > /tmp/ext-secrets-trust.json
sed "s|851725602228|${AWS_ACCOUNT_ID}|g; s|<OIDC_URL>|${OIDC_URL}|g" \
  iam/fluentbit-trust-policy.json > /tmp/fluentbit-trust.json
sed "s|851725602228|${AWS_ACCOUNT_ID}|g; s|<OIDC_URL>|${OIDC_URL}|g" \
  iam/velero-trust-policy.json > /tmp/velero-trust.json

# Helper function - create role only if it doesn't exist
create_role_if_not_exists() {
  local ROLE_NAME=$1
  local TRUST_FILE=$2
  if aws iam get-role --role-name ${ROLE_NAME} 2>/stage/null; then
    echo "  Role ${ROLE_NAME} already exists - skipping create"
  else
    aws iam create-role --role-name ${ROLE_NAME} \
      --assume-role-policy-document file://${TRUST_FILE}
    echo "  Created: ${ROLE_NAME}"
  fi
}

echo ">>> Creating IRSA roles..."

# Backend IRSA Role
create_role_if_not_exists BackendIRSARole /tmp/backend-trust.json
aws iam attach-role-policy --role-name BackendIRSARole \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
echo "  Attached policy to: BackendIRSARole"

# External Secrets IRSA Role - FIXED policy name
create_role_if_not_exists ExternalSecretsRole /tmp/ext-secrets-trust.json
aws iam attach-role-policy --role-name ExternalSecretsRole \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
echo "  Attached policy to: ExternalSecretsRole"

# FluentBit IRSA Role
create_role_if_not_exists FluentBitRole /tmp/fluentbit-trust.json
aws iam attach-role-policy --role-name FluentBitRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
echo "  Attached policy to: FluentBitRole"

# Velero IRSA Role
create_role_if_not_exists VeleroRole /tmp/velero-trust.json
aws iam attach-role-policy --role-name VeleroRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
echo "  Attached policy to: VeleroRole"

# --- Create gp3 StorageClass ---
echo ">>> Creating gp3 StorageClass..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

echo ""
echo "=== Post Cluster Setup Complete ==="
kubectl get storageclass
echo ""
echo ">>> Next: Run 06-install-controllers.sh"
