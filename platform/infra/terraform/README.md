# Terraform Setup

## Prerequisites

- AWS CLI 2.17+ (Needed for EKS Access Config)
- Terraform CLI
- kubectl

## Workshop Setup

To setup the environment go to the following path and run the script. The script works only from the root directory.

```bash
cd /appmod-blueprints/platform/infra/terraform
./setup-workshop.sh
```

## Local Setup

To setup the environment when testing locally, go to the following path and run the script

```bash
cd /appmod-blueprints/platform/infra/terraform
./setup-workshop-local.sh
```

### Setup Workshop Local Script

The script `setup-workshop-local.sh` does the following

- Creates an IAM user named `modern-engg-local-test`
- Creates an IAM role named `developer-env-VSCodeInstanceRole`
- Allows codebuild, ec2, codecommit, ssm, and the new IAM user to assume the role
- Attaches the `AdministratorAccess` policy, a cdk assume policy, and a codewhisperer policy
- Logs into the `modern-engg-local-test` user, then assumes the `developer-env-VSCodeInstanceRole`
- Runs the `setup-workshop.sh` script in the `developer-env-VSCodeInstanceRole`

### Setup Workshop Script

The script `setup-workshop.sh` does the following:

- Create the EKS management cluster where IDP Builder will be deployed
- Installs ArgoCD, Ingress-Nginx and its pre-requisites.
- Deploys core tools needed on ArgoCD like Gitea, Backstage, Argo Workflows etc.,
- Deploys the DEV and PROD EKS clusters with all tools including observability and integration with Amazon Managed Grafana.
- Automatically add the DEV and PROD clusters to the ArgoCD integration.
- Setup Codebuild project which can be integrated with backstage.
- Other components that are deployed in all 3 clusters include crossplane, KubeVela.

Set Cluster and region using environment variables. Example below:
export TF_VAR_cluster_name=dev-platform
export TF_VAR_aws_region=us-west-2

Note: Setup takes up to 1-2 hours to complete. Ensure IAM role/token do not time out during the changes. If timed out,please re-run the script.

Outputs will provide the details of URLs that are needed to access the core services including Amazon Managed Grafana.

# Setup Application

To deploy sample app, refer to prod-public-apps.yaml to deploy applications. Ensure the destination is mapped to the correct target cluster (dev-cluster or prod-cluster).

Ensure the target cluster is mapped to the local management cluster and only the target cluster (Dev or Prod) is updated on the actual applications that will have the running applications. For Examples,refer to argo-examples folders to deploy applications or app-of-apps from public repo or integrated Gitea.

# Terraform Destroy

```bash
cd /appmod-blueprints/platform/infra/terraform
./destroy-workshop.sh

```

Execute the destroy-workshop.sh to destroy all the components except the bootstrap components. This is to ensure the buckets and the lock table are not destroyed in case of any issues during deletion,so it can be re-run again. Once the script is ran successfully execute the terraform command below to remove the bootstrap components.

```bash
cd /appmod-blueprints/platform/infra/terraform
terraform -chdir=bootstrap destroy -auto-approve

```

The bucket is intentionally not cleaned or removed to preserve the state files.
There will be error at the end of the script that S3 bucket deletion failed due to objects in the bucket. You can manually remove the terraform state files and destroy the bucket.
