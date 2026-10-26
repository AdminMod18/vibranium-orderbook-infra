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
T=""; for _ in $(seq 1 30); do   # el primer scrape tarda unos segundos tras arrancar Prometheus
  T=$(k exec prometheus-0 -- wget -qO- http://localhost:9090/api/v1/targets 2>&1); [[ "$T" == *'"health":"up"'* ]] && break; sleep 2; done
has "Prometheus ve al order book (target up)" "$T" '"health":"up"'
R=$(k exec prometheus-0 -- wget -qO- http://localhost:9090/api/v1/rules 2>&1)
N=$(grep -o '"type":"alerting"' <<<"$R" | wc -l | tr -d ' ')
[ "$N" = 13 ] && pass "13 alertas cargadas" || bad "13 alertas cargadas" "$N"
has "Grafana saludable por el ingress" "$(curl -s -m 10 -H "Host: $GRAFANA_HOST" "http://$API_ADDR/api/health")" '"database": "ok"'
has "dashboard de la app provisionado" "$(curl -s -m 10 -H "Host: $GRAFANA_HOST" "http://$API_ADDR/api/search?query=Order")" orderbook-overview
has "dashboard de la plataforma provisionado" "$(curl -s -m 10 -H "Host: $GRAFANA_HOST" "http://$API_ADDR/api/search?query=Plataforma")" plataforma-k8s
# Cada métrica que usa el dashboard de plataforma debe EXISTIR en Prometheus (si no, el panel mostraría "No data").
prom_has() {  # $1 = consulta PromQL sin caracteres especiales; espera hasta 60 s al primer scrape
  local r=""; for _ in $(seq 1 30); do
    r=$(k exec prometheus-0 -- wget -qO- "http://localhost:9090/api/v1/query?query=$1" 2>&1)
    [[ "$r" == *'"result":[{'* ]] && return 0; sleep 2; done; return 1; }
for m in up nginx_ingress_controller_requests nginx_ingress_controller_request_duration_seconds_count \
         nginx_ingress_controller_nginx_process_connections process_start_time_seconds process_cpu_seconds_total \
         process_resident_memory_bytes process_open_fds go_goroutines orderbook_http_requests_total; do
  prom_has "$m" && pass "métrica disponible: $m" || bad "métrica disponible: $m" "sin datos en Prometheus"
done
UPI=$(k exec prometheus-0 -- wget -qO- "http://localhost:9090/api/v1/query?query=up" 2>&1)
has "Prometheus alcanza el ingress (job ingress-nginx, up)" "$UPI" '"job":"ingress-nginx"'

echo "5) Historial en Postgres (order book -> Postgres a través de las NetworkPolicy)"
H=""; for _ in $(seq 1 60); do H=$(api "/audit/history/$AL"); [[ "$H" == *'"lag":0'* ]] && break; sleep 2; done
has "el historial alcanzó al journal (lag 0)" "$H" '"lag":0'
has "saldo del historial == saldo del motor" "$H" '"consistent":true'

echo "6) ¿El CNI de este cluster APLICA las NetworkPolicy? (informativo: no cuenta como fallo)"
k delete pod np-probe --ignore-not-found >/dev/null 2>&1
k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: np-probe}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: busybox:1.36
      command: [sh, -c, "nc -zw3 postgres 5432 && echo ALCANZABLE || echo BLOQUEADO"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
k wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-probe --timeout=90s >/dev/null 2>&1
NP=$(k logs np-probe 2>/dev/null | tail -1); k delete pod np-probe --ignore-not-found >/dev/null 2>&1
case "$NP" in
  BLOQUEADO)   echo "  [INFO]  un pod sin etiqueta NO alcanza a Postgres: las NetworkPolicy se APLICAN";;
  ALCANZABLE)  echo "  [INFO]  un pod sin etiqueta SÍ alcanza a Postgres: este CNI NO aplica NetworkPolicy (declaradas pero sin efecto aquí)";;
  *)           echo "  [INFO]  no se pudo determinar (resultado: '$NP')";;
esac

echo
[ "$FAILS" = 0 ] && { echo "SMOKE OK"; exit 0; } || { echo "SMOKE: $FAILS fallos"; exit 1; }
