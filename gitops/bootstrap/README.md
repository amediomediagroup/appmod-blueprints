# Bootstrap

This directory makes the hub cluster self-managing. Once ArgoCD is running on the hub and `root-appset.yaml` is applied, the hub syncs this directory and takes over its own addon lifecycle -- no external controller needed.

## Files

| File | Sync-Wave | Purpose |
|------|-----------|---------|
| `root-appset.yaml` | -- | Entry point. Applied once by the cluster provider. Syncs the rest of this directory to the hub. |
| `addons.yaml` | -1 | Renders the appset-chart on the hub, producing one ApplicationSet per enabled addon. |
| `fleet-secrets.yaml` | 1 | Creates a fleet-secret Application per member cluster, generating cluster secrets with `enable_*` labels. |
| `clusters.yaml` | 5 | Deploys the `platform-cluster` Helm chart to provision fleet member clusters via Crossplane/KRO. |

## Bootstrap Sequence

1. The cluster provider (e.g. `kind-crossplane`) applies `root-appset.yaml` to the hub.
2. `root-appset.yaml` creates a `bootstrap` Application that syncs this directory (excluding itself) to the hub's ArgoCD.
3. ArgoCD applies the remaining three ApplicationSets in sync-wave order:
   - Wave -1: `addons.yaml` -- installs the addon pipeline on the hub.
   - Wave 1: `fleet-secrets.yaml` -- generates cluster secrets for each fleet member.
   - Wave 5: `clusters.yaml` -- provisions fleet member infrastructure.

## How root-appset.yaml Works

`root-appset.yaml` uses a `clusters` generator with `matchLabels: fleet_member: control-plane`. This means it only targets the hub cluster's own ArgoCD secret. It reads repo coordinates from the secret's annotations (`fleetRepoURL`, `fleetRepoRevision`, `fleetRepoBasepath`) and syncs the `bootstrap/` directory, excluding itself to avoid a loop.

## How addons.yaml Works

Uses a `clusters` generator matching `fleet_member: control-plane`. Renders the `appset-chart` Helm chart with the full addon registry (`_defaults.yaml`, `core.yaml`, `gitops.yaml`, etc.) plus environment and cluster overlays. The output is one ApplicationSet per addon definition, each with selectors that match `enable_*` labels on cluster secrets.

`preserveResourcesOnDeletion: false` -- removing an addon from the registry removes its ApplicationSet and all generated Applications.

## How fleet-secrets.yaml Works

Uses a matrix generator combining:
- `clusters` generator matching `fleet_member: control-plane` (the hub)
- `git` generator scanning `fleet/members/*/values.yaml`

For each fleet member, it renders the `fleet-secret` chart, which produces a Kubernetes Secret in the `argocd` namespace with labels like `enable_argocd: true`, `enable_external-secrets: true`, etc. These labels are what the addon ApplicationSets select on.

`preserveResourcesOnDeletion: true` -- removing a member from git does not delete its cluster secret (safety measure).

## How clusters.yaml Works

Uses a `clusters` generator matching `fleet_member: control-plane`. Deploys the `abstractions/crossplane/platform-cluster` Helm chart with values from `fleet/kro-values/`. This creates `PlatformCluster` custom resources that Crossplane reconciles into VPC + EKS + IAM infrastructure.

Values are layered: default values, then per-tenant overrides.

## The control-plane Label

Most ApplicationSets in this directory use the same generator selector:

```yaml
selector:
  matchLabels:
    fleet_member: control-plane
```

This label exists on the hub cluster's ArgoCD secret. It ensures these ApplicationSets only target the hub -- they read the hub's repo annotations and deploy to the hub's ArgoCD namespace. Fleet member clusters get their addons through the addon pipeline, not through these bootstrap ApplicationSets directly.

## Azure provider boundary

An AKS hub with `cloud: azure` uses the shared addon pipeline and
`hub-fleet-secret-azure.yaml`. The AWS hub-secret ApplicationSet must not select
that hub. EKS cluster generators, AWS spoke registration/client provisioning,
and the Crossplane abstraction generator also exclude the Azure hub; they
otherwise require AWS role ARNs, EKS authentication, Secrets Manager, or
Crossplane controllers not installed on this AKS hub.

This exclusion does not move infrastructure ownership. For the Kind-to-AKS
provider, Azure resources remain controlled by Crossplane on Kind until a
separately verified ownership migration. ArgoCD on AKS does not overwrite the
Kind Composition merely by syncing its own bootstrap directory.

Installing ArgoCD and ESO is only the one-time bootstrap prerequisite. Full
addon fan-out additionally requires the hub registration Secret, a Git revision
containing the Azure configuration, a seeded Key Vault config payload readable
through `azure-key-vault`, and actual ingress/domain settings for consumers that
derive public URLs. Do not replace missing deployment inputs with example domains
or silently grant Key Vault write roles to the operator.

