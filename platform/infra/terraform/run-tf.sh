#!/bin/bash

# checking environment variables

if [ -z "${TF_VAR_aws_region}" ]; then
    message="env variable AWS_REGION not set, defaulting to us-west-2"
    echo $message
    export TF_VAR_aws_region="us-west-2"
fi

curr_dir=${PWD}

# Default cluster names set. To override, set them as environment variables.
export TF_VAR_dev_cluster_name="appmod-dev"
export TF_VAR_prod_cluster_name="appmod-prod"

echo "Following environment variables will be used:"
echo "CLUSTER_REGION = "$TF_VAR_aws_region
echo "DEV_CLUSTER_NAME = "$TF_VAR_dev_cluster_name
echo "PROD_CLUSTER_NAME = "$TF_VAR_prod_cluster_name

rm -rf terraform-aws-observability-accelerator/
git clone https://github.com/aws-observability/terraform-aws-observability-accelerator.git
cp -r terraform-aws-observability-accelerator/examples/managed-grafana-workspace bootstrap/

# bootstrapping TF S3 bucket and DynamoDB locally
echo "bootstrapping Terraform"
terraform -chdir=bootstrap init -reconfigure
terraform -chdir=bootstrap plan
terraform -chdir=bootstrap apply -auto-approve

export TF_VAR_state_s3_bucket=$(terraform -chdir=bootstrap  output -raw eks-accelerator-bootstrap-state-bucket)
export TF_VAR_state_ddb_lock_table=$(terraform -chdir=bootstrap output -raw eks-accelerator-bootstrap-ddb-lock-table)
export TF_VAR_managed_grafana_workspace_id=$(terraform -chdir=bootstrap output -raw amg_workspace_id)

# Bootstrap EKS Cluster using S3 bucket and DynamoDB
echo "Following bucket and dynamodb table will be used to store states for dev and PROD Cluster:"
echo "S3_BUCKET = "$TF_VAR_state_s3_bucket
echo "DYNAMO_DB_lOCK_TABLE = "$TF_VAR_state_ddb_lock_table

# Create API key for Managed Grafana and export the key. Manually delete the key if re-running
export AMG_API_KEY=$(aws grafana create-workspace-api-key \
  --key-name "grafana-operator-${RANDOM}" \
  --key-role "ADMIN" \
  --seconds-to-live 432000 \
  --workspace-id $TF_VAR_managed_grafana_workspace_id \
  --query key \
  --output text)

echo "Following Managed Grafana Workspace used for Observability accelerator:"
echo "Managed Grafana Workspace ID = "$TF_VAR_managed_grafana_workspace_id

# Initialize backend for DEV cluster
terraform -chdir=dev init -reconfigure -backend-config="key=dev/eks-accelerator-vpc.tfstate" \
-backend-config="bucket=$TF_VAR_state_s3_bucket" \
-backend-config="region=$TF_VAR_aws_region" \
-backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

# Apply the infrastructure changes to deploy EKS DEV cluster
terraform -chdir=dev apply -var aws_region="${TF_VAR_aws_region}" \
-var managed_grafana_workspace_id="${TF_VAR_managed_grafana_workspace_id}" \
-var cluster_name="${TF_VAR_dev_cluster_name}" \
-var grafana_api_key="${AMG_API_KEY}" -auto-approve

# Update kubeconfig with DEV cluster credentials for external secrets
aws eks update-kubeconfig --name $TF_VAR_dev_cluster_name --region $TF_VAR_aws_region

# Apply the EKS Observability Accelerator in DEV
terraform -chdir=dev apply -var aws_region="${TF_VAR_aws_region}" \
-var managed_grafana_workspace_id="${TF_VAR_managed_grafana_workspace_id}" \
-var cluster_name="${TF_VAR_dev_cluster_name}" \
-var grafana_api_key="${AMG_API_KEY}" -auto-approve

export TF_VAR_managed_prometheus_workspace_id=$(terraform -chdir=dev output -raw amp_workspace_id)
echo "Following Managed Prometheus Workspace will be for Observability accelerator in PROD:"
echo "Amazon Managed Prometheus Workspace ID = "$TF_VAR_managed_prometheus_workspace_id

# Initialize backend for PROD cluster
terraform -chdir=prod init -reconfigure -backend-config="key=prod/eks-accelerator-vpc.tfstate" \
-backend-config="bucket=$TF_VAR_state_s3_bucket" \
-backend-config="region=$TF_VAR_aws_region" \
-backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

# Apply the infrastructure changes to deploy EKS PROD cluster
terraform -chdir=prod apply -var aws_region="${TF_VAR_aws_region}" \
-var managed_grafana_workspace_id="${TF_VAR_managed_grafana_workspace_id}" \
-var managed_prometheus_workspace_id="${TF_VAR_managed_prometheus_workspace_id}" \
-var cluster_name="${TF_VAR_prod_cluster_name}" \
-var grafana_api_key="${AMG_API_KEY}" -auto-approve

# Update kubeconfig with PROD cluster credentials for external secrets
aws eks update-kubeconfig --name $TF_VAR_prod_cluster_name --region $TF_VAR_aws_region

# Apply the EKS Observability Accelerator in PROD
terraform -chdir=prod apply -var aws_region="${TF_VAR_aws_region}" \
-var managed_grafana_workspace_id="${TF_VAR_managed_grafana_workspace_id}" \
-var managed_prometheus_workspace_id="${TF_VAR_managed_prometheus_workspace_id}" \
-var cluster_name="${TF_VAR_prod_cluster_name}" \
-var grafana_api_key="${AMG_API_KEY}" -auto-approve

echo "Execution Completed"