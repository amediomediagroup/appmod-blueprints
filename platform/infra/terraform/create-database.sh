#!/bin/bash

# Initialize backend for DB DEV cluster
terraform -chdir=dev/db init -reconfigure -backend-config="key=dev/db/db-ec2-cluster.tfstate" \
  -backend-config="bucket=$TF_VAR_state_s3_bucket" \
  -backend-config="region=$TF_VAR_aws_region" \
  -backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

# Apply the infrastructure changes to deploy DB DEV cluster 
terraform -chdir=dev/db apply -var aws_region="${TF_VAR_aws_region}" \
  -var vpc_id="${TF_eks_cluster_vpc_id}" \
  -var vpc_private_subnets="${TF_eks_cluster_private_subnets}" \
  -var availability_zones="${TF_eks_cluster_private_az}" \
  -var vpc_cidr="${TF_eks_cluster_vpc_cidr}" \
  -var key_name="ws-default-keypair" -auto-approve


# Initialize backend for DB Prod cluster
terraform -chdir=prod/db init -reconfigure -backend-config="key=prod/db/db-ec2-cluster.tfstate" \
  -backend-config="bucket=$TF_VAR_state_s3_bucket" \
  -backend-config="region=$TF_VAR_aws_region" \
  -backend-config="dynamodb_table=$TF_VAR_state_ddb_lock_table"

# Apply the infrastructure changes to deploy DB DEV cluster 
terraform -chdir=prod/db apply -var aws_region="${TF_VAR_aws_region}" \
  -var vpc_id="${TF_eks_cluster_vpc_id}" \
  -var vpc_private_subnets="${TF_eks_cluster_private_subnets}" \
  -var availability_zones="${TF_eks_cluster_private_az}" \
  -var vpc_cidr="${TF_eks_cluster_vpc_cidr}" \
  -var key_name="ws-default-keypair" -auto-approve

echo "-------- Dev Cluster --------"
terraform -chdir=dev/db output

echo "-------- Prod Cluster --------"
terraform -chdir=prod/db output

echo "Terraform execution completed"

echo "Script Complete"
