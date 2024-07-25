# Terraform Setup

The script run-tf.sh creates 2 EKS clusters with Observability accelerator and deploys ArgoCD on both the clusters. This also creates an Amazon Grafana which gets the information from Amazon Managed Prometheus.

Set Cluster and region using environment variables. Example below:
export TF_VAR_cluster_name=dev-platform
export TF_VAR_aws_region=us-west-2

Note: Setup takes up to 2 hours to complete. Ensure IAM role/token do not time out during the changes. If so re-run the script.
