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
# ingress-nginx replaces the GKE Gateway API locally. On Rancher Desktop the
# bundled Traefik must be disabled first (deploy.sh --local / bootstrap handles
# that) so ports 80/443 are free.

resource "kubernetes_namespace" "ingress" {
  metadata {
    name = local.ingress_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "horizon-local"
    }
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  # Controller v1.15.1; supported k8s 1.31-1.35 (Docker Desktop ships 1.36 — one
  # minor beyond the tested matrix but the stable Ingress v1 API works; pin bumped
  # from 4.11.3 whose matrix stopped at 1.30).
  version   = "4.15.1"
  namespace = kubernetes_namespace.ingress.metadata[0].name
  wait      = true

  values = [
    yamlencode({
      controller = {
        # Single desktop node; one replica is enough.
        replicaCount = 1
        service = {
          # Docker/Rancher Desktop map a LoadBalancer to localhost (127.0.0.1).
          # The stack is localhost-only by design (weak dev creds); do not expose
          # this service on 0.0.0.0 or via a tunnel.
          type = "LoadBalancer"
        }
        # Default TLS cert for all hosts without their own secret.
        extraArgs = {
          default-ssl-certificate = "${local.ingress_namespace}/horizon-local-tls"
        }
        # Portal proxy can stream workflow logs; raise proxy timeouts.
        config = {
          "proxy-read-timeout"    = "3600"
          "proxy-send-timeout"    = "3600"
          "proxy-body-size"       = "256m"
          "use-forwarded-headers" = "true"
        }
      }
    })
  ]
}
