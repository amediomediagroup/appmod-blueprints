#!/bin/bash
#
# Copyright 2024 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

#title           create-workshop.sh
#description     This script sets up terraform EKS clusters and prerequisites
#version         1.0
#==============================================================================
set -e -o pipefail

# checking environment variables

if [ -z "${TF_VAR_aws_region}" ]; then
  message="env variable AWS_REGION not set, defaulting to us-west-2"
  echo $message
  export TF_VAR_aws_region="us-west-2"
fi

export REPO_ROOT=$(git rev-parse --show-toplevel)
source ${REPO_ROOT}/platform/infra/terraform/setup-keycloak.sh

# Deploy the base cluster with prerequisites like ArgoCD and Ingress-nginx
${REPO_ROOT}/platform/infra/terraform/mgmt/terraform/mgmt-cluster/install.sh

# Set the DNS_HOSTNAME to be checked
export DNS_HOSTNAME=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Replace dns with the value of DNS_HOSTNAME
sed -e "s/INGRESS_DNS/${DNS_HOSTNAME}/g" ${REPO_ROOT}/platform/infra/terraform/mgmt/setups/default-config.yaml >${REPO_ROOT}/platform/infra/terraform/mgmt/setups/config.yaml

# Deploy the apps on IDP Builder and ArgoCD
${REPO_ROOT}/platform/infra/terraform/mgmt/setups/install.sh

cd ${REPO_ROOT}/platform/infra/terraform/mgmt/terraform/mgmt-cluster/
export TF_eks_cluster_vpc_id=$(terraform output -raw eks_cluster_vpc_id)
export TF_eks_cluster_private_subnets=$(terraform output -json eks_cluster_private_subnets)

export KEYCLOAK_NAMESPACE=keycloak
export KEYCLOAK_REALM=grafana
export KEYCLOAK_USER_ADMIN_PASSWORD=$(openssl rand -base64 8)
export KEYCLOAK_USER_EDITOR_PASSWORD=$(openssl rand -base64 8)

# Default cluster names set. To override, set them as environment variables.
export TF_VAR_mgmt_cluster_name="modern-engineering"
export TF_VAR_dev_cluster_name="modernengg-dev"
export TF_VAR_prod_cluster_name="modernengg-prod"

# SAML IDP Metadata url for keycloak
export TF_VAR_grafana_keycloak_idp_url="http://${DNS_HOSTNAME}/keycloak/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor"

echo "Following environment variables will be used:"
echo "CLUSTER_REGION = "$TF_VAR_aws_region
echo "DEV_CLUSTER_NAME = "$TF_VAR_dev_cluster_name
echo "PROD_CLUSTER_NAME = "$TF_VAR_prod_cluster_name
echo "VPC_ID = "$TF_eks_cluster_vpc_id
echo "VPC_Private_Subnets = "$TF_eks_cluster_private_subnets
echo "Grafana Keycloak IDP metadata URL = "$TF_VAR_grafana_keycloak_idp_url

# bootstrapping TF S3 bucket and DynamoDB locally
cd "${REPO_ROOT}/platform/infra/terraform/"

rm -rf terraform-aws-observability-accelerator/
git clone https://github.com/aws-observability/terraform-aws-observability-accelerator.git

echo "bootstrapping Terraform"
terraform -chdir=bootstrap init -reconfigure
terraform -chdir=bootstrap plan
terraform -chdir=bootstrap apply -auto-approve

export TF_VAR_state_s3_bucket=$(terraform -chdir=bootstrap output -raw eks-accelerator-bootstrap-state-bucket)
export TF_VAR_state_ddb_lock_table=$(terraform -chdir=bootstrap output -raw eks-accelerator-bootstrap-ddb-lock-table)
export TF_VAR_managed_prometheus_workspace_id=$(terraform -chdir=bootstrap output -raw amp_workspace_id)
export TF_VAR_managed_grafana_workspace_id=$(terraform -chdir=bootstrap output -raw amg_workspace_id)
export TF_VAR_grafana_workspace_endpoint=$(terraform -chdir=bootstrap output -raw grafana_workspace_endpoint)

export WORKSPACE_ENDPOINT=$TF_VAR_grafana_workspace_endpoint
export KEYCLOAK_NAMESPACE=keycloak
export KEYCLOAK_REALM=grafana
export WORKSPACE_ID=$TF_VAR_managed_grafana_workspace_id
export KEYCLOAK_USER_ADMIN_PASSWORD=$(openssl rand -base64 8)
export KEYCLOAK_USER_EDITOR_PASSWORD=$(openssl rand -base64 8)

# Export the Keycloak admin password for the workspace from the Management Cluster Keycloak
export KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secret keycloak-config -n keycloak --template={{.data.KEYCLOAK_ADMIN_PASSWORD}} | base64 -d)
export AWS_REGION=$TF_VAR_aws_region

# Configure Keycloak Realm for Grafana Workspace
configure_keycloak

# Update SAML Auth for Grafana Workspace
update_workspace_saml_auth || true

cd "${REPO_ROOT}/platform/infra/terraform/"

# Bootstrap EKS Cluster using S3 bucket and DynamoDB
echo "Following bucket and dynamodb table will be used to store states for dev and PROD Cluster:"
echo "S3_BUCKET = "$TF_VAR_state_s3_bucket
echo "DYNAMO_DB_lOCK_TABLE = "$TF_VAR_state_ddb_lock_table

# Create API key for Managed Grafana and export the key.
export AMG_API_KEY=$(aws grafana create-workspace-api-key \
  --key-name "grafana-operator-${RANDOM}" \
  --key-role "ADMIN" \
  --seconds-to-live 432000 \
  --workspace-id $TF_VAR_managed_grafana_workspace_id \
  --query key \
  --output text)

echo "Following Managed Grafana Workspace used for Observability accelerator for both DEV and PROD:"
echo "Managed Grafana Workspace ID = "$TF_VAR_managed_grafana_workspace_id

echo "Following Amazon Managed Prometheus Workspace will be used for Observability accelerator for both DEV and PROD:"
echo "Managed Prometheus Workspace ID = "$TF_VAR_managed_prometheus_workspace_id

# Initialize backend for DEV cluster
terraform -chdir=dev init -reconfigure -backend-config="key=dev/eks-accelerator-vpc.tfstate" \
  -backend-config="bucket=$TF_VAR_state_s3_bucket" \
  -backend-config="region=$TF_VAR_aws_region" \
  -backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

# Apply the infrastructure changes to deploy EKS DEV cluster and install EKS observability Accelerator
terraform -chdir=dev apply -var aws_region="${TF_VAR_aws_region}" \
  -var managed_grafana_workspace_id="${TF_VAR_managed_grafana_workspace_id}" \
  -var managed_prometheus_workspace_id="${TF_VAR_managed_prometheus_workspace_id}" \
  -var cluster_name="${TF_VAR_dev_cluster_name}" \
  -var vpc_id="${TF_eks_cluster_vpc_id}" \
  -var vpc_private_subnets="${TF_eks_cluster_private_subnets}" \
  -var grafana_api_key="${AMG_API_KEY}" -auto-approve

# Change IAM Access Configs for DEV Cluster
aws eks --region $TF_VAR_aws_region update-kubeconfig --name $TF_VAR_dev_cluster_name
export DEV_ACCESS_CONF=$(aws eks describe-cluster --region $TF_VAR_aws_region --name $TF_VAR_dev_cluster_name --query 'cluster.accessConfig' --output text)

if [[ "$DEV_ACCESS_CONF" != "API_AND_CONFIG_MAP" ]]; then
  echo "Changing IAM access configs for DEV cluster: $DEV_ACCESS_CONF"
  aws eks update-cluster-config --region $TF_VAR_aws_region --name ${TF_VAR_dev_cluster_name} --access-config authenticationMode=API_AND_CONFIG_MAP
fi

# Initialize backend for PROD cluster
terraform -chdir=prod init -reconfigure -backend-config="key=prod/eks-accelerator-vpc.tfstate" \
  -backend-config="bucket=$TF_VAR_state_s3_bucket" \
  -backend-config="region=$TF_VAR_aws_region" \
  -backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

# Apply the infrastructure changes to deploy EKS PROD cluster and deploy observability accelerator
terraform -chdir=prod apply -var aws_region="${TF_VAR_aws_region}" \
  -var managed_grafana_workspace_id="${TF_VAR_managed_grafana_workspace_id}" \
  -var managed_prometheus_workspace_id="${TF_VAR_managed_prometheus_workspace_id}" \
  -var cluster_name="${TF_VAR_prod_cluster_name}" \
  -var vpc_id="${TF_eks_cluster_vpc_id}" \
  -var vpc_private_subnets="${TF_eks_cluster_private_subnets}" \
  -var grafana_api_key="${AMG_API_KEY}" -auto-approve

# Change IAM Access Configs for PROD Cluster
aws eks --region $TF_VAR_aws_region update-kubeconfig --name $TF_VAR_prod_cluster_name
export PROD_ACCESS_CONF=$(aws eks describe-cluster --region $TF_VAR_aws_region --name $TF_VAR_prod_cluster_name --query 'cluster.accessConfig' --output text)
if [[ "$PROD_ACCESS_CONF" != "API_AND_CONFIG_MAP" ]]; then
  echo "Changing IAM access configs for PROD cluster: $PROD_ACCESS_CONF"
  aws eks update-cluster-config --region $TF_VAR_aws_region --name $TF_VAR_prod_cluster_name --access-config authenticationMode=API_AND_CONFIG_MAP
fi

echo "Sleeping for 5 minutes to allow cluster to change auth mode"
sleep 300

# Reconnect back to Management Cluster
aws eks --region $TF_VAR_aws_region update-kubeconfig --name $TF_VAR_mgmt_cluster_name

# Setup Applications on Clusters using ArgoCD on the management cluster
# Setup Kubevela on Management,Dev and Prod clusters
kubectl apply -f ${REPO_ROOT}/platform/infra/terraform/argocd-apps/

# Connect ArgoCD on MGMT cluster to DEV and PROD target clusters
terraform -chdir=post-deploy init -reconfigure -backend-config="key=post/argocd-connect-vpc.tfstate" \
  -backend-config="bucket=$TF_VAR_state_s3_bucket" \
  -backend-config="region=$TF_VAR_aws_region" \
  -backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

export TF_VAR_GITEA_URL="https://${DNS_HOSTNAME}/gitea"

# Apply the changes for ArgoConnect and Codebuild project for clusters
terraform -chdir=post-deploy apply -var aws_region="${TF_VAR_aws_region}" \
  -var mgmt_cluster_gitea_url="${TF_VAR_GITEA_URL}" \
  -var dev_cluster_name="${TF_VAR_dev_cluster_name}" \
  -var prod_cluster_name="${TF_VAR_prod_cluster_name}" -auto-approve

# Setup Gitea Repo
${REPO_ROOT}/platform/infra/terraform/giteaInit.sh

echo "Terraform execution completed"

# Cleanup Folders
rm -rf terraform-aws-observability-accelerator/

echo "ArgoCD URL is: https://$DNS_HOSTNAME/argocd"

echo "GITEA URL is: https://$DNS_HOSTNAME/gitea"

echo "Keycloak URL is: https://$DNS_HOSTNAME/keycloak"

echo "Backstage URL is: https://$DNS_HOSTNAME/"

echo "ArgoWorkflows URL is: https://$DNS_HOSTNAME/argo-workflows"

echo "-------------------"
echo "Workspace endpoint: https://$WORKSPACE_ENDPOINT/"
echo "-------------------"
echo "Admin credentials"
echo "-------------------"
echo "username: admin"
echo "password: $KEYCLOAK_USER_ADMIN_PASSWORD"
echo ""
echo "-------------------"
echo "Editor credentials"
echo "-------------------"
echo "username: editor"
echo "password: $KEYCLOAK_USER_EDITOR_PASSWORD"
echo ""
echo "Setup done."

echo "Script Complete"

