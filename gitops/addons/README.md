# Addons

Addon catalog, configuration, and custom charts for the GitOps platform. Everything ArgoCD needs to know about an addon lives here.

## Directory Structure

```
addons/
├── registry/       What can be deployed — addon definitions split by domain
├── configs/        How to configure them — default Helm values per addon
└── charts/         Custom wrapper charts — when upstream charts aren't enough
```

## How the Three Directories Relate

1. `registry/` defines each addon: its chart source, namespace, sync-wave, and cluster selector.
2. `configs/` provides the default Helm values passed to the addon's chart at deploy time.
3. `charts/` holds custom Helm charts for addons that wrap multiple upstream charts or need extra resources (e.g., ExternalSecrets, IAM roles). Registry entries for these addons use a `path:` field pointing here instead of `chartRepository`.

The appset-chart reads registry entries to generate ArgoCD ApplicationSets. Each ApplicationSet references the corresponding `configs/<addon>/values.yaml` as a value file source. Missing files are silently skipped.

## configs/

One directory per addon containing default Helm values and optional manifests:

```
configs/
├── argocd/values.yaml
├── external-secrets/
│   ├── values.yaml
│   └── manifests/          Additional raw manifests (used via additionalResources)
├── ingress-nginx/values.yaml
└── ...
```

These are the base values. Environment and cluster overlays in `overlays/` layer on top.

## charts/

Custom wrapper Helm charts for addons that need more than a single upstream chart:

```
charts/
├── keycloak/               Wraps Keycloak + ExternalSecrets + PushSecret
├── grafana/                Wraps Grafana + IAM + ingress config
├── backstage/              Wraps Backstage + ExternalSecrets
└── ...
```

Each has a standard Helm structure (`Chart.yaml`, `values.yaml`, `templates/`). Registry entries reference these via `path:` instead of `chartRepository`.

## How to Add a New Addon

1. Add an entry to `registry/<domain>.yaml` with the required fields (`namespace`, `selector`, `annotationsAppSet`, and either `chartRepository`/`defaultVersion` or `path`). See `registry/README.md` for field details.

2. Create `configs/<addon-name>/values.yaml` with default Helm values for the upstream chart. Skip this if the addon needs no custom values.

3. If the addon requires a custom wrapper chart (multiple sub-charts, ExternalSecrets, IAM resources), create `charts/<addon-name>/` with a standard Helm chart. Point the registry entry's `path:` to it.

4. Add `enable_<addon_name>: true` to the relevant `overlays/environments/<env>/enabled-addons.yaml` files.

5. Commit and push. ArgoCD picks up the change automatically.

## Azure: agc-gateway

**Owner:** `gitops/addons/charts/agc-gateway/` (chart), `gitops/addons/registry/azure.yaml` (registry key `agc_gateway`)

The `agc-gateway` chart manages the two Kubernetes CRs needed to expose HTTP traffic through Azure Application Gateway for Containers (AGC):

| Resource | API | Purpose |
|---|---|---|
| `ApplicationLoadBalancer` | `alb.networking.azure.io/v1` | Instructs the ALB controller to provision and manage the AGC instance in Azure. References the dedicated delegated subnet via `spec.associations`. |
| `Gateway` | `gateway.networking.k8s.io/v1` | Binds to `GatewayClass: azure-alb-external` (installed by the AKS native AGC addon). HTTPRoutes attach to this Gateway to configure routing rules. |

**What this chart does NOT manage:** the ALB controller itself, its CRDs, HTTPRoutes, or sample backends. The controller is installed by the AKS native AGC addon (`enableApplicationGatewayForContainers: true` on the cluster).

### Route namespace policy

`gateway.allowedRoutesFrom` controls which namespaces may attach HTTPRoutes:

- `Same` (default) — only HTTPRoutes in the same namespace as the Gateway. Safest; avoids cross-namespace traffic leakage.
- `All` — HTTPRoutes from any namespace. Use when workloads are spread across namespaces and a single Gateway is shared.
- `Selector` — HTTPRoutes from namespaces matching `gateway.allowedRoutesSelector` labels. Fine-grained policy for multi-tenant clusters.

### Public HTTP / cost boundary

A public HTTP/80 listener begins accruing AGC capacity-unit charges the moment the Gateway is synced. Do not enable `agc_gateway` in non-production environments unless the cost boundary is understood and budgeted.

### Readiness requirement

Deployment is gated by **two** cluster Secret labels, both must be `true`:

| Label | Set by | Condition |
|---|---|---|
| `enable_agc_gateway` | Bootstrap / Crossplane | Subscription provider registrations complete |
| `agc_native_ready` | `native_agc.py` | Provider registrations Ready/Synced **and** `UpdateResource` Ready/Synced **and** `GatewayClass azure-alb-external` Accepted **and** subnet delegated to `Microsoft.ServiceNetworking/trafficControllers` **and** scoped NetworkContributor assignment Ready |

`native_agc.py` leaves `agc_native_ready` absent (not `false`) on any failure; the ApplicationSet generator therefore produces no Application until both labels are present. The environment overlay sets `agc_gateway: true` — actual deployment is withheld by the selector, not the flag.

### Required cluster annotation

| Annotation | Description |
|---|---|
| `azure_agc_subnet_id` | Full ARM resource ID of the AGC-dedicated delegated subnet. Format: `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>`. The subnet must be delegated to `Microsoft.ServiceNetworking/trafficControllers`. |

Set by `hub:seed-secret` (bootstrap); never hardcode in this repo.
