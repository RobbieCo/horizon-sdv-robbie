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
# Self-signed TLS for https://<base_domain>. A local CA signs a server cert for
# the host. The browser will warn (accepted); in-cluster OIDC clients trust the
# CA via injection (see ca-injection resources). No mkcert dependency.

# --- Local CA ---------------------------------------------------------------

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  is_ca_certificate     = true
  validity_period_hours = 8760 # 1 year

  subject {
    common_name  = "Horizon Local Dev CA"
    organization = "Horizon SDV (local)"
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# --- Server cert for base_domain --------------------------------------------

resource "tls_private_key" "server" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name  = var.base_domain
    organization = "Horizon SDV (local)"
  }

  dns_names = [
    var.base_domain,
    "*.${var.base_domain}",
  ]
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem   = tls_cert_request.server.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# --- Ingress TLS secret (server cert + CA chain) ----------------------------

resource "kubernetes_secret" "ingress_tls" {
  metadata {
    name      = "horizon-local-tls"
    namespace = local.ingress_namespace
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = "${tls_locally_signed_cert.server.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
    "tls.key" = tls_private_key.server.private_key_pem
  }

  depends_on = [helm_release.ingress_nginx]
}
