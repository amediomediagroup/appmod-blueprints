# kind-crossplane-azure — Cluster Provider

Provisions an AKS hub cluster in Azure via Kind + Crossplane, with full platform
bootstrap (ArgoCD, ESO → Azure Key Vault, AGIC, Keycloak, Backstage).

## Prerequisites

1. **AVM module** (`terraform-azure-avm-ptn-alz-application-landing-zone-cicd-bootstrap-github`)
   applied — creates the UAMI + GitHub OIDC federated credentials + Bootstrap Key Vault.
2. Azure CLI: `az login` (local dev) or `azure/login@v3` action (CI).
3. Required CLIs: `az`, `kubectl`, `helm`, `kind`, `yq`, `jq`.

## Quick Start (local)

```bash
az login

cp config.yaml config.local.yaml
# Fill azure.* fields from your Bootstrap Key Vault — see config.yaml comments.
# Never hardcode subscription IDs, tenant IDs, or domain names in this file.
yq -i '.clusterProvider = "kind-crossplane-azure"' config.local.yaml

task kind-crossplane-azure:install    # bootstrap Kind → AKS → ArgoCD
task kind-crossplane-azure:destroy-kind  # remove Kind once AKS is self-managing
```

## Credential & Secret Model

This provider uses **Azure OIDC federation** — no long-lived secrets or PII stored
in the repository.

| Value | Where stored | Notes |
|-------|-------------|-------|
| `AZURE_CLIENT_ID` | GitHub **secret** | UAMI client ID — identity only |
| `AZURE_TENANT_ID` | GitHub **secret** | Tenant ID — identity only |
| `BOOTSTRAP_KV_NAME` | GitHub **secret** | Name of the Bootstrap Key Vault |
| Subscription ID | **Bootstrap Key Vault** | Never in code or logs |
| Location / Region | **Bootstrap Key Vault** | Never in code or logs |
| Platform domain | **Bootstrap Key Vault** | Never in code or logs |
| Cluster name | **Bootstrap Key Vault** | Never in code or logs |
| Keycloak passwords | **Platform Key Vault** | Seeded by `keyvault:seed-keycloak` |
| Platform config | **Platform Key Vault** | `<cluster>-config` secret, synced to AKS via ESO |

### Bootstrap Key Vault secrets

All platform configuration lives in a pre-provisioned Bootstrap Key Vault
(created by the AVM module). The workflow fetches them at runtime and masks
all values before use:

| Secret name | Content |
|-------------|---------|
| `platform-config` | JSON: `subscriptionId`, `location`, `domain`, `resourceGroup`, `repoUrl`, `repoRevision`, `clusterName`, `resourcePrefix` |

No customer-specific values (subscription IDs, tenant IDs, domain names, cluster
names, regions) should appear in any file committed to this repository.

## GitHub Actions

Trigger: `.github/workflows/deploy-azure-hub.yml`

Required GitHub **secrets** in environment `azure-hub`:

| Secret | Source |
|--------|--------|
| `AZURE_CLIENT_ID` | AVM module output `managed_identity_client_ids` |
| `AZURE_TENANT_ID` | AVM module output `tenant_id` |
| `BOOTSTRAP_KV_NAME` | AVM module — Bootstrap Key Vault name |

All other config (`subscriptionId`, `location`, `domain`, etc.) is fetched from
the Bootstrap Key Vault at workflow runtime and **never stored in GitHub**.

## Architecture

```
Kind cluster (bootstrap, ephemeral)
  └─ Crossplane + Azure providers
       └─ Workload Identity (UAMI + OIDC, no SP secret)
            └─ XAzurePlatformCluster claim
                 ├─ VNet + Subnets
                 ├─ Application Gateway (AGIC)
                 ├─ UAMIs (kubelet, ESO, AGIC)
                 ├─ AKS (OIDC + Workload Identity enabled)
                 └─ Platform Key Vault
                      └─ ESO ClusterSecretStore → K8s Secrets
                           └─ ArgoCD → root-appset → all addons
```

## Destroy

```bash
task kind-crossplane-azure:destroy        # full teardown (AKS + Azure resources + Kind)
task kind-crossplane-azure:destroy-kind   # Kind only (AKS persists)
```

## Troubleshooting

**OIDC endpoint not reachable:**
```bash
az storage account show --name <oidcStorageAccount> --query primaryEndpoints.web
```

**AKS cluster not Ready after 90 min:**
```bash
kubectl describe azureplatformcluster <cluster> -n crossplane-system
kubectl get managed | grep -v True
```

**Key Vault RBAC not propagated:** Role assignments take up to 30 min. Retry:
```bash
task kind-crossplane-azure:hub:cluster-secret-store
```

**Crossplane provider loses Azure auth:** Restart provider pods to pick up fresh token:
```bash
kubectl delete pod -n crossplane-system -l pkg.crossplane.io/revision --force
```
