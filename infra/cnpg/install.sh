#!/usr/bin/env bash
# infra/cnpg/install.sh
# Install CloudNativePG operator v1.25.1.
# Idempotent — safe to re-run.

set -euo pipefail

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}==>${NC} $*"; }

info "Installing CloudNativePG operator v1.25.1..."
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml

info "Waiting for CNPG controller manager to be ready..."
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=300s

# NOTE: cnpg-system is NOT enrolled in Istio Ambient mesh.
# CNPG manages its own TLS for streaming replication and the operator's webhook
# must be reachable by kube-apiserver (which is outside the mesh).

info "CloudNativePG operator installed successfully."
