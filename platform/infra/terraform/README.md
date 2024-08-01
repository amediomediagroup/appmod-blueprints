# Terraform Setup

## Prerequisites

- AWS CLI
- Terraform CLI
- kubectl

The script create-tf.sh creates 2 EKS clusters (Dev and Prod) with Observability. This also creates an Amazon Grafana which gets the information from Amazon Managed Prometheus workspace shared across both the clusters.

Set Cluster and region using environment variables. Example below:
export TF_VAR_cluster_name=dev-platform
export TF_VAR_aws_region=us-west-2

Note: Setup takes up to 1-2 hours to complete. Ensure IAM role/token do not time out during the changes. If so re-run the script.

# Terraform Destroy

Execute the destroy-tf.sh to destroy all the components. The bucket is intentionally not cleaned or removed to preserve the state files.

# Setup Application

Refer to dev-argo-connect.tf to connect to the target cluster which is outside of management cluster. This leverages SSM parameter store to retrieve the cluster details like tokens that were already created during setup. 

To deploy sample app, refer to prod-public-apps.yaml to deploy applications. Ensure the destination is mapped to the correct target cluster.

Ensure the target cluster is mapped to the local management cluster and only the target cluster (Dev or Prod) is updated on the actual applications that will have the running applications.
