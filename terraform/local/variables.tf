# Copyright (c) 2026 Accenture, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# --- Cluster / kube context -------------------------------------------------

variable "kube_context" {
  description = "kubeconfig context for the desktop cluster. Only rancher-desktop or docker-desktop are allowed (deploy.sh --local enforces this too)."
  type        = string
  default     = "rancher-desktop"

  validation {
    condition     = contains(["rancher-desktop", "docker-desktop"], var.kube_context)
    error_message = "kube_context must be 'rancher-desktop' or 'docker-desktop' for the local prototype."
  }
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file."
  type        = string
  default     = "~/.kube/config"
}

# --- Hostname / routing -----------------------------------------------------

variable "base_domain" {
  description = "Single host that all services are served under. Must resolve to 127.0.0.1 on the host and (via CoreDNS rewrite) to ingress-nginx inside the cluster."
  type        = string
  default     = "horizon.local"
}

# --- GitOps source (ArgoCD pulls the trimmed overlay) -----------------------

variable "scm_repo_url" {
  description = "Git repository URL ArgoCD pulls the local overlay from."
  type        = string
}

variable "scm_repo_branch" {
  description = "Branch ArgoCD tracks for the local overlay."
  type        = string
  default     = "horizon-local-development-mode"
}

variable "gitops_path" {
  description = "Path within the repo to the GitOps umbrella chart. Same chart as production; the local path is selected via config.local.enabled in the ArgoCD Application values (no separate copy)."
  type        = string
  default     = "gitops"
}

# --- Images -----------------------------------------------------------------

variable "image_tag" {
  description = "Tag applied to locally built images."
  type        = string
  default     = "local"
}

variable "image_pull_policy" {
  description = "imagePullPolicy for locally built images (IfNotPresent so the desktop image store is used)."
  type        = string
  default     = "IfNotPresent"
}

variable "image_overrides" {
  description = "Map of logical image name to the local image reference (name:tag) loaded into the desktop image store."
  type        = map(string)
  default = {
    horizon-dev-portal           = "horizon/horizon-dev-portal:local"
    horizon-api-app              = "horizon/horizon-api:local"
    module-manager-app           = "horizon/module-manager:local"
    keycloak-post                = "horizon/keycloak-post:local"
    keycloak-post-horizon-api    = "horizon/keycloak-post-horizon-api:local"
    keycloak-post-argo-workflows = "horizon/keycloak-post-argo-workflows:local"
    keycloak-post-argocd         = "horizon/keycloak-post-argocd:local"
  }
}

# --- Services ---------------------------------------------------------------

variable "enabled_services" {
  description = "Services the local overlay deploys. Fixed scope but toggleable."
  type        = list(string)
  default     = ["keycloak", "argocd", "horizon-api", "module-manager", "argo-workflows", "portal"]
}

# --- Dev credentials (localhost-only; realm-policy compliant) ---------------

variable "dev_password" {
  description = "Single standard password used for Keycloak admin, the horizon realm admin, ArgoCD admin, and the seeded dev users. Must satisfy the realm password policy."
  type        = string
  default     = "Horizon@123"
  sensitive   = true
}

variable "dev_users" {
  description = "Static dev users seeded into the horizon realm by the local-only finisher Job. Groups must be realm groups created by the base keycloak-post job (administrators/viewers/developers)."
  type = list(object({
    username = string
    groups   = list(string)
  }))
  default = [
    { username = "admin", groups = ["administrators"] },
    { username = "developer", groups = ["developers"] },
  ]
}

# --- Local behaviour toggles (differ from prod defaults) --------------------

variable "enable_network_policies" {
  description = "Keep false locally; desktop CNIs often do not enforce NetworkPolicy and the prod policies reference out-of-scope namespaces."
  type        = bool
  default     = false
}

variable "argo_workflows_archive" {
  description = "Artifact archiving. False locally (no GCS backend)."
  type        = bool
  default     = false
}

variable "keycloak_post_jobs" {
  description = "Subset of production keycloak-post-* jobs reused locally (by logical name)."
  type        = list(string)
  default     = ["base", "horizon-api", "argo-workflows", "argocd"]
}

variable "postgresql_persistence" {
  description = "Use a PVC for Keycloak's PostgreSQL so realm/users survive restarts (k3s local-path)."
  type        = bool
  default     = true
}
