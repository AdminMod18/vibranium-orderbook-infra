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
