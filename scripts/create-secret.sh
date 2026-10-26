#!/usr/bin/env bash
# Crea (o rota) el Secret de staging/prod FUERA de git, con contraseñas aleatorias:
#   CONFIRM_CONTEXT=<contexto> scripts/create-secret.sh staging|prod
# Si ya existe NO lo reemplaza (rotar a ciegas dejaría a Postgres con una contraseña distinta a la de su volumen).
set -euo pipefail
ENV_NAME=${1:?uso: scripts/create-secret.sh staging|prod}
. "$(dirname "$0")/lib.sh"
need kubectl openssl
[ "$ENV_NAME" != local ] || die "local usa credenciales de demo (components/demo-secrets)"
guard_context
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
if kubectl -n "$NS" get secret vibranium-secrets >/dev/null 2>&1; then info "el Secret ya existe en $NS: no se modifica"; exit 0; fi
kubectl -n "$NS" create secret generic vibranium-secrets \
  --from-literal=password="$(openssl rand -hex 24)" \
  --from-literal=grafana-admin-password="$(openssl rand -hex 16)"
info "creado. La contraseña de Grafana: kubectl -n $NS get secret vibranium-secrets -o jsonpath='{.data.grafana-admin-password}' | base64 -d"
