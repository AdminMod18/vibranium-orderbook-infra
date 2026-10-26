#!/usr/bin/env bash
# Construye la imagen de la app desde el repo hermano y la carga en kind (sin registro). APP_DIR cambia la ruta del repo de la app.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need docker kind
APP_DIR=${APP_DIR:-$ROOT/../vibranium-orderbook-meli}
[ -f "$APP_DIR/Dockerfile" ] || die "no encuentro el repo de la app en '$APP_DIR' (clónelo al lado o defina APP_DIR=ruta)"
IMAGE=${IMAGE:-vibranium-orderbook-meli:dev}
info "construyendo $IMAGE desde $APP_DIR"
docker build -t "$IMAGE" "$APP_DIR"
info "cargando la imagen en el cluster '$CLUSTER'"
kind load docker-image "$IMAGE" --name "$CLUSTER"
