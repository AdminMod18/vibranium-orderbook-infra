#!/usr/bin/env bash
# Construye la imagen de la app desde el repo hermano y la carga en kind (sin registro). APP_DIR cambia la ruta del repo de la app.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need docker kind
APP_DIR=${APP_DIR:-$ROOT/../vibranium-orderbook-meli}
[ -f "$APP_DIR/Dockerfile" ] || die "no encuentro el repo de la app en '$APP_DIR' (clónelo al lado o defina APP_DIR=ruta)"
APP_DIR=$(cd "$APP_DIR" && pwd)                       # ruta normalizada (sin "..")
# En Git Bash (Windows), docker.exe NO entiende rutas tipo /c/Users/...: se le pasa la ruta en formato Windows (C:/Users/...).
if command -v cygpath >/dev/null 2>&1; then APP_BUILD=$(cygpath -m "$APP_DIR"); else APP_BUILD=$APP_DIR; fi
IMAGE=${IMAGE:-vibranium-orderbook-meli:dev}
info "construyendo $IMAGE desde $APP_DIR"
docker build -t "$IMAGE" "$APP_BUILD"
info "cargando la imagen en el cluster '$CLUSTER'"
kind load docker-image "$IMAGE" --name "$CLUSTER"
