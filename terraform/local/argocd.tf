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
#
# Description:
# ArgoCD for the local overlay. No External Secrets. Admin password = dev_password.
# The self-signed CA is registered in argocd-tls-certs-cm so argocd-server trusts
# the Keycloak issuer (https://<base_domain>/auth) without editing the reused
# keycloak-post-argocd job (which patches oidc.config but not rootCA).

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"
  namespace  = kubernetes_namespace.core["argocd"].metadata[0].name
  wait       = true

  values = [
    yamlencode({
      global = {
        domain = var.base_domain
      }
      configs = {
        params = {
          "server.insecure" = true
          "server.rootpath" = "/argocd"
          # Parity with production (sdv-gke-apps argocd-values.yaml.tpl): GitHub HTTPS
          # from the cluster can be slow/stall; raise git + repo-server timeouts so the
          # gitops chart and Module Manager modules sync instead of "context deadline
          # exceeded" in repo-server.
          "reposerver.git.request.timeout"         = "120s"
          "server.repo.server.timeout.seconds"     = "180"
          "controller.repo.server.timeout.seconds" = "180"
        }
        cm = {
          url = "${local.domain_url}/argocd"
          # Local-only stub: Config Connector (KCC) CRDs are installed WITHOUT the
          # controller (see bootstrap-local.sh), so *.cnrm.cloud.google.com resources
          # apply but never get a status and would otherwise sit "Progressing" forever.
          # Report them Healthy so the real (unmodified) Module Manager modules sync
          # end-to-end and production MM can be developed on the local cluster.
          # These CRs provision nothing locally. Wildcard GVK health requires the
          # monolithic resource.customizations key (quoted because it starts with '*').
          "resource.customizations" = <<EOT
"*.cnrm.cloud.google.com/*":
  health.lua: |
    hs = {}
    hs.status = "Healthy"
    hs.message = "Local stub: Config Connector controller not installed; resource is inert."
    return hs
EOT

        }
        # Admin login with dev_password (bcrypt). Keycloak OIDC is layered on by
        # the reused keycloak-post-argocd job.
        secret = {
          argocdServerAdminPassword      = bcrypt(var.dev_password)
          argocdServerAdminPasswordMtime = "2026-01-01T00:00:00Z"
        }
        # Trust the self-signed CA for the Keycloak host (server-side OIDC).
        tls = {
          certificates = {
            (var.base_domain) = tls_self_signed_cert.ca.cert_pem
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_config_map.ca_bundle,
    helm_release.ingress_nginx,
  ]
}

# Repository credentials so ArgoCD can pull the (public) prototype branch.
# Public repo: no secret needed. Left as a placeholder for private forks.
