#!/usr/bin/env bash
# Prueba de humo de la PLATAFORMA (no solo de la app): el tráfico entra por el ingress, el ciclo de órdenes funciona,
# /metrics NO se publica y la observabilidad está conectada (Prometheus ve al order book, las 13 alertas cargadas, Grafana con dashboard).
#   scripts/smoke.sh            (ambiente local por defecto; ENV_NAME=staging ... para otro)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need kubectl curl
API_ADDR=${API_ADDR:-127.0.0.1:$HTTP_PORT}
API_HOST=${API_HOST:-localhost}
GRAFANA_HOST=${GRAFANA_HOST:-grafana.localtest.me}
RUN=$(date +%s)$RANDOM
FAILS=0
pass() { printf '  [OK]    %s\n' "$1"; }
bad()  { printf '  [FALLO] %s\n          obtenido: %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }
has()  { [[ "$2" == *"$3"* ]] && pass "$1" || bad "$1 (se esperaba «$3»)" "$2"; }
api()  { curl -s -m 10 -H "Host: $API_HOST" "http://$API_ADDR$1" "${@:2}"; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: $1" "http://$API_ADDR$2" "${@:3}"; }

echo "1) El tráfico entra por el ingress ($API_HOST -> $API_ADDR)"
for i in $(seq 1 60); do [ "$(code "$API_HOST" /readyz)" = 200 ] && break; sleep 2; done
has "GET /readyz = 200 (el secuenciador está activo)" "$(code "$API_HOST" /readyz)" 200
has "GET /healthz = 200" "$(code "$API_HOST" /healthz)" 200

echo "2) Ciclo de órdenes"
AL=alice-$RUN; BO=bob-$RUN
has "depósito BRL => 204" "$(code "$API_HOST" /deposits -XPOST -d "{\"user_id\":\"$AL\",\"brl\":1000000}")" 204
has "depósito VIB => 204" "$(code "$API_HOST" /deposits -XPOST -d "{\"user_id\":\"$BO\",\"vib\":100}")" 204
has "venta aceptada => 201" "$(code "$API_HOST" /orders -XPOST -d "{\"id\":\"s-$RUN\",\"user_id\":\"$BO\",\"side\":\"SELL\",\"price\":900,\"qty\":4}")" 201
has "compra aceptada => 201" "$(code "$API_HOST" /orders -XPOST -d "{\"id\":\"b-$RUN\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":900,\"qty\":4}")" 201
has "mismo id dos veces => 409 (idempotencia)" "$(code "$API_HOST" /orders -XPOST -d "{\"id\":\"b-$RUN\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":1,\"qty\":1}")" 409
has "id inválido => 400" "$(api /orders -XPOST -d "{\"id\":\"id con espacios\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":1,\"qty\":1}")" invalid_id
has "auditoría: invariantes y conservación" "$(api /audit)" '"ok":true'

echo "3) Superficie expuesta"
has "/metrics NO sale por el ingress (puerto de administración aparte)" "$([ "$(code "$API_HOST" /metrics)" != 200 ] && echo cerrado || echo ABIERTO)" cerrado
has "/debug/pprof NO sale por el ingress" "$([ "$(code "$API_HOST" /debug/pprof/)" != 200 ] && echo cerrado || echo ABIERTO)" cerrado

echo "4) Observabilidad conectada (consulta a Prometheus dentro del cluster)"
T=$(k exec prometheus-0 -- wget -qO- http://localhost:9090/api/v1/targets 2>&1)
has "Prometheus ve al order book (target up)" "$T" '"health":"up"'
R=$(k exec prometheus-0 -- wget -qO- http://localhost:9090/api/v1/rules 2>&1)
N=$(grep -o '"type":"alerting"' <<<"$R" | wc -l | tr -d ' ')
[ "$N" = 13 ] && pass "13 alertas cargadas" || bad "13 alertas cargadas" "$N"
has "Grafana saludable por el ingress" "$(curl -s -m 10 -H "Host: $GRAFANA_HOST" "http://$API_ADDR/api/health")" '"database": "ok"'
has "dashboard provisionado" "$(curl -s -m 10 -H "Host: $GRAFANA_HOST" "http://$API_ADDR/api/search?query=Order")" orderbook-overview

echo
[ "$FAILS" = 0 ] && { echo "SMOKE OK"; exit 0; } || { echo "SMOKE: $FAILS fallos"; exit 1; }
