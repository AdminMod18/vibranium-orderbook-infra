#!/usr/bin/env bash
# Elimina el cluster kind y, con él, sus volúmenes. Pide confirmación (es destructivo): CONFIRM=yes para omitirla.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need kind
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || { info "no existe el cluster '$CLUSTER'"; exit 0; }
if [ "${CONFIRM:-}" != yes ]; then read -r -p "Esto BORRA el cluster '$CLUSTER' y los datos (journal, historial). Escriba 'yes': " a; [ "$a" = yes ] || die "cancelado"; fi
kind delete cluster --name "$CLUSTER"
