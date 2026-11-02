<!-- Copyright (c) 2026 Accenture, All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. -->

# Horizon SDV — Local Developer Prototype (Proposal)

## 1. Purpose

Provide a **minimal, self-contained Horizon** that a developer can stand up on
their own laptop (macOS, or Windows via WSL2) using the Kubernetes built into
**Rancher Desktop** (primary) or **Docker Desktop**. The goal is to relieve the
shortage of shared cloud development environments for **UX work, module
development, and basic platform-service development** — without any Android
builds, Cloud Workstations, ABFS, or other cloud-compute-intensive functions.

Guiding principles:

- **Keep the wiring as realistic as production as possible.**
- **Keep the core application code unmodified** (images, `keycloak.mjs`,
  `configure.sh`). All local behaviour is additive overlay + a few local-only
  stubs.
- **Keep production safe.** The prototype is developed on a public GitHub branch
  and will eventually merge to `main`, so the Terraform toggle defaults to GCP
  and leaves existing deployments byte-for-byte unchanged.

## 2. Scope

| In scope | Out of scope |
|---|---|
| Horizon Developer Portal (UX) | Jenkins, Gerrit, Grafana/monitoring |
| Horizon API | MCP gateway / Gemini proxy |
| Module Manager (identical to production; full `ModuleCatalog`) | Android / OpenBSW workloads, ABFS |
| Argo Workflows (archiving disabled) | Cloud Workstations |
| Keycloak + PostgreSQL (real OIDC) | Config Connector / KCC **controller** (CRDs installed as inert stubs), GCS, Spanner, Artifact Registry |
| ArgoCD (trimmed overlay, Keycloak OIDC) | GCP LB / Gateway API / Cloud DNS / managed certs / KMS |
| | External Secrets / Secret Manager, Workload Identity |

## 3. Decisions (resolved)

| Topic | Decision |
|---|---|
| Cluster source | Desktop Kubernetes (Rancher Desktop primary, Docker Desktop secondary); not created by Terraform |
| Safety gate | `deploy.sh --local` refuses any kube context other than `rancher-desktop` / `docker-desktop` |
| Terraform config | **Separate `terraform/local` root** (sibling of `terraform/env`); no `google` provider, `backend "local"`. `terraform/env` is untouched, so the GCP plan is byte-for-byte unchanged |
| Prod safety | Local uses its own root + its own state; nothing in the cloud path is modified |
| App delivery | Keep **ArgoCD**, pointed at the **same `gitops/` chart** as production |
| GitOps source | **Single source of truth:** one `gitops/` chart. Local mode is selected by `config.local.enabled=true` in the ArgoCD Application values — no `gitops-local/` copy that could drift |
| Services | Portal, Horizon API, Module Manager, Argo Workflows, Keycloak (+PostgreSQL) |
| Auth | Real Keycloak; reuse production `keycloak-post-*` jobs unmodified |
| Dev users | Two: `admin` (group `administrators`), `developer` (group `developers`) |
| Dev password | Single standard, policy-compliant value `Horizon@123` (realm policy kept as prod) |
| Ingress | **ingress-nginx**, with k3s **Traefik disabled** on Rancher Desktop |
| Hostname / DOMAIN | `horizon.local` (host `/etc/hosts` + in-cluster CoreDNS rewrite) |
| TLS | **Self-signed** cert (browser warnings accepted); CA injected into OIDC-consuming pods |
| Images | Build locally, load into desktop image store; `imagePullPolicy: IfNotPresent` |
| Image load | Rancher **containerd** via `nerdctl`/`rdctl` (namespace `k8s.io`); fallback `docker` |
| Secrets | Plain Kubernetes Secrets generated at deploy time; External Secrets dropped |
| PostgreSQL | **PVC** (k3s `local-path`), so realm/users persist across restarts |
| Resource limits | **Keep all chart requests/limits unmodified**; document the resulting machine floor |
| Workflows storage | Artifact archiving disabled (no GCS) |
| Network policies | Disabled locally (`enableNetworkPolicies=false`) |
| Module Manager | **Identical to production** (same chart + full `ModuleCatalog`, no trimming) so production MM can be developed on the local cluster. Modules' cloud (`*.cnrm.cloud.google.com`) resources are stubbed cluster-wide: `bootstrap-local.sh` installs the KCC **CRDs only** (no controller) and `terraform/local/argocd.tf` adds an ArgoCD health override that reports those CRs Healthy. They apply but provision nothing |
| Windows | WSL2 |
| Tracking | Prototype branch only (no Jira) |

## 4. Architecture

### 4.1 Deploy flow

```
./deploy.sh --local
  ├─ safety gate: kube context ∈ {rancher-desktop, docker-desktop}
  ├─ skip gcloud auth + GCP requirement checks
  ├─ build-local-images.sh         # portal, horizon-api, module-manager, keycloak-post-* → k8s.io
  ├─ bootstrap: disable Traefik, install ingress-nginx, self-signed cert for horizon.local,
  │             CoreDNS rewrite, /etc/hosts guidance, CA secret for pod injection
  └─ terraform -chdir=terraform/local apply
        ├─ plain K8s Secrets (dev creds)
        ├─ ArgoCD (no External Secrets)
        └─ ArgoCD Application → gitops/ with config.local.enabled=true
```

### 4.2 Terraform: separate `terraform/local` root

`terraform/env` (the cloud root) is **not touched**. A sibling root
`terraform/local` was added because `terraform/modules/base` declares provider
config blocks (`google`, `google-beta`, `docker`, …), which makes that module
impossible to `count`/`for_each`-gate from a unified root. The separate root
sidesteps that entirely:

- No `google`/`google-beta` providers at all — nothing can call GCP.
- `backend "local"` (state in `terraform/local`), so the prod GCS backend is
  irrelevant to the local flow.
- `kubernetes` / `helm` / `kubectl` providers target `var.kube_context`
  (validated to `rancher-desktop` / `docker-desktop`).
- Resources: namespaces, self-signed CA + TLS, ingress-nginx, ArgoCD, plain dev
  Secrets, CA ConfigMaps, and the one ArgoCD `Application` that points at the
  shared `gitops/` chart.

### 4.3 GitOps: single `gitops/` chart, `config.local.enabled` switch

There is **no separate `gitops-local/` copy**. The production `gitops/` umbrella
gained one switch, `config.local.enabled` (default **false** → production
unchanged), set to `true` only by the `terraform/local` ArgoCD Application. The
switch drives, inside the existing templates:

- **Out-of-scope apps** (Jenkins, Gerrit, Grafana, MTK, Headlamp, MCP registry,
  Config Connector, External DNS, Argo Events, Kubescape, Zookeeper, monitoring,
  dynpvc, openbsw, and the GKE `Gateway`): wrapped in
  `{{- if not .Values.config.local.enabled }}` so they render only in the cloud.
- **In-scope routing**: the 5 `gateway-*.yaml` files emit an **ingress-nginx
  `Ingress`** (via the `horizon.local.ingress` helper in `_local.tpl`) when local,
  and the GKE `HTTPRoute`/`HealthCheckPolicy`/`GCPBackendPolicy` when cloud.
- **keycloak-init.yaml**: gated off locally (ESO + Workload-Identity SA are
  cloud-only); Terraform supplies the equivalent plain Secrets.
- **postgresql-init.yaml**: local branch creates the PVC against the cluster
  default StorageClass instead of GKE `pd.csi`.
- **keycloak-post-apps.yaml**: the 6 out-of-scope client jobs are gated off; only
  `horizon-api`, `argo-workflows`, `argocd` (plus the realm seed and dev-portal
  client job) run locally.

Every change is proven prod-safe with `helm template` (cloud render is
byte-for-byte identical with the switch off).

### 4.4 Networking / ingress / TLS

Production routing uses the **GKE Gateway API** (`gke-gateway`,
`HealthCheckPolicy`, `GCPBackendPolicy`, GCP-managed certs) — absent on desktop
Kubernetes. Locally replaced by **ingress-nginx** (k3s **Traefik disabled** to
free ports 80/443) with path-based routing under one host:

| Path | Backend |
|---|---|
| `https://horizon.local/auth` | Keycloak |
| `https://horizon.local/developer-portal` | Portal |
| `https://horizon.local/horizon-api` | Horizon API |
| `https://horizon.local/workflows` | Argo Workflows server |
| `https://horizon.local/argocd` | ArgoCD server |

**Dedicated hostname, not bare `localhost`:** OIDC is validated server-side
(ArgoCD, portal proxy, Horizon API fetch issuer/JWKS at
`${DOMAIN}/auth/realms/horizon`). In a pod, `localhost` is the pod itself, and
the token `iss` claim must match for both browser and pods. `horizon.local`
resolves consistently:

- host `/etc/hosts`: `127.0.0.1 horizon.local`
- in-cluster **CoreDNS rewrite**: `horizon.local` → ingress-nginx Service ClusterIP
- **self-signed** certificate for `horizon.local`

**Self-signed trust:** the browser warning is accepted. Because the self-signed
CA isn't trusted by the OS, the in-cluster OIDC clients get the CA injected so
server-side validation still works, additively and dev-only:

- ArgoCD: `oidc.config.rootCA` set to the CA
- Node services (portal proxy, keycloak-post jobs): `NODE_EXTRA_CA_CERTS`
- Go / other services (Horizon API): mounted CA via `SSL_CERT_FILE`

### 4.5 Images

Portal, Horizon API, Module Manager and the Keycloak post-config jobs are custom
images (production pulls them from Google Artifact Registry). `build-local-images.sh`
builds them from the repo and loads them into the desktop image store, pinning
local tags with `imagePullPolicy: IfNotPresent`. On Rancher Desktop (containerd)
images are loaded into the **`k8s.io`** namespace via `nerdctl`/`rdctl`; if Rancher
is in dockerd (moby) mode, `docker` is used. Argo Workflows, Keycloak, PostgreSQL
and ingress-nginx use upstream public charts/images.

### 4.6 Secrets

External Secrets + GCP Secret Manager are dropped. The local path generates plain
Kubernetes Secrets at deploy time (`keycloak-initial-creds`, PostgreSQL creds,
ArgoCD admin, etc.) seeded from `dev_password`.

### 4.7 Identity / OIDC wiring (realistic, reused unmodified)

Reuse these **four** production job images, unchanged, driven only by env +
image tags from the overlay:

| Job image | Creates |
|---|---|
| `keycloak-post` (base) | Realm `horizon`, role `realm_admin`, realm groups `administrators` / `viewers` / `developers`, `groups`/`roles` client scopes + mappers, one temporary admin user |
| `keycloak-post-horizon-api` | Clients `horizon-api` (public, PKCE, device grant), `horizon-api-ci` (confidential, service account), `horizon-dev-portal` (public SPA) + CI secret hand-off |
| `keycloak-post-argo-workflows` | Client `argo-workflows-oauth`, client roles `administrators`/`developers` mapped to realm groups, secret dump |
| `keycloak-post-argocd` | Client `argocd`, roles `administrators`/`viewers` → groups, `roles` claim mapper, `argocd` realm user; `configure.sh` patches `argocd-cm`/`argocd-secret`/`argocd-rbac-cm` and restarts argocd-server |

Issuer for all: `https://horizon.local/auth/realms/horizon`. The jobs already
emit `localhost`/`127.0.0.1` CLI callback URIs, so CLIs (`argocd login --sso`,
Horizon API device grant) also work.

Env the jobs require (supplied by the overlay): `PLATFORM_URL`, `DOMAIN` (both
`https://horizon.local`), `KEYCLOAK_USERNAME` / `KEYCLOAK_PASSWORD`,
`HORIZON_ADMIN_USERNAME` / `HORIZON_ADMIN_PASSWORD`, `ARGOCD_ADMIN_USERNAME` /
`ARGOCD_ADMIN_PASSWORD`, `NAMESPACE_PREFIX` ("").

## 5. Keeping core code unmodified — the stub strategy

No edits to existing images, `keycloak.mjs`, or `configure.sh`. All gaps are
closed additively:

1. **Env-driven Job overlays** — real job images run as-is; only env + image tag
   differ.
2. **Stub `jenkins` namespace** — `keycloak-post-horizon-api/configure.sh` does a
   failing-mode `curl -fS POST …/namespaces/jenkins/secrets` for the CI secret.
   An empty `jenkins` namespace lets the unmodified script succeed; it also writes
   the portal's copy of the same secret, which we want.
3. **Local-only "dev users" finisher Job** — stand-in for the production
   `tools/users_mgmt` admin step. Via `kcadm` it resets the horizon admin to a
   **permanent** `Horizon@123`, creates `developer` (permanent `Horizon@123`), and
   adds `admin`→`administrators`, `developer`→`developers`. Only new code; purely
   additive (the base job's `temporary:true` behaviour and the realm password
   policy stay exactly as production).

## 6. tfvars (proposed)

Lives in `terraform/local/terraform.tfvars` (flat variables; sibling root). See
`terraform/local/terraform.tfvars.sample` for the committed template.

```hcl
# Cluster / safety gate
kube_context = "rancher-desktop"   # or "docker-desktop"
base_domain  = "horizon.local"

# GitOps source — the SAME gitops/ chart as production.
# config.local.enabled=true (set by terraform/local/application.tf) picks local mode.
scm_repo_url    = "https://github.com/<org>/horizon-sdv"
scm_repo_branch = "horizon-local-development-mode"
gitops_path     = "gitops"

# Locally built images
image_tag         = "local"
image_pull_policy = "IfNotPresent"
image_overrides = {
  horizon-dev-portal           = "horizon/horizon-dev-portal:local"
  horizon-api-app              = "horizon/horizon-api:local"
  module-manager-app           = "horizon/module-manager:local"
  keycloak-post                = "horizon/keycloak-post:local"
  keycloak-post-horizon-api    = "horizon/keycloak-post-horizon-api:local"
  keycloak-post-argo-workflows = "horizon/keycloak-post-argo-workflows:local"
  keycloak-post-argocd         = "horizon/keycloak-post-argocd:local"
}

# Services (fixed scope)
enabled_services = ["keycloak", "argocd", "horizon-api", "module-manager", "argo-workflows", "portal"]

# Dev credentials (localhost-only; realm-policy compliant)
dev_password = "Horizon@123"
dev_users = [
  { username = "admin",     groups = ["administrators"] },
  { username = "developer", groups = ["developers"] },
]

# Local behaviour toggles (differ from prod defaults)
enable_network_policies = false
argo_workflows_archive  = false
keycloak_post_jobs      = ["base", "horizon-api", "argo-workflows", "argocd"]
postgresql_persistence  = true    # PVC on cluster default StorageClass
```

## 7. Work breakdown

1. `deploy.sh` `--local` dispatch → `deploy-local.sh`: context safety gate, skip
   gcloud/GCP checks, Traefik-off + ingress-nginx + self-signed cert + CoreDNS
   rewrite bootstrap, localhost-only binding warning, `terraform/local` apply.
2. `terraform/local` sibling root: no google provider, `backend "local"`,
   kubernetes/helm/kubectl providers from `var.kube_context`.
3. Single-source `gitops/` conditionality via `config.local.enabled`: gate
   out-of-scope apps, Ingress branch for the 5 in-scope gateways, keycloak-init
   gated, postgresql-init local PVC, keycloak-post out-of-scope jobs gated.
5. `build-local-images.sh` (nerdctl/rdctl `k8s.io`, docker fallback).
6. Plain-secret generator (from `dev_password`) + CA secret for pod injection.
7. Keycloak Job overlays (env + tags) for the four reused jobs + stub `jenkins`
   namespace + CA injection env.
8. Local-only "dev users" finisher Job.
9. Module Manager kept identical to production (full `ModuleCatalog`); cloud
   dependencies stubbed cluster-wide — `bootstrap-local.sh` installs the KCC CRDs
   only (no controller) and `terraform/local/argocd.tf` adds an ArgoCD health
   override so inert `*.cnrm.cloud.google.com` CRs report Healthy.
10. Measure the unmodified-limits resource floor; docs for macOS + Windows/WSL2.

## 8. Known limitations (by design)

- Horizon API `downloadArtifact` (GCS V4 signed URLs) is non-functional — no GCS.
- Argo Workflows run but archive nothing. Cloud-backed modules can be enabled and
  their ArgoCD Applications go Healthy, but their `*.cnrm.cloud.google.com` resources
  are inert stubs (no KCC controller) and provision nothing in GCP; module pods that
  call GCP at runtime will not function. Module Manager's own reconcile/enable/disable/
  dependency logic is fully exercised.
- No build node pools / horizontal scale; single-node desktop Kubernetes only.
- Realm policy includes `forceExpiredPasswordChange(75)`, so `Horizon@123` expires
  after 75 days (re-run the finisher Job to reset).
- Self-signed cert: the browser shows a warning (accepted); CA is injected into
  pods for server-side OIDC.
- Weak shared password is safe **only** because ingress binds to `127.0.0.1`;
  `deploy.sh --local` warns against exposing the stack via `0.0.0.0` port-forwards
  or tunnels.
- Resource requests/limits are left at production values; the machine must provide
  the stack's floor (see §10).

## 9. Running the prototype (macOS and Windows/WSL2)

### 9.1 Prerequisites (both platforms)

- **Rancher Desktop** (primary) with **Kubernetes enabled**, or **Docker Desktop**
  with Kubernetes enabled. Kube context must be `rancher-desktop` or
  `docker-desktop` (the deploy script refuses anything else).
- **Container engine for image loading:** Rancher Desktop in **containerd** mode
  is recommended (images load into the `k8s.io` namespace via `nerdctl`/`rdctl`).
  dockerd (moby) mode also works (`docker`). If no engine is available, deploy
  with `--skip-build` and supply images another way.
- CLIs on `PATH`: `kubectl`, `terraform`, `git`, `bash`, plus `helm` (bundled with
  Rancher Desktop). Deploy-time network access to GitHub (gitops + modules) and to
  the pinned Config Connector CRDs is required.
- Allocate enough VM resources — see **§10 Resource floor**.

### 9.2 macOS (Rancher Desktop)

1. Rancher Desktop → **Preferences → Virtual Machine**: set CPUs/Memory per §10.
2. **Preferences → Kubernetes**: enable Kubernetes; **uncheck Traefik** (the
   bootstrap also removes it, but unchecking stops k3s recreating it on restart).
3. `kubectl config use-context rancher-desktop`.
4. The bootstrap adds `127.0.0.1 horizon.local` to `/etc/hosts` (prompts for
   `sudo`); add it manually if you decline.

### 9.3 Windows via WSL2 (Rancher Desktop)

1. Install Rancher Desktop for Windows with **WSL2 integration** enabled for your
   distro; run all commands from inside that WSL2 distro.
2. Set WSL2 VM resources in `C:\Users\<you>\.wslconfig` (WSL2 defaults to ~half of
   host RAM), e.g.:

   ```ini
   [wsl2]
   processors=6
   memory=12GB
   ```

   then `wsl --shutdown` and reopen the distro.
3. `kubectl config use-context rancher-desktop` (available inside WSL via the
   Rancher Desktop WSL integration).
4. **Add `horizon.local` to BOTH hosts files** — the browser runs on Windows, the
   cluster/scripts in WSL:
   - WSL: `127.0.0.1 horizon.local` in `/etc/hosts` (bootstrap does this).
   - Windows: `127.0.0.1 horizon.local` in
     `C:\Windows\System32\drivers\etc\hosts` (edit as Administrator).

### 9.4 Deploy / destroy

```bash
# One-time: create your tfvars from the template and set scm_repo_url / branch.
cp terraform/local/terraform.tfvars.sample terraform/local/terraform.tfvars
$EDITOR terraform/local/terraform.tfvars

# Deploy (gate → bootstrap → build images → terraform apply):
./deploy.sh --local                 # or: ./deploy.sh --local --skip-build

# Then open (accept the self-signed cert warning):
#   https://horizon.local/developer-portal
# Log in as  admin / Horizon@123   (or developer / Horizon@123).

# Useful variants:
./deploy.sh --local --plan          # terraform plan only
./deploy.sh --local --skip-bootstrap --skip-build   # re-apply only
./deploy.sh --local --destroy       # tear down (local state)
```

Entry points: `https://horizon.local/{developer-portal,horizon-api,workflows,argocd,auth}`.

## 10. Resource floor

The prototype keeps **all chart requests/limits at their production values**, so
the machine must provide the stack's floor on a single desktop node. Only the
portal pins explicit requests in-repo; the two Go services run request-less
(best-effort), and the packaged components (Keycloak, PostgreSQL, Argo Workflows,
ArgoCD, ingress-nginx) inherit their upstream chart defaults:

| Component | Requests (in-repo) | Notes |
|---|---|---|
| Horizon Dev Portal | 128Mi / 100m (limit 512Mi / 500m) | `gitops/apps/horizon-dev-portal/values.yaml` |
| Horizon API | none (best-effort) | no `resources:` block |
| Module Manager | none (best-effort) | no `resources:` block |
| Keycloak (keycloakx) | upstream chart default | JVM; the heaviest steady-state pod |
| PostgreSQL | upstream chart default | PVC-backed |
| Argo Workflows (server + controller) | upstream chart default | archiving disabled |
| ArgoCD (server, repo-server, controller, redis) | upstream chart default | ~4 pods |
| ingress-nginx | upstream chart default | single controller |

Because several components rely on upstream defaults and actual usage is
higher than requests, **measure on first run** rather than trusting a static sum:

```bash
# Sum of CPU/memory requests actually scheduled:
kubectl get pods -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
CPU:.spec.containers[*].resources.requests.cpu,\
MEM:.spec.containers[*].resources.requests.memory
# Live usage (needs metrics-server; Rancher Desktop bundles it):
kubectl top pods -A
```

**Recommended Rancher Desktop / WSL2 VM allocation:**

- **Minimum:** 4 vCPU, 8 GB RAM, ~40 GB disk (core stack idle).
- **Comfortable:** 6 vCPU, 12 GB RAM — headroom for image builds and for enabling
  a sample Module Manager module. ArgoCD + Keycloak + PostgreSQL dominate RAM;
  image builds dominate transient CPU/disk.

These are starting points; record the measured floor for your fork in this
section once the stack has been run.

## 11. Open items

All prior open items are resolved. Remaining to confirm during implementation:

1. **Resource floor** — the figures in §10 are a starting estimate; replace with
   the measured values from a first run on representative hardware.
2. **Fork/branch naming** — exact `scm_repo_url` + branch for the public prototype.

## Appendix A — Confirmed realm facts (from `keycloak-post`)

- Realm password policy: `forceExpiredPasswordChange(75) and specialChars(1) and
  passwordHistory(24) and upperCase(1) and lowerCase(1) and length(8) and
  digits(1) and notUsername and regexPattern(no 5 repeated chars)`.
- Realm groups created centrally: `administrators`, `viewers`, `developers`.
- Base job creates only the single horizon admin user (`temporary:true`); user/
  group assignment is otherwise a separate admin task (prod: `tools/users_mgmt`).
