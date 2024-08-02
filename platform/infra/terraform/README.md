# Terraform Setup

## Prerequisites

- AWS CLI
- Terraform CLI
- kubectl

The script create-tf.sh creates 2 EKS clusters (Dev and Prod) with Observability. This also creates an Amazon Grafana which gets the information from Amazon Managed Prometheus workspace shared across both the clusters.

Set Cluster and region using environment variables. Example below:
export TF_VAR_cluster_name=dev-platform
export TF_VAR_aws_region=us-west-2

Note: Setup takes up to 1-2 hours to complete. Ensure IAM role/token do not time out during the changes. If timed out,please re-run the script.

Note: There may be some Flux warning/errors at the end due to API changes and can be safely ignored as they will not impact any features.

# Create Secret manually to connect to target cluster

Refer to the argo-examples/sample-cluster-connect.yaml and create the argo secret to connect to the target cluster from the management cluster.

Update the name and server url of the cluster, which can be obtained from the SSM parameter store references on the Terraform setup. The bearer token and base64 encoded CA is also available on the SSM parameter store. For Example for DEV cluster the SSM parameters are below:

- /gitops/dev-argocdca
- /gitops/dev-argocd-token
- /gitops/dev-serverurl

If you prefer to use Terraform to connect to target cluster refer to dev-argo-connect.tf to connect to the target cluster which is outside of management cluster. This leverages SSM parameter store to retrieve the cluster details like tokens that were already created during setup. 

# Setup Application

To deploy sample app, refer to prod-public-apps.yaml to deploy applications. Ensure the destination is mapped to the correct target cluster.

Ensure the target cluster is mapped to the local management cluster and only the target cluster (Dev or Prod) is updated on the actual applications that will have the running applications.

# Terraform Destroy

Execute the destroy-tf.sh to destroy all the components. The bucket is intentionally not cleaned or removed to preserve the state files.