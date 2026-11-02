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
# Deploy the minimal LOCAL Horizon prototype onto the desktop Kubernetes built
# into Rancher Desktop or Docker Desktop. Targets terraform/local (local state,
# no GCP). Invoked via `./deploy.sh --local` or directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/local"

# Only these kube contexts are ever allowed for the local prototype.
ALLOWED_CONTEXTS=("rancher-desktop" "docker-desktop")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; }

MODE="apply"
SKIP_BUILD="false"
SKIP_BOOTSTRAP="false"

usage() {
  cat <<EOF

Horizon local developer prototype.

Usage:
  ./deploy.sh --local [OPTION]
  ./deploy-local.sh [OPTION]

Options:
  -p, --plan          Terraform plan only
  -a, --apply         Terraform apply (default)
  -d, --destroy       Terraform destroy
      --skip-build    Do not (re)build local images
      --skip-bootstrap Do not run cluster bootstrap (ingress-nginx, Traefik, CoreDNS, hosts)
  -h, --help          This help

This targets desktop Kubernetes ONLY (contexts: ${ALLOWED_CONTEXTS[*]}).
It never authenticates to or deploys on GCP.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--plan) MODE="plan" ;;
      -a|--apply) MODE="apply" ;;
      -d|--destroy) MODE="destroy" ;;
      --skip-build) SKIP_BUILD="true" ;;
      --skip-bootstrap) SKIP_BOOTSTRAP="true" ;;
      -h|--help) usage; exit 0 ;;
      *) log_err "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done
}

# Refuse to run against anything that is not the developer's desktop cluster.
local_context_gate() {
  if ! command -v kubectl >/dev/null 2>&1; then
    log_err "kubectl not found on PATH."
    exit 1
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "$ctx" ]]; then
    log_err "No current kubectl context. Start Rancher/Docker Desktop Kubernetes."
    exit 1
  fi
  local ok="false"
  for a in "${ALLOWED_CONTEXTS[@]}"; do
    [[ "$ctx" == "$a" ]] && ok="true"
  done
  if [[ "$ok" != "true" ]]; then
    log_err "Refusing to run: current context is '${ctx}'."
    log_err "The local prototype only runs on: ${ALLOWED_CONTEXTS[*]}."
    log_err "Switch with: kubectl config use-context rancher-desktop"
    exit 1
  fi
  log_info "Local context verified: ${ctx}"
}

check_requirements() {
  command -v terraform >/dev/null 2>&1 || { log_err "terraform not found."; exit 1; }
  command -v kubectl >/dev/null 2>&1 || { log_err "kubectl not found."; exit 1; }
  if ! command -v nerdctl >/dev/null 2>&1 \
     && ! command -v docker >/dev/null 2>&1 \
     && ! command -v rdctl >/dev/null 2>&1; then
    log_warn "No container engine (nerdctl/docker/rdctl) found; --skip-build required."
  fi
}

ensure_tfvars() {
  if [[ ! -f "${TF_DIR}/terraform.tfvars" ]]; then
    log_err "Missing ${TF_DIR}/terraform.tfvars"
    log_err "Copy terraform.tfvars.sample to terraform.tfvars and set scm_repo_url."
    exit 1
  fi
}

run_terraform() {
  cd "${TF_DIR}"
  log_info "terraform init (local backend)"
  terraform init -input=false

  case "$MODE" in
    plan)
      log_info "terraform plan"
      terraform plan
      ;;
    destroy)
      log_warn "!!! DESTROY (local) !!!"
      terraform destroy -auto-approve
      ;;
    apply)
      log_info "terraform apply"
      terraform apply -auto-approve
      log_info "Done. Open https://$(terraform output -raw base_domain 2>/dev/null || echo horizon.local)/developer-portal"
      ;;
  esac
}

main() {
  parse_args "$@"
  log_warn "Local prototype: default dev credentials, bound to 127.0.0.1 only."
  log_warn "Do NOT expose these services on 0.0.0.0 or via a tunnel."

  local_context_gate
  check_requirements
  ensure_tfvars

  if [[ "$MODE" != "destroy" ]]; then
    if [[ "$SKIP_BOOTSTRAP" != "true" ]]; then
      log_info "Bootstrapping cluster (Traefik off, CoreDNS rewrite, hosts)"
      bash "${SCRIPT_DIR}/bootstrap-local.sh"
    fi
    if [[ "$SKIP_BUILD" != "true" ]]; then
      log_info "Building local images"
      bash "${SCRIPT_DIR}/build-local-images.sh"
    fi
  fi

  run_terraform
}

main "$@"
