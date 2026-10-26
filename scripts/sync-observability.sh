#!/usr/bin/env bash
# Trae dashboards y alertas del repo de la app (única fuente de verdad) a base/observability/ y anota de qué commit vienen.
#   scripts/sync-observability.sh [ruta-al-repo-de-la-app]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
APP_DIR=${1:-${APP_DIR:-$ROOT/../vibranium-orderbook-meli}}
[ -d "$APP_DIR/ops" ] || die "no encuentro $APP_DIR/ops"
D="$ROOT/base/observability"
cp "$APP_DIR/ops/prometheus/prometheus.yml" "$APP_DIR/ops/prometheus/alerts.yml" "$D/"
cp "$APP_DIR"/ops/grafana/provisioning/datasources/*.yml "$D/grafana/datasources/prometheus.yml"
cp "$APP_DIR"/ops/grafana/provisioning/dashboards/*.yml "$D/grafana/dashboards.yml"
cp "$APP_DIR/ops/grafana/dashboards/orderbook.json" "$D/grafana/orderbook.json"
git -C "$APP_DIR" rev-parse HEAD > "$D/SOURCE"
info "sincronizado desde $(cat "$D/SOURCE")"
