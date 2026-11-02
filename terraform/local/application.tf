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
# Root ArgoCD AppProject + Application for the local developer stack. Points at
# the SAME gitops/ umbrella chart as production; config.local.enabled=true selects
# the local branches (Ingress instead of Gateway, plain secrets, no cloud apps).

resource "kubectl_manifest" "appproject" {
  validate_schema = false

  yaml_body = <<-EOT
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: horizon-sdv
      namespace: ${kubernetes_namespace.core["argocd"].metadata[0].name}
    spec:
      description: "Horizon SDV (local dev)"
      sourceRepos:
      - "*"
      destinations:
      - namespace: "*"
        server: https://kubernetes.default.svc
      clusterResourceWhitelist:
      - group: "*"
        kind: "*"
      namespaceResourceWhitelist:
      - group: "*"
        kind: "*"
  EOT

  depends_on = [helm_release.argocd]
}

resource "kubectl_manifest" "application" {
  validate_schema   = false
  server_side_apply = true
  force_conflicts   = true

  yaml_body = <<-EOT
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: horizon-sdv
      namespace: ${kubernetes_namespace.core["argocd"].metadata[0].name}
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: horizon-sdv
      source:
        repoURL: ${var.scm_repo_url}
        path: ${var.gitops_path}
        targetRevision: ${var.scm_repo_branch}
        helm:
          values: |
            config:
              domain: ${var.base_domain}
              namespacePrefix: ""
              isSubEnvironment: false
              environmentName: "local"
              enableNetworkPolicies: ${var.enable_network_policies}
              # Cloud-only scalars the in-scope templates still dereference; set to
              # empty so the chart renders cleanly (no "<no value>") on the desktop.
              projectID: ""
              region: ""
              zone: ""
              backendBucket: ""
              storageLocation: ""
              nginx:
                image: "nginx"
                tag: "stable"
              versions:
                components:
                  horizoncore: ${jsonencode(var.image_tag)}
              # Locally built image refs. These are the keys the chart actually reads
              # (config.containerImages.* for the apps, config.postjobs.* for the jobs).
              containerImages:
                horizonApi: ${jsonencode(lookup(var.image_overrides, "horizon-api-app", ""))}
                moduleManager: ${jsonencode(lookup(var.image_overrides, "module-manager-app", ""))}
                horizondevelopmentportal: ${jsonencode(lookup(var.image_overrides, "horizon-dev-portal", ""))}
                storageGcsModule: ""
                cloudWorkstationsModule: ""
              postjobs:
                keycloak: ${jsonencode(lookup(var.image_overrides, "keycloak-post", ""))}
                keycloakhorizonapi: ${jsonencode(lookup(var.image_overrides, "keycloak-post-horizon-api", ""))}
                keycloakArgoWorkflows: ${jsonencode(lookup(var.image_overrides, "keycloak-post-argo-workflows", ""))}
                keycloakargocd: ${jsonencode(lookup(var.image_overrides, "keycloak-post-argocd", ""))}
              # Local mode switch consumed by the SAME gitops chart (no copy).
              local:
                enabled: true
                platformUrl: ${local.domain_url}
                issuerUrl: ${local.issuer_url}
                enabledServices: ${jsonencode(var.enabled_services)}
                imagePullPolicy: ${jsonencode(var.image_pull_policy)}
                postgresqlPersistence: ${var.postgresql_persistence}
                argoWorkflowsArchive: ${var.argo_workflows_archive}
                keycloakPostJobs: ${jsonencode(var.keycloak_post_jobs)}
                caConfigMap: horizon-local-ca
                # Self-signed CA (base64 PEM) so horizon-api / portal Go pods trust
                # https://${var.base_domain} when validating/exchanging OIDC tokens.
                caBundleB64: ${base64encode(tls_self_signed_cert.ca.cert_pem)}
                # Developer login users created by the local-only finisher Job.
                devUsers: ${jsonencode(var.dev_users)}
            # SCM wiring. The chart dereferences .Values.scm.* (module-manager reads
            # authMethod). "none" means anonymous git against the public prototype
            # repo and disables the git-cred External Secrets in argo-workflows-init.
            scm:
              type: "github"
              authMethod: "none"
              repoUrl: ${jsonencode(var.scm_repo_url)}
              repoName: ""
              repoOwner: ""
              branch: ${jsonencode(var.scm_repo_branch)}
              username: "git"
      destination:
        server: https://kubernetes.default.svc
      syncPolicy:
        syncOptions:
        - CreateNamespace=true
        automated:
          prune: true
          selfHeal: false
  EOT

  depends_on = [kubectl_manifest.appproject]
}
