# kind-crossplane-azure — Cluster Provider

Provisions an AKS hub cluster in Azure via Kind + Crossplane, with full platform
bootstrap (ArgoCD, ESO → Azure Key Vault, native AGC, Keycloak, Backstage).

## Existing-cluster config revision recovery

For the Azure student hub, infrastructure changes are Crossplane managed, config
is authoritative in Key Vault, and addon changes are applied by ArgoCD. Do not
rerun the legacy install steps below merely to update addon configuration.

The Azure cluster chart supports opt-in `clusters.<key>.configWriter.enabled`,
`configWriter.principalId` and `configWriter.vaultId` runtime parameters. These
render a Crossplane RoleAssignment granting Key Vault Secrets Officer only on
`<vaultId>/secrets/<clusterName>-config`. Keep identity/scope values out of source.
Bootstrap-seed the rendered managed resource on the management cluster if it has
no GitOps controller; Crossplane creates and reconciles Azure IAM. This does not
make the management cluster ArgoCD-managed. The assignment uses Orphan deletion
policy, so deleting its Kubernetes object does not revoke Azure access.

Use the authorized federated identity for Vault data-plane updates; preserve all
config fields and update `metadata`'s `addonsRepoRevision` and `fleetRepoRevision`
to the published commit. `metadata` is a serialized JSON string in this config.
Also preserve `azure_eso_mi_client_id`, sourced from the Crossplane XR status.
An empty client ID breaks ESO and prevents revision propagation. If already
broken, bootstrap only these cluster-Secret annotations from the authoritative
Vault config once; ArgoCD repairs ESO, then ESO resumes ownership. Do not directly
patch addon workloads or change their Applications' target revisions.

Recovery verified: Crossplane IAM Ready/Synced, Vault config updated through
federation, fleet ExternalSecret Ready, ESO Deployment updated and ready, and no
Pending pods. Workflow CPU reservations are 25m each; memory settings unchanged.
System pool remains 30 pods; this is not a pool-capacity increase.

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
# Keep Kind running until Azure resource ownership and federation are durably migrated.
```

### Bootstrap topology

The Kind bootstrap is **one control-plane plus two workers**. It is rendered by
`kind:create` from `kind.yaml`; the static manifest and the rendered config must
stay in sync.

### Adopting an already-running bootstrap cluster

`kind:create` never recreates a cluster that already exists under the resolved
name. To adopt a running cluster whose name is not `<hub.clusterName>-bootstrap`,
and whose issuer is already published, set:

```yaml
azure:
  kindClusterName: "<existing-kind-cluster>"
  oidcIssuerUrl: "https://<account>.blob.core.windows.net/<container>/clusters/<cluster>"
  oidcStorageAccount: "<account>"
  oidcStorageContainer: "<container>"
  oidcStorageResourceGroup: "<issuer-storage-resource-group>"
  bootstrapIdentityResourceGroup: "<bootstrap-uami-resource-group>"
```

With `oidcIssuerUrl` set, `workload-identity:publish` publishes the running
cluster's own public JWKS. It does not create storage, does not generate or read
a signing key, and fails closed if the live API server issuer differs from the
configured value. Blob uploads use `--auth-mode login` only — never account keys
or SAS — and the blob prefix is derived from the issuer path so an unrelated
cluster's documents are never overwritten.

The optional storage and identity resource-group overrides default to
`azure.resourceGroup`. Set them when shared public issuer storage, the dedicated
bootstrap UAMI, and the target AKS group are separate. Adoption refuses automatic
`destroy-kind` cleanup; it must not delete a shared storage account or active trust.


### Azure provider compatibility and sizing

Azure providers are pinned to v2.8.0. The family provider uses the canonical
dependency name `upbound-provider-family-azure`; installing the same package
under a second name breaks dependency resolution.

The runtime reuses the existing federated `crossplane-system/crossplane`
ServiceAccount without transferring its ownership to a provider revision.
`OIDCTokenFile` uses the webhook's `AZURE_FEDERATED_TOKEN_FILE`; do not hardcode
the projected token path, which changes between webhook versions and pods.
Verify an Observe-only ResourceGroup is `Synced=True` before applying claims.

Set the following Azure fields from the approved regional capacity plan:

```yaml
azure:
  systemNodeSize: "<approved-vm-sku>"
  systemNodeMin: 1
  systemNodeMax: 1
  vnetCidr: "10.240.0.0/15"
```

A system pool needs at least 4 vCPUs per node and B-series is not supported.
The observed one-node lab configuration is not a production HA configuration.
This Composition uses `maxSurge: "1"`; budget one additional node during an
upgrade. Do not interpret a successful cluster creation as proof that upgrade
quota is available. `maxSurge: "0"` alone is invalid without a compatible
`maxUnavailable` configuration.

Check regional SKU restrictions and family/total vCPU quotas before choosing.
ARM64 does not bypass quotas: `Standard_D4ps_v5` is a 4-vCPU/16-GiB ARM64 option
whose family quota is typically zero on constrained offers. Verify the exact
workload image manifests include `linux/arm64` before selecting it.

The VNet must contain the system/user subnets and must not overlap the AKS
service CIDR `10.0.0.0/16`. Budget quota for `systemNodeMax` plus any upgrade
surge. Quota request submission is not approval: inspect its final decision and
live limits before applying a claim. `ResourceNotAvailableForOffer` means the
subscription offer itself does not permit that capacity; only an eligible
subscription/offer or a provider-approved change unblocks it.
For narrowed RBAC, precreate `<hub.clusterName>-rg` and authorize only the
dedicated bootstrap identity on that group; do not grant subscription-wide roles.

The v2.8.0 Composition uses object-shaped AKS identity, node-pool and network
fields; `autoScalingEnabled`; Key Vault `skuName`/`rbacAuthorizationEnabled`;
and explicit managed-identity names. RoleAssignments receive observed principal
IDs through XR status and let the provider generate valid assignment UUIDs.

The Composition also publishes the AKS OIDC issuer into XR status and creates the
two AKS-side federated identity credentials the platform needs: ESO
(`system:serviceaccount:external-secrets:external-secrets-sa`) and the ALB
controller (`system:serviceaccount:azure-alb-system:alb-controller-sa`). Verify
the rendered subject names against the pinned charts before changing chart
versions. `hub:seed-secret` also writes `aws_cluster_name`/`aws_region` aliases
because shared bootstrap ApplicationSets read those keys on every cloud.

Installing ArgoCD does not move Crossplane ownership to AKS. Keep the bootstrap
cluster, issuer documents and federation until a separate ownership migration
has been verified. `destroy-kind` is not a safe automatic post-install step.

### Adopting an existing user node pool

The AKS chart can render an independent `KubernetesClusterNodePool` when a cluster
entry contains `userNodePool`. Its Azure identity is the pool's actual name, not
a new generated name. Start with `managementPolicies: [Observe]`, verify that
`status.atProvider.id` identifies the existing pool and that it is Ready/Synced,
then add `Update` only after all explicit desired fields match observation.
The chart uses `deletionPolicy: Orphan`; do not add `Create` or `Delete` policies
as part of an import. This pool remains managed from the Kind control plane and
is independent of the cluster claim's deletion lifecycle.

Set `userNodePool.name`, `vmSize`, `subnetId`, and the existing pool's
`nodeCount`, `osSku`, `osDiskSizeGb`, `maxPods`, `nodeLabels`, and `maxSurge`.
The pool is fixed-size (`autoScalingEnabled: false`). A `nodeCount` of zero is
preserved, but is a user-pool operation, not a full-cluster stop.

Legacy platform charts select `karpenter.sh/nodepool=system`. The system pool
publishes that compatibility label; when the user pool should also accept those
workloads, include the same key/value under `userNodePool.nodeLabels`. Persist
labels in Crossplane rather than applying them only to current Kubernetes Nodes.
This does not install Karpenter or change Azure pool mode: a User pool remains
User even with that label. Cloud/provider discovery must use the actual Azure
configuration or Node `spec.providerID`, not the Karpenter-named selector.
The label does not create availability zones or override pod topology constraints.

Render only the pool during adoption so the live cluster Composition and claim
are not reapplied incidentally:

```bash
helm template azure-platform gitops/abstractions/crossplane/azure-platform-cluster \
  -f "$POOL_VALUES_FILE" --show-only templates/nodepool.yaml |
  kubectl --kubeconfig "$KIND_KUBECONFIG" apply -f -
```
### Subscription provider registrations

The Azure cluster chart accepts `resourceProviderRegistrations`, a list of
`namespace`, optional `features` (feature names to register), and optional
`providerConfigName`. Set `global.subscriptionId` and declare these registrations
once per subscription, outside the per-cluster values. Native AGC prerequisites
are `Microsoft.ContainerService` with `ManagedGatewayAPIPreview` and
`ApplicationLoadBalancerPreview`, plus `Microsoft.Network`,
`Microsoft.NetworkFunction`, and `Microsoft.ServiceNetworking`.

These render Crossplane `ResourceProviderRegistration` objects, not Helm hooks.
The selected provider identity needs subscription-scoped registration permissions;
resource-group Contributor is insufficient. Resources use Orphan deletion and
exclude Delete management policy, so chart removal does not unregister providers.
Successful rendering or Kubernetes admission is not evidence of Azure registration:
verify Azure provider and feature states before enabling the native addon.

Registration IAM is an explicit operator task, never an automatic subscription
privilege grant during `install`:

```bash
task --taskfile cluster-providers/kind-crossplane-azure/Taskfile.yaml registration-iam:grant
task --taskfile cluster-providers/kind-crossplane-azure/Taskfile.yaml registration-iam:status
# Destructive, only when registration access is no longer required:
task --taskfile cluster-providers/kind-crossplane-azure/Taskfile.yaml registration-iam:revoke CONFIRM=yes
```

Set `azure.crossplanePrincipalId` or allow lookup using the bootstrap identity
resource group and client ID. `azure.agcIam.evidencePath` chooses the private
journal; point it at the original recorded IAM change to preserve ownership of
an earlier grant. Existing resources are validated without modification;
discovery alone never grants deletion ownership. Grant preserves original
ownership and appends events, including partial changes. Status prints exact
Terraform import IDs. Revoke only removes owned IAM and keeps a custom role
when other assignments use it. Built-in role definitions are never removed.

### Native AKS Application Gateway for Containers

Opt in with the Azure bootstrap configuration:

```yaml
azure:
  agc:
    enabled: true
    subnetCidr: 10.242.0.0/24
```

Choose a free dedicated IPv4 /24 or larger; the example is outside the default
node VNet range. `install` invokes `agc:setup` after creating the root ApplicationSet,
so failed native AGC prerequisites do not prevent other addons from being activated.
The task renders chart declarations and `native_agc.py` sequences their
reconciliation: subscription registrations, federated AzAPI provider v2.2.1,
additional VNet prefix, delegated subnet, native addon, and the native managed
identity's subnet-scoped Network Contributor assignment. All Azure writes are
made by Crossplane; Azure CLI is used only for network and identity readback.
The existing VNet Composition receives only its AGC patch; the helper does not
reapply a potentially stale full Composition during adoption.

The addon is currently Azure preview and requires both documented preview
features. Native enablement uses `UpdateResource` for only
`ingressProfile.applicationLoadBalancer.enabled` and
`ingressProfile.gatewayAPI.installation`, fields absent from Azure provider v2.8.0.
The original typed resource remains the cluster owner. Do not substitute
`ingressApplicationGateway` (legacy AGIC), install a second controller via Helm,
or assume typed-provider/native-addon coexistence is proven without live updates.

The AzAPI runtime explicitly projects a token for the existing `crossplane`
service account and `api://AzureADTokenExchange` audience. It uses the existing
OIDC federation, without static credentials or dependency on webhook injection.
Subscription registration must be authorized separately; the task never grants
subscription Contributor/Owner or silently falls back to CLI provisioning.

After current-generation reconciliation and GatewayClass acceptance, bootstrap
publishes `agc_native_ready=true` and `azure_agc_subnet_id` on the Argo cluster
Secret. The registry requires that readiness label in addition to the Azure and
enable-addon selectors. Sync waves alone are not dependency gates. Failed setup
does not publish readiness. The label is a bootstrap checkpoint, not continuous
Azure health monitoring.

The Gateway chart exposes HTTP/80 only, with Same-namespace routes by default.
No DNS, application routes, or TLS certificates are invented. AGC billing is
independent of node CPU quota, and stopping AKS does not tear down AGC. Registrations,
subnet, permission and native update use Orphan/no-Delete policies; disabling the
flag does not reverse existing cloud settings. Teardown requires a separate
reviewed sequence. Crossplane continues running on Kind.




## Power management

AKS full-cluster start/stop is **not** exposed by the installed typed provider:
`KubernetesCluster` v1beta2 has no `powerState` in either spec or status. Do not
invent one or patch ARM behind Crossplane's back.

Two supported options exist, and they differ in who runs the schedule:

1. **Declarative (Crossplane/AzAPI)** — `ResourceAction` can call ARM
   `start`/`stop` on the cluster, but it is a one-shot action resource, not a
   scheduler. Verified on this cluster: a `ResourceAction` with `method: GET`
   reconciled `Synced`/`Ready` against the real AKS ARM ID. Using it for power
   still needs something to create/delete that action on a timetable, and that
   something must live outside the cluster being stopped. In this deployment
   that is Kind, so it inherits the workstation-availability caveat.
2. **Azure Automation runbook + managed identity** — the conventional choice
   for unattended schedules: Azure-native scheduler, no long-lived secrets, and
   it can start a stopped cluster without depending on Kind or a workstation.
   A least-privilege custom role needs only `managedClusters/read`,
   `managedClusters/start/action`, and `managedClusters/stop/action`.

This repository therefore ships `aks_power.py` plus `power:status`, `power:stop`
(CONFIRM=yes), and `power:start` tasks as the **supervised** mechanism: it
suspends the Crossplane `KubernetesCluster` and `KubernetesClusterNodePool`
management policies before stopping, then restores them after start. That
prevents a stopped cluster from being reconciled. It deliberately does not
install an unattended schedule; choosing working hours, timezone and holidays is
an owner decision.

`az` CLI is used only as the transport for start/stop and power-state polling in
this supervised path. It is not an ownership change: desired state stays in
Crossplane on Kind.

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
                 ├─ Role assignments (network, Key Vault, ALB controller)
                 ├─ UAMIs (control-plane, ESO, ALB controller)
                 ├─ AKS (OIDC + Workload Identity enabled)
                 └─ Platform Key Vault
                      └─ ESO ClusterSecretStore → K8s Secrets
                           └─ ArgoCD → root-appset → all addons
```

## Destroy

```bash
task kind-crossplane-azure:destroy        # full teardown (AKS + Azure resources + Kind)
task kind-crossplane-azure:destroy-kind   # refuses adopted cluster/storage; review ownership first
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
