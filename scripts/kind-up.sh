#!/usr/bin/env bash
# Crea el cluster kind (si no existe) e instala ingress-nginx. Idempotente. HTTP_PORT cambia el puerto del host (8080).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need docker kind kubectl
cd "$ROOT"
need_free_gb

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  info "el cluster '$CLUSTER' ya existe (no se toca)"
else
  info "creando cluster '$CLUSTER' (puerto del host: $HTTP_PORT)"
  sed "s/hostPort: 8080/hostPort: $HTTP_PORT/" kind/cluster.yaml | kind create cluster --config -
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

info "instalando ingress-nginx (versión fijada)"
for i in 1 2 3; do kubectl apply -k platform/ingress-nginx && break || { sleep 5; [ "$i" = 3 ] && die "no se pudo aplicar ingress-nginx"; }; done
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=240s
info "listo. Siguiente: scripts/build-image.sh  y  scripts/deploy.sh local"
