#!/usr/bin/env bash

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
# Prepare the desktop cluster for the local prototype:
#   1. On Rancher Desktop (k3s): disable the bundled Traefik so ports 80/443 are
#      free for ingress-nginx.
#   2. Add a CoreDNS rewrite so <base_domain> resolves to ingress-nginx INSIDE the
#      cluster (so pods can reach the Keycloak OIDC issuer).
#   3. Install inert Config Connector (KCC) CRD stubs so the real, unmodified
#      Module Manager modules can apply their *.cnrm.cloud.google.com resources.
#      CRDs only -- NO controller -- so the CRs provision nothing; an ArgoCD health
#      override (terraform/local/argocd.tf) reports them Healthy. This lets
#      production MM be developed on the local cluster without a GCP project.
#   4. Ensure the host maps <base_domain> to 127.0.0.1.
# Idempotent; safe to re-run. ingress-nginx itself is installed by Terraform.
#
# Env overrides:
#   KCC_VERSION     Config Connector release tag for the CRD stubs (default below).
#   SKIP_KCC_CRDS=1 Skip installing the KCC CRD stubs (cloud modules will not sync).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/local"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}"; }

# Read base_domain from tfvars if present, else default.
BASE_DOMAIN="horizon.local"
if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
  v="$(grep -E '^\s*base_domain\s*=' "${TF_DIR}/terraform.tfvars" | head -1 | cut -d'"' -f2 || true)"
  [[ -n "$v" ]] && BASE_DOMAIN="$v"
fi

INGRESS_SVC_FQDN="ingress-nginx-controller.ingress-nginx.svc.cluster.local"
CTX="$(kubectl config current-context 2>/dev/null || true)"

# Config Connector release tag whose CRD definitions we install as inert stubs.
KCC_VERSION="${KCC_VERSION:-v1.160.0}"
KCC_CRD_BASE="https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-config-connector/${KCC_VERSION}/config/crds/resources"
# Exactly the cnrm kinds referenced by gitops/modules (keep in sync with the catalog).
# Each entry is a CRD filename under config/crds/resources in the KCC repo.
KCC_CRDS=(
  "apiextensions.k8s.io_v1_customresourcedefinition_computefirewalls.compute.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_containernodepools.container.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_dnsmanagedzones.dns.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_dnsrecordsets.dns.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_iampolicymembers.iam.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_iamserviceaccounts.iam.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_pubsubtopics.pubsub.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_secretmanagersecrets.secretmanager.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_services.serviceusage.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_spannerdatabases.spanner.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_spannerinstances.spanner.cnrm.cloud.google.com.yaml"
  "apiextensions.k8s.io_v1_customresourcedefinition_storagebuckets.storage.cnrm.cloud.google.com.yaml"
)

disable_traefik() {
  if [[ "$CTX" != "rancher-desktop" ]]; then
    return 0
  fi
  if kubectl -n kube-system get deploy traefik >/dev/null 2>&1 \
     || kubectl -n kube-system get helmchart traefik >/dev/null 2>&1; then
    log_warn "Rancher Desktop Traefik detected; removing it to free 80/443."
    kubectl -n kube-system delete helmchart traefik --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n kube-system delete deploy traefik --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n kube-system delete svc traefik --ignore-not-found >/dev/null 2>&1 || true
    log_warn "Also UNCHECK Traefik in Rancher Desktop > Preferences > Kubernetes"
    log_warn "to stop k3s recreating it on restart."
  else
    log_info "Traefik not present; nothing to disable."
  fi
}

patch_coredns() {
  # Add a rewrite entry so <base_domain> → ingress-nginx inside the cluster.
  if kubectl -n kube-system get configmap coredns >/dev/null 2>&1; then
    if kubectl -n kube-system get configmap coredns -o yaml | grep -q "rewrite name ${BASE_DOMAIN}"; then
      log_info "CoreDNS rewrite for ${BASE_DOMAIN} already present."
      return 0
    fi
    log_info "Adding CoreDNS rewrite: ${BASE_DOMAIN} -> ${INGRESS_SVC_FQDN}"
    # Insert the rewrite line after the first opening brace of the server block.
    local current new
    current="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
    new="$(awk -v d="${BASE_DOMAIN}" -v t="${INGRESS_SVC_FQDN}" '
      NR==1 && /\{/ { print; print "    rewrite name " d " " t; next } { print }
    ' <<<"$current")"
    kubectl -n kube-system create configmap coredns \
      --from-literal=Corefile="$new" --dry-run=client -o yaml \
      | kubectl -n kube-system apply -f - >/dev/null
    kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
    log_warn "Review the CoreDNS Corefile if DNS misbehaves (kube-system/coredns)."
  else
    log_warn "No 'coredns' configmap in kube-system; skipping (adjust for your CNI)."
  fi
}

install_kcc_crd_stubs() {
  # Install Config Connector CRDs ONLY (no operator/controller) so the real Module
  # Manager modules can apply their *.cnrm.cloud.google.com resources locally. The
  # CRs stay statusless (inert); ArgoCD treats them Healthy via a local health override.
  if [[ "${SKIP_KCC_CRDS:-0}" == "1" ]]; then
    log_warn "SKIP_KCC_CRDS=1; skipping KCC CRD stubs (cloud modules will not sync)."
    return 0
  fi
  log_info "Installing inert KCC CRD stubs (${KCC_VERSION}, CRDs only, no controller)."
  local f url tmp failed=0
  tmp="$(mktemp -d)"
  for f in "${KCC_CRDS[@]}"; do
    url="${KCC_CRD_BASE}/${f}"
    if ! curl -fsSL -o "${tmp}/${f}" "${url}"; then
      log_warn "Could not download ${f}; skipping."
      failed=1
      continue
    fi
  done
  if ! kubectl apply -f "${tmp}" >/dev/null 2>&1; then
    # Fall back to server-side apply; KCC CRD schemas can exceed the client-side
    # last-applied-configuration annotation size limit.
    kubectl apply --server-side -f "${tmp}" >/dev/null 2>&1 || failed=1
  fi
  rm -rf "${tmp}"
  if [[ "$failed" == "0" ]]; then
    log_info "KCC CRD stubs installed (${#KCC_CRDS[@]} CRDs)."
  else
    log_warn "Some KCC CRD stubs failed; cloud modules may not sync. Re-run with network."
  fi
}

ensure_hosts_entry() {
  if grep -qE "^[^#]*\b${BASE_DOMAIN}\b" /etc/hosts 2>/dev/null; then
    log_info "/etc/hosts already maps ${BASE_DOMAIN}."
    return 0
  fi
  log_info "Adding '127.0.0.1 ${BASE_DOMAIN}' to /etc/hosts (sudo)."
  if printf '127.0.0.1 %s\n' "${BASE_DOMAIN}" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
    log_info "Host entry added."
  else
    log_warn "Could not edit /etc/hosts. Add this line manually:"
    log_warn "  127.0.0.1 ${BASE_DOMAIN}"
    log_warn "(On WSL also add it to the Windows hosts file.)"
  fi
}

main() {
  log_info "Bootstrapping local cluster for ${BASE_DOMAIN} (context: ${CTX})"
  disable_traefik
  patch_coredns
  install_kcc_crd_stubs
  ensure_hosts_entry
  log_info "Bootstrap complete."
}

main "$@"
