#!/usr/bin/env bash
# Aplica un ambiente:  scripts/deploy.sh local|staging|prod   (staging/prod: CONFIRM_CONTEXT=<contexto> scripts/deploy.sh prod)
set -euo pipefail
ENV_NAME=${1:?uso: scripts/deploy.sh local|staging|prod}
. "$(dirname "$0")/lib.sh"
need kubectl
cd "$ROOT"
[ -d "overlays/$ENV_NAME" ] || die "no existe overlays/$ENV_NAME"
guard_context
if [ "$ENV_NAME" != local ]; then
  kubectl get secret vibranium-secrets -n "$NS" >/dev/null 2>&1 || die "falta el Secret 'vibranium-secrets' en $NS: scripts/create-secret.sh $ENV_NAME"
fi

info "aplicando overlays/$ENV_NAME (namespace $NS)"
# El webhook de admisión de ingress-nginx puede tardar unos segundos tras instalarse: se reintenta.
for i in 1 2 3 4; do kubectl apply -k "overlays/$ENV_NAME" && break || { [ "$i" = 4 ] && die "falló kubectl apply"; sleep 8; }; done

info "esperando a que todo esté listo"
k rollout status statefulset/postgres   --timeout=240s
k rollout status statefulset/orderbook  --timeout=420s
k rollout status statefulset/prometheus --timeout=180s
k rollout status deployment/grafana     --timeout=180s
k rollout status deployment/kube-state-metrics --timeout=180s
k get pods,svc,ingress,pvc
