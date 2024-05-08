# Backstage Crossplane Integrations

## 🏃‍♀️ Prerequisites

1. We might need a container engines such as `Docker Desktop`, `Podman` to run backstage crossplane integrations locally. Please check [this](https://github.com/cnoe-io/idpbuilder?tab=readme-ov-file#prerequisites) documentation to setup your container engine.

2. Download and install [idpbuilder](https://github.com/cnoe-io/idpbuilder?tab=readme-ov-file#download-and-install-the-idpbuilder) for running backstage crossplane integrations.

## 🌟 Implementation walkthrough

1. Use the below command to deploy Argo application for CrossPlane compositions/XRDs :

```bash
kubectl -f ../crossplane/crossplane-compositions.yaml
```

2. Naviate to `idpbuilder` repo and create an AWS Secret on required namespaces for deploying templates on AWS environment using below commands:

```bash
export IDP_AWS_ACCESS_KEY_ID_BASE64=$(echo -n ${YOUR_AWS_ACCESS_KEY_ID} | base64)
export IDP_AWS_SECRET_ACCESS_KEY_BASE64=$(echo -n ${YOUR_AWS_SECRET_ACCESS_KEY} | base64)
# AWS Credentials for argo Namespace
cat << EOF > ./aws-secrets.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: argo
type: Opaque
data:
  AWS_ACCESS_KEY_ID: ${IDP_AWS_ACCESS_KEY_ID_BASE64}
  AWS_SECRET_ACCESS_KEY: $IDP_AWS_SECRET_ACCESS_KEY_BASE64
EOF
kubectl apply -f ./aws-secrets.yaml

# AWS Credentials for data-on-eks Namespace
cat << EOF > ./aws-secrets-doeks.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: data-on-eks
type: Opaque
data:
  AWS_ACCESS_KEY_ID: ${IDP_AWS_ACCESS_KEY_ID_BASE64}
  AWS_SECRET_ACCESS_KEY: $IDP_AWS_SECRET_ACCESS_KEY_BASE64
EOF
kubectl apply -f ./aws-secrets-doeks.yaml

# AWS Credentials for tf-eks-observability Namespace
cat << EOF > ./aws-secrets-eobs.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: tf-eks-observability
type: Opaque
data:
  AWS_ACCESS_KEY_ID: ${IDP_AWS_ACCESS_KEY_ID_BASE64}
  AWS_SECRET_ACCESS_KEY: $IDP_AWS_SECRET_ACCESS_KEY_BASE64
EOF
kubectl apply -f ./aws-secrets-eobs.yaml
```

6. Next, in the `idpbuilder` folder, navigate to `./examples/ref-implementation/backstage/manifests/install.yaml` and add the following lines for catalog location at line 171 in backstage config to deploy crossplane backstage templates to backstage:

```yaml
        - type: url
          target: https://github.com/aws-samples/appmod-blueprints/blob/main/platform/backstage/templates/catalog-info.yaml
          rules:
            - allow: [User, Group]
```

7. Finally, run the following `idpbuilder` command to build and run the crossplane backstage integrations:

```bash
idpbuilder create \
  --use-path-routing \
  --package-dir examples/ref-implementation
```