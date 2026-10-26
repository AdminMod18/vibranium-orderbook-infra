#!/usr/bin/env bash
# Pruebas de resiliencia de la plataforma, sobre el ambiente local (kind). NO borran volúmenes.
#   scripts/chaos.sh kill-pod       mata el pod del order book SIN apagado ordenado (equivale a un crash/OOM) y mide la recuperación
#   scripts/chaos.sh postgres-down  apaga Postgres: el mercado debe seguir; al volver, el historial se reconcilia
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$ENV_NAME" = local ] || die "las pruebas de caos solo corren en el ambiente local"
need kubectl curl
guard_context
API_ADDR=${API_ADDR:-127.0.0.1:$HTTP_PORT}
API_HOST=${API_HOST:-localhost}
RUN=$(date +%s)$RANDOM
FAILS=0
pass() { printf '  [OK]    %s\n' "$1"; }
bad()  { printf '  [FALLO] %s\n          obtenido: %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }
has()  { [[ "$2" == *"$3"* ]] && pass "$1" || bad "$1 (se esperaba «$3»)" "$2"; }
api()  { curl -s -m 10 -H "Host: $API_HOST" "http://$API_ADDR$1" "${@:2}"; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: $API_HOST" "http://$API_ADDR$1" "${@:2}"; }
now()  { date +%s.%N; }
wait_ready() { local t0 t; t0=$(now); for _ in $(seq 1 240); do [ "$(code /readyz)" = 200 ] && break; sleep 1; done; t=$(now); awk -v a="$t0" -v b="$t" 'BEGIN{printf "%.1f", b-a}'; }

AL=chaos-a-$RUN; BO=chaos-b-$RUN
seed() {
  code /deposits -XPOST -d "{\"user_id\":\"$AL\",\"brl\":5000000}" >/dev/null
  code /deposits -XPOST -d "{\"user_id\":\"$BO\",\"vib\":500}" >/dev/null
  # un cruce parcial y órdenes en reposo en ambos lados: estado no trivial que debe sobrevivir
  code /orders -XPOST -d "{\"id\":\"cs-$RUN\",\"user_id\":\"$BO\",\"side\":\"SELL\",\"price\":4100,\"qty\":10}" >/dev/null
  code /orders -XPOST -d "{\"id\":\"cb-$RUN\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":4100,\"qty\":4}" >/dev/null
  code /orders -XPOST -d "{\"id\":\"cr-$RUN\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":4000,\"qty\":7}" >/dev/null
  # GET /orders/{id} lee del historial (Postgres, eventualmente consistente): se espera a que alcance al journal antes de fotografiar el
  # estado, o la comparación "antes/después" mediría una carrera y no la recuperación.
  for _ in $(seq 1 60); do [[ "$(api "/audit/history/$AL")" == *'"lag":0'* ]] && break; sleep 1; done
}
snapshot() { printf '%s\n%s\n%s\n%s\n' "$(api /balances/$AL)" "$(api /balances/$BO)" "$(api /orders/cs-$RUN)" "$(api /audit)"; }

case "${1:-}" in
kill-pod)
  echo "== kill-pod: crash del order book bajo estado no trivial =="
  wait_ready >/dev/null; seed
  ANTES=$(snapshot); UID_ANTES=$(k get pod orderbook-0 -o jsonpath='{.metadata.uid}')
  echo "estado antes:"; sed 's/^/    /' <<<"$ANTES"
  echo "matando orderbook-0 (--grace-period=0 --force: sin apagado ordenado)"
  k delete pod orderbook-0 --grace-period=0 --force >/dev/null 2>&1
  # El StatefulSet lo recrea; el tráfico solo vuelve cuando /readyz = 200 (readinessProbe)
  OFF=0; for _ in 1 2 3; do c=$(code /readyz); [ "$c" != 200 ] && OFF=1 && break; sleep 0.3; done
  T=$(wait_ready)
  UID_DESPUES=$(k get pod orderbook-0 -o jsonpath='{.metadata.uid}')
  DESPUES=$(snapshot)
  echo "estado después:"; sed 's/^/    /' <<<"$DESPUES"
  [ "$UID_ANTES" != "$UID_DESPUES" ] && pass "el pod fue realmente recreado (uid distinto)" || bad "el pod fue recreado" "mismo uid: no hubo crash"
  [ "$ANTES" = "$DESPUES" ] && pass "saldos, orden en el libro y auditoría IDÉNTICOS tras el crash (el journal en el volumen sobrevivió)" || bad "estado idéntico tras el crash" "difiere (ver arriba)"
  has "el servicio vuelve a aceptar órdenes" "$(code /orders -XPOST -d "{\"id\":\"cp-$RUN\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":3900,\"qty\":1}")" 201
  printf '  tiempo hasta /readyz = 200 tras el crash: %s s\n' "$T"
  ;;
postgres-down)
  echo "== postgres-down: el historial cae, el mercado NO =="
  wait_ready >/dev/null; seed
  echo "apagando Postgres (replicas=0; el volumen se conserva)"
  k scale statefulset/postgres --replicas=0 >/dev/null; k wait --for=delete pod/postgres-0 --timeout=90s >/dev/null 2>&1
  has "el mercado sigue aceptando órdenes (201) sin Postgres" "$(code /orders -XPOST -d "{\"id\":\"pd-$RUN\",\"user_id\":\"$AL\",\"side\":\"BUY\",\"price\":3800,\"qty\":1}")" 201
  has "/readyz sigue en 200 (Postgres no es requisito para recibir tráfico)" "$(code /readyz)" 200
  has "el historial responde 503 (degradación explícita, no silenciosa)" "$(code /orders/cs-$RUN)" 503
  echo "restaurando Postgres"
  k scale statefulset/postgres --replicas=1 >/dev/null; k rollout status statefulset/postgres --timeout=180s >/dev/null
  R=""; for _ in $(seq 1 120); do R=$(api /audit/history/$AL); [[ "$R" == *'"lag":0'* ]] && break; sleep 1; done
  has "el historial se pone al día solo (lag 0)" "$R" '"lag":0'
  has "saldo del historial == saldo del motor" "$R" '"consistent":true'
  ;;
*) die "uso: scripts/chaos.sh kill-pod|postgres-down";;
esac
echo; [ "$FAILS" = 0 ] && { echo "CHAOS OK"; exit 0; } || { echo "CHAOS: $FAILS fallos"; exit 1; }
