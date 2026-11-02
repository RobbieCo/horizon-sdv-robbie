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

output "base_domain" {
  description = "Host the stack is served under."
  value       = var.base_domain
}

output "urls" {
  description = "Service URLs."
  value = {
    portal         = "${local.domain_url}/developer-portal"
    horizon_api    = "${local.domain_url}/horizon-api"
    argocd         = "${local.domain_url}/argocd"
    argo_workflows = "${local.domain_url}/workflows"
    keycloak       = "${local.domain_url}/auth"
  }
}

output "oidc_issuer" {
  description = "Keycloak OIDC issuer."
  value       = local.issuer_url
}

output "ca_certificate_pem" {
  description = "Self-signed CA. Trust this on the host to silence browser warnings (optional)."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "dev_login_hint" {
  description = "Local dev login."
  value       = "users: ${join(", ", [for u in var.dev_users : u.username])} | password: (dev_password)"
}
