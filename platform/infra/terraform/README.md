# Terraform Setup

## Prerequisites

- AWS CLI
- Terraform CLI
- kubectl

The script setup-workshop.sh does the following:

- Create the EKS management cluster where IDP Builder will be deployed
- Installs ArgoCD, Ingress-Nginx and its pre-requisites.
- Deploys core tools needed on ArgoCD like Gitea, backstage etc.,
- Deploys the DEV and PROD EKS clusters with all tools including observability and integration with Amazon Managed Grafana.
- Automatically add the DEV and PROD clusters to the ArgoCD integration.

Set Cluster and region using environment variables. Example below:
export TF_VAR_cluster_name=dev-platform
export TF_VAR_aws_region=us-west-2

Note: Setup takes up to 1-2 hours to complete. Ensure IAM role/token do not time out during the changes. If timed out,please re-run the script.

# Setup Application

To deploy sample app, refer to prod-public-apps.yaml to deploy applications. Ensure the destination is mapped to the correct target cluster (dev-cluster or prod-cluster).

Ensure the target cluster is mapped to the local management cluster and only the target cluster (Dev or Prod) is updated on the actual applications that will have the running applications.

# Terraform Destroy

Execute the destroy-workshop.sh to destroy all the components. The bucket is intentionally not cleaned or removed to preserve the state files.
There will be error at the end of the script that S3 bucket deletion failed due to objects in the bucket. You can manually remove the terraform state files and destroy the bucket.