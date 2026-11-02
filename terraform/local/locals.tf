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

locals {
  # Public base URL used for OIDC issuer, redirect URIs and in-cluster discovery.
  # Path-based routing under a single host, matching production keycloak-post jobs.
  domain_url = "https://${var.base_domain}"
  issuer_url = "${local.domain_url}/auth/realms/horizon"

  # Namespaces terraform must create BEFORE ArgoCD syncs, so dev Secrets can be
  # pre-seeded. ArgoCD (namespaces.yaml in the gitops chart) also declares these and
  # adopts them. All other namespaces — including the "jenkins" namespace that
  # keycloak-post-horizon-api/configure.sh writes the CI secret into (wave 0, before
  # the post jobs at wave 4-5) — are created by the gitops chart, so there is no
  # separate stub here.
  core_namespaces = [
    "argocd",
    "keycloak",
  ]

  # ingress-nginx TLS secret (self-signed) lives in this namespace.
  ingress_namespace = "ingress-nginx"
}
