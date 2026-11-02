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
# Build the custom Horizon images and load them into the desktop image store so
# the local overlay can use them with imagePullPolicy: IfNotPresent.
# Rancher Desktop (containerd): nerdctl --namespace k8s.io. Docker Desktop: docker.
#
# NOTE: build contexts are each image's Dockerfile directory. If an image needs a
# wider context (e.g. shared sources), adjust CONTEXT_OVERRIDES below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/terraform/modules/sdv-container-images/images"
TAG="${IMAGE_TAG:-local}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}"; }

# logical tag (must match terraform/local image_overrides) -> Dockerfile dir
declare -a IMAGES=(
  "horizon/horizon-dev-portal|horizon-dev-portal/horizon-dev-portal"
  "horizon/horizon-api|horizon-api/horizon-api-app"
  "horizon/module-manager|module-manager/module-manager-app"
  "horizon/keycloak-post|keycloak/keycloak-post"
  "horizon/keycloak-post-horizon-api|keycloak/keycloak-post-horizon-api"
  "horizon/keycloak-post-argo-workflows|keycloak/keycloak-post-argo-workflows"
  "horizon/keycloak-post-argocd|keycloak/keycloak-post-argocd"
)

# Choose build command based on the desktop engine.
CTX="$(kubectl config current-context 2>/dev/null || true)"
BUILD=()
if [[ "$CTX" == "rancher-desktop" ]] && command -v nerdctl >/dev/null 2>&1; then
  BUILD=(nerdctl --namespace k8s.io build)
  log_info "Using nerdctl (containerd namespace k8s.io)."
elif command -v docker >/dev/null 2>&1; then
  BUILD=(docker build)
  log_info "Using docker."
elif command -v nerdctl >/dev/null 2>&1; then
  BUILD=(nerdctl --namespace k8s.io build)
  log_info "Using nerdctl (containerd namespace k8s.io)."
else
  log_err "No container engine found (nerdctl/docker). Cannot build images."
  exit 1
fi

# The portal Dockerfile's `cli` stage does `COPY cli/ ./`, but the Horizon CLI
# sources live in tools/horizon (the legacy docker builder cannot use additional
# build contexts). In production, Terraform stages them via local_file; here we
# mirror tools/horizon into <portal-context>/cli (gitignored) before the build.
stage_portal_cli() {
  local ctx="${IMAGES_DIR}/horizon-dev-portal/horizon-dev-portal"
  local cli_src="${REPO_ROOT}/tools/horizon"
  [[ -d "$ctx" && -d "$cli_src" ]] || return 0
  log_info "Staging Horizon CLI sources into portal context (cli/)."
  rm -rf "${ctx}/cli"
  mkdir -p "${ctx}/cli"
  cp -R "${cli_src}/." "${ctx}/cli/"
}

stage_portal_cli

for entry in "${IMAGES[@]}"; do
  name="${entry%%|*}"
  subdir="${entry##*|}"
  context="${IMAGES_DIR}/${subdir}"
  if [[ ! -f "${context}/Dockerfile" ]]; then
    log_warn "Skipping ${name}: no Dockerfile at ${context}"
    continue
  fi
  log_info "Building ${name}:${TAG}"
  "${BUILD[@]}" -t "${name}:${TAG}" "${context}"
done

log_info "All local images built."
