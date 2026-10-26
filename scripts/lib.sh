#!/usr/bin/env bash
# Utilidades comunes. Se carga con:  . "$(dirname "$0")/lib.sh"
export MSYS_NO_PATHCONV=1          # Git Bash (Windows) convertiría los argumentos que empiezan por "/" en rutas de Windows
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=${CLUSTER:-vibranium}
ENV_NAME=${ENV_NAME:-local}
NS="vibranium-${ENV_NAME}"
HTTP_PORT=${HTTP_PORT:-8080}

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "falta '$c' en el PATH (ver README §Requisitos)"; done; }
k()    { kubectl -n "$NS" "$@"; }

# Contexto de kubectl: el ambiente `local` SOLO se despliega en el cluster kind de este repo;
# cualquier otro exige confirmar explícitamente el contexto (evita aplicar cambios al cluster equivocado).
guard_context() {
  local ctx; ctx=$(kubectl config current-context 2>/dev/null) || die "kubectl sin contexto activo"
  if [ "$ENV_NAME" = local ]; then
    [ "$ctx" = "kind-$CLUSTER" ] || die "el contexto activo es '$ctx', no 'kind-$CLUSTER'. Ejecute scripts/kind-up.sh o 'kubectl config use-context kind-$CLUSTER'"
  else
    [ "${CONFIRM_CONTEXT:-}" = "$ctx" ] || die "va a tocar el ambiente '$ENV_NAME' en el contexto '$ctx'. Confirme con: CONFIRM_CONTEXT=$ctx $0 ..."
  fi
}

# Espacio libre en el disco donde vive el repo (en Docker Desktop/WSL2 el disco virtual de Docker crece sobre ESTE disco: si se llena,
# el motor se cuelga y el cluster deja de responder). El disco virtual NO lo ve: Grafana puede mostrar cientos de GiB libres con 0 bytes reales.
need_free_gb() {
  local min=${MIN_FREE_GB:-20} free
  [ -n "${CI:-}" ] && return 0                      # los runners de CI son efímeros
  free=$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')
  [ -n "$free" ] || return 0
  [ "$free" -ge "$min" ] || die "solo quedan ${free} GiB libres en el disco (mínimo ${min}). Una corrida de carga genera varios GiB (journal + Postgres + métricas) y con el disco lleno Docker se cuelga. Libere espacio, o defina MIN_FREE_GB=<n> bajo su responsabilidad."
}
