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
# Plain Kubernetes Secrets that replace External Secrets + GCP Secret Manager.
# All seeded from dev_password (localhost-only). PostgreSQL gets a random pw.
#
# NOTE: secret key names mirror what the gitops templates expect
# (gitops/templates/keycloak.yaml: keycloak-initial-creds.password,
# database.existingSecret = postgresql-initial-creds). These replace the Secrets
# that gitops/templates/keycloak-init.yaml creates in cloud mode (that whole file
# is gated off when config.local.enabled is true).

resource "random_password" "postgres" {
  length  = 24
  special = false
}

# Keycloak master admin password (KEYCLOAK_ADMIN_PASSWORD).
resource "kubernetes_secret" "keycloak_initial_creds" {
  metadata {
    name      = "keycloak-initial-creds"
    namespace = kubernetes_namespace.core["keycloak"].metadata[0].name
  }
  data = {
    password = var.dev_password
  }
}

# PostgreSQL credentials consumed by Keycloak (database.existingSecret).
resource "kubernetes_secret" "postgresql_initial_creds" {
  metadata {
    name      = "postgresql-initial-creds"
    namespace = kubernetes_namespace.core["keycloak"].metadata[0].name
  }
  data = {
    # keycloakx chart reads "password"; the postgres chart reads its own keys too.
    password            = random_password.postgres.result
    "postgres-password" = random_password.postgres.result
    username            = "dbusername"
  }
}

# Keycloak bootstrap admin user consumed by keycloak-post (HORIZON_ADMIN_*).
resource "kubernetes_secret" "keycloak_horizon_admin" {
  metadata {
    name      = "keycloak-horizon-admin"
    namespace = kubernetes_namespace.core["keycloak"].metadata[0].name
  }
  data = {
    username = "horizon-admin"
    password = var.dev_password
  }
}

# ArgoCD realm user consumed by keycloak-post-argocd (ARGOCD_ADMIN_*).
resource "kubernetes_secret" "keycloak_argocd_admin" {
  metadata {
    name      = "keycloak-argocd-admin"
    namespace = kubernetes_namespace.core["keycloak"].metadata[0].name
  }
  data = {
    username = "argocd-admin"
    password = var.dev_password
  }
}

# --- Self-signed CA for in-cluster OIDC trust (injection) -------------------
# Distributed into namespaces whose pods validate OIDC/JWKS server-side against
# https://<base_domain>/auth. Referenced by the gitops chart (local mode) via
# NODE_EXTRA_CA_CERTS / SSL_CERT_FILE mounts and by ArgoCD oidc.config.rootCA.
resource "kubernetes_config_map" "ca_bundle" {
  for_each = toset(["argocd", "keycloak"])

  metadata {
    name      = "horizon-local-ca"
    namespace = kubernetes_namespace.core[each.key].metadata[0].name
  }
  data = {
    "ca.crt" = tls_self_signed_cert.ca.cert_pem
  }
}
