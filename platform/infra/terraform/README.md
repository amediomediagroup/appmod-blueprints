# Terraform Setup

## Prerequisites

- AWS CLI 2.17+ (Needed for EKS Access Config)
- Terraform CLI
- kubectl

## Workshop Setup

To setup the environment goto the following path and run the script. The script works only from the root directory.

```bash
cd /appmod-blueprints/platform/infra/terraform
./setup-environments.sh

```

The script `setup-environments.sh` does the following:

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

## Testing Workshop Setup

To setup the environment when testing locally, go to the following path and run the script

```bash
cd /appmod-blueprints/platform/infra/terraform
./setup-environments-local.sh
```

### Setup Environments Local Script

The script `setup-environments-local.sh` does the following

- Creates an IAM user named `modern-engg-local-test`
- Creates an IAM role named `developer-env-VSCodeInstanceRole`
- Allows codebuild, ec2, codecommit, ssm, and the new IAM user to assume the role
- Attaches the `AdministratorAccess` policy, a cdk assume policy, and a codewhisperer policy
- Logs into the `modern-engg-local-test` user, then assumes the `developer-env-VSCodeInstanceRole` to give enough assumed time to run the full script
- Runs the `setup-environments.sh` script as the `developer-env-VSCodeInstanceRole`

### Cluster Access

To access the clusters created by the setup script, you will need to run this bash code to assume the `developer-env-VSCodeInstanceRole`.  This will allow you to assume the role for 1 hour.

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="developer-env-VSCodeInstanceRole"
SESSION_NAME="workshop"

ASSUME_ROLE_OUTPUT=$(aws sts assume-role --role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME --role-session-name $SESSION_NAME)
export AWS_ACCESS_KEY_ID=$(echo $ASSUME_ROLE_OUTPUT | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $ASSUME_ROLE_OUTPUT | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $ASSUME_ROLE_OUTPUT | jq -r '.Credentials.SessionToken')
```

# Setup Application

To deploy sample app, refer to prod-public-apps.yaml to deploy applications. Ensure the destination is mapped to the correct target cluster (dev-cluster or prod-cluster).

Ensure the target cluster is mapped to the local management cluster and only the target cluster (Dev or Prod) is updated on the actual applications that will have the running applications. For Examples,refer to argo-examples folders to deploy applications or app-of-apps from public repo or integrated Gitea.

# Terraform Destroy

```bash
cd /appmod-blueprints/platform/infra/terraform
./destroy-environments.sh

```

Execute the destroy-environments.sh to destroy all the components except the bootstrap components. This is to ensure the buckets and the lock table are not destroyed in case of any issues during deletion,so it can be re-run again. Once the script is ran successfully execute the terraform command below to remove the bootstrap components.

```bash
cd /appmod-blueprints/platform/infra/terraform
terraform -chdir=bootstrap destroy -auto-approve

```

The bucket is intentionally not cleaned or removed to preserve the state files.
There will be error at the end of the script that S3 bucket deletion failed due to objects in the bucket. You can manually remove the terraform state files and destroy the bucket.

