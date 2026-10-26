#!/usr/bin/env bash
# Validación ESTÁTICA (no necesita cluster): cada overlay debe compilar con kustomize, cumplir el esquema de Kubernetes
# (kubeconform) y respetar las políticas del repo (scripts/policy.py). Es lo que corre el CI en cada push.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need kubectl kubeconform python3
cd "$ROOT"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
for env in $(ls overlays); do
  info "overlay $env"
  kubectl kustomize "overlays/$env" > "$OUT/$env.yaml"
  kubeconform -strict -summary -kubernetes-version "${K8S_VERSION:-1.31.0}" "$OUT/$env.yaml"
  python3 scripts/policy.py "$env" "$OUT/$env.yaml"
done
info "todo válido"
