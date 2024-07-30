# Backstage Crossplane Integrations

## 🏃‍♀️ Prerequisites

1. We might need a container engines such as `Docker Desktop`, `Podman` to run backstage crossplane integrations locally. Please check [this](https://github.com/cnoe-io/idpbuilder?tab=readme-ov-file#prerequisites) documentation to setup your container engine.

2. Download and install [idpbuilder](https://github.com/cnoe-io/idpbuilder?tab=readme-ov-file#download-and-install-the-idpbuilder) for running backstage crossplane integrations.

## 🌟 Implementation walkthrough

1. `idpBuilder` is extensible to launch custom Crossplane patterns using package extensions. 

Please use the below command to deploy an IDP reference implementation with an Argo application for preparing up the setup for terraform integrations:

```bash
idpbuilder create \
  --use-path-routing \
  --package-dir https://github.com/cnoe-io/stacks//ref-implementation \
  --package-dir https://github.com/cnoe-io/stacks//crossplane-integrations
```
## What is installed?

- Crossplane Runtime
- AWS providers
- Basic Compositions

2. Clone the [cnoe-io/stacks](https://github.com/cnoe-io/stacks) repository
3. Update [the credentials secret file](crossplane-providers/provider-secret.yaml)
4. Run the below command to create the crossplane provider secrets:

```bash
idpbuilder create \
  --use-path-routing \
  --package-dir https://github.com/cnoe-io/stacks//ref-implementation \
  --package-dir [path-to-stacks-repo]/crossplane-integrations
```

5. Postgres credentials for RDS Database

```bash
cat << EOF > ./postgres-secret.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-root-user-password
  namespace: crossplane-system
data:
  password: bXlzZWNyZXRQYXNzd29yZDEh # mysecretPassword1!
EOF
kubectl apply -f ./postgres-secret.yaml
```

6. Next, in the `idpbuilder` folder, navigate to `./ref-implementation/backstage/manifests/install.yaml` and add the following lines for catalog location at line 171 in backstage config to deploy crossplane backstage templates to backstage:

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
  --package-dir https://github.com/cnoe-io/stacks//ref-implementation \
  --package-dir [path-to-stacks-repo]/crossplane-integrations
```