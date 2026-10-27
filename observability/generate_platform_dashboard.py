#!/usr/bin/env python3
"""Genera base/observability/grafana/plataforma.json: el dashboard de PLATAFORMA (ingress y pod), complemento del dashboard de la app.

    python3 observability/generate_platform_dashboard.py

El dashboard de la app (orderbook.json) mide la aplicación y se sincroniza desde su repo; este mide lo que solo existe en el cluster.
Solo biblioteca estándar. Toda métrica usada la comprueba scripts/smoke.sh contra el Prometheus real (un panel con "No data" falla el CI).
"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "base" / "observability" / "grafana" / "plataforma.json"
DS = {"type": "prometheus", "uid": "prometheus"}
R = "$rate"
_id = 0
_panels = []
_y = _x = _rowh = 0


def _nid():
    global _id
    _id += 1
    return _id


def row(title, description=""):
    global _y, _x, _rowh
    _y += _rowh
    _x = _rowh = 0
    _panels.append({"id": _nid(), "type": "row", "title": title, "description": description, "collapsed": False, "panels": [],
                    "gridPos": {"x": 0, "y": _y, "w": 24, "h": 1}})
    _y += 1


def place(w, h):
    global _x, _y, _rowh
    if _x + w > 24:
        _y += _rowh
        _x = _rowh = 0
    pos = {"x": _x, "y": _y, "w": w, "h": h}
    _x += w
    _rowh = max(_rowh, h)
    return pos


def tgt(expr, legend="", ref="A"):
    return {"refId": ref, "expr": expr, "datasource": DS, "legendFormat": legend, "instant": False, "range": True}


def steps(*pairs):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in pairs]}


def stat(title, expr, unit, th=None, desc="", w=4, h=4, decimals=None, mappings=None):
    fc = {"unit": unit, "thresholds": th or steps((None, "blue")), "mappings": mappings or []}
    if decimals is not None:
        fc["decimals"] = decimals
    _panels.append({"id": _nid(), "type": "stat", "title": title, "description": desc, "datasource": DS, "gridPos": place(w, h),
                    "targets": [tgt(expr)], "fieldConfig": {"defaults": fc, "overrides": []},
                    "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "background",
                                "graphMode": "area", "textMode": "value", "justifyMode": "center"}})


def ts(title, targets, unit, desc="", w=12, h=8, stack=False):
    custom = {"lineWidth": 2, "fillOpacity": 15, "showPoints": "never", "spanNulls": True, "drawStyle": "line",
              "stacking": {"mode": "normal" if stack else "none", "group": "A"}, "axisSoftMin": 0}
    _panels.append({"id": _nid(), "type": "timeseries", "title": title, "description": desc, "datasource": DS, "gridPos": place(w, h),
                    "targets": targets, "fieldConfig": {"defaults": {"unit": unit, "custom": custom}, "overrides": []},
                    "options": {"legend": {"displayMode": "table", "placement": "bottom", "showLegend": True, "calcs": ["lastNotNull", "mean", "max"]},
                                "tooltip": {"mode": "multi", "sort": "desc"}}})


def text(content, w=24, h=3):
    _panels.append({"id": _nid(), "type": "text", "title": "", "gridPos": place(w, h), "transparent": True,
                    "options": {"mode": "markdown", "content": content}})


def hq(quantile, metric, sel=""):
    return f"histogram_quantile({quantile}, sum by (le) (rate({metric}_bucket{sel}[{R}])))"


REQ = "nginx_ingress_controller_requests"
DUR = "nginx_ingress_controller_request_duration_seconds"
UP_MAP = [{"type": "value", "options": {"1": {"text": "OK", "color": "green"}, "0": {"text": "CAÍDO", "color": "red"}}}]
OB = '{ingress="orderbook"}'

text("**Plataforma (Kubernetes).** Lo que solo existe en el cluster: la **entrada de tráfico** (ingress-nginx) y el **pod** del order book. "
     "El dashboard de la aplicación (órdenes, latencia, cola, journal) es el otro panel de esta carpeta. "
     "Las secciones 2 y 3 salen del cluster: **cAdvisor** (CPU, memoria y red reales de cada contenedor) y **kube-state-metrics** (reinicios, estado y los límites declarados). "
     "El namespace se elige arriba (ambiente).", h=3)

row("1 · Entrada de tráfico (ingress-nginx)", "Todo el tráfico de clientes y de JMeter pasa por aquí antes de llegar al pod.")
stat("Ingress", 'up{job="ingress-nginx"}', "none", steps((None, "red"), (1, "green")), "1 = Prometheus alcanza las métricas del controlador de ingress.", mappings=UP_MAP)
stat("Peticiones / s", f"sum(rate({REQ}[{R}]))", "reqps", desc="Peticiones que atravesaron el ingress (todas las rutas, incluido Grafana).", decimals=0)
stat("Errores 5xx / s", f'sum(rate({REQ}{{status=~"5.."}}[{R}])) or vector(0)', "reqps", steps((None, "green"), (0.001, "red")),
     "Respuestas 5xx vistas por el ingress: fallos del pod o 502/503/504 por pod caído o saturado. Debe ser 0.", decimals=2)
stat("p95 en el ingress", hq(0.95, DUR, OB), "s", steps((None, "green"), (0.05, "yellow"), (0.25, "red")),
     "Latencia p95 medida en el ingress (cliente → ingress → pod → respuesta) para el ingress del order book.", decimals=3)
stat("p99 en el ingress", hq(0.99, DUR, OB), "s", steps((None, "green"), (0.1, "yellow"), (0.5, "red")), "Latencia p99 en el ingress.", decimals=3)
stat("Conexiones activas", "sum(nginx_ingress_controller_nginx_process_connections{state=\"active\"})", "short", desc="Conexiones TCP abiertas en el controlador.", decimals=0)
ts("Peticiones por segundo, por ingress", [tgt(f"sum by (ingress) (rate({REQ}[{R}]))", "{{ingress}}")], "reqps",
   "Reparto del tráfico entre el order book y Grafana.", stack=True)
ts("Respuestas por código HTTP (ingress)", [tgt(f"sum by (status) (rate({REQ}[{R}]))", "{{status}}")], "reqps",
   "201 = órdenes aceptadas; 4xx = rechazos esperados del contrato; 5xx = fallos.", stack=True)
ts("Latencia: lo que ve el ingress vs lo que mide el servidor", [
    tgt(hq(0.95, DUR, OB), "p95 en el ingress (incluye red y cola de conexión)", "A"),
    tgt(hq(0.95, "orderbook_http_request_duration_seconds", '{route="POST /orders"}'), "p95 medido por el servidor (POST /orders)", "B")], "s",
   "La diferencia entre las dos líneas es lo que añade el salto por el ingress. Si el ingress es mucho mayor, el cuello está en la entrada o en la red, no en el order book.")
ts("Conciliación de tráfico: ingress vs servidor", [
    tgt(f"sum(rate({REQ}{OB}[{R}]))", "peticiones vistas por el ingress", "A"),
    tgt(f"sum(rate(orderbook_http_requests_total[{R}]))", "peticiones contadas por el servidor", "B")], "reqps",
   "Deben coincidir (el servidor no cuenta las que el ingress rechaza o corta antes). Una brecha sostenida indica peticiones perdidas en la entrada.")

NSQ = '{namespace="$namespace"}'
CT = '{namespace="$namespace",container!=""}'
OBP = '{namespace="$namespace",pod="orderbook-0",container="orderbook"}'

row("2 · Pods del namespace (cAdvisor + kube-state-metrics)", "Rendimiento real de cada pod medido por el cluster, no por la aplicación.")
stat("Pods listos", f'sum(kube_pod_status_ready{{namespace="$namespace",condition="true"}})', "short", steps((None, "red"), (1, "yellow"), (4, "green")),
     "Pods en estado Ready. Se esperan 5 en el cluster local (order book, Postgres, Prometheus, Grafana y kube-state-metrics).", decimals=0)
stat("Reinicios de contenedores", f"sum(kube_pod_container_status_restarts_total{NSQ})", "short", steps((None, "green"), (1, "yellow"), (5, "red")),
     "Reinicios acumulados de contenedores (crash, OOM o sonda de vida fallida). Un pod recreado por el StatefulSet NO suma aquí: es un pod nuevo.", decimals=0)
stat("CPU del namespace", f"sum(rate(container_cpu_usage_seconds_total{CT}[{R}]))", "short", desc="Núcleos que consumen todos los pods del ambiente.", decimals=2)
stat("Memoria del namespace", f"sum(container_memory_working_set_bytes{CT})", "bytes", desc="Memoria en uso (working set) de todos los pods; es la que cuenta el límite del contenedor.")
stat("Order book: memoria", f"container_memory_working_set_bytes{OBP}", "bytes", steps((None, "green"), (2.5 * 1024**3, "yellow"), (3.5 * 1024**3, "red")),
     "Memoria del contenedor del order book. Su límite es 4 GiB; al pasarlo, el kernel lo mata (OOM).")
stat("Order book: CPU (núcleos)", f"rate(container_cpu_usage_seconds_total{OBP}[{R}])", "short", desc="Núcleos que consume el contenedor del order book.", decimals=2)
ts("CPU por pod (núcleos)", [tgt(f"sum by (pod) (rate(container_cpu_usage_seconds_total{CT}[{R}]))", "{{pod}}")], "short",
   "Quién consume CPU durante la prueba. El order book es un solo escritor: se espera que domine y que se acerque a 1-2 núcleos.", stack=True)
ts("Memoria por pod (working set)", [tgt(f"sum by (pod) (container_memory_working_set_bytes{CT})", "{{pod}}")], "bytes",
   "Memoria en uso de cada pod. Crece con el libro y la ventana de idempotencia.", stack=True)
ts("Order book: memoria frente a su request y su límite", [
    tgt(f"container_memory_working_set_bytes{OBP}", "uso (working set)", "A"),
    tgt(f'kube_pod_container_resource_requests{{namespace="$namespace",pod="orderbook-0",container="orderbook",resource="memory"}}', "request (reservado)", "B"),
    tgt(f'kube_pod_container_resource_limits{{namespace="$namespace",pod="orderbook-0",container="orderbook",resource="memory"}}', "límite (OOM al superarlo)", "C")], "bytes",
   "El margen entre el uso y el límite es lo que protege de un OOM. GOMEMLIMIT hace que el GC apriete antes de llegar al límite.")
ts("Order book: CPU frente a su request", [
    tgt(f"rate(container_cpu_usage_seconds_total{OBP}[{R}])", "uso (núcleos)", "A"),
    tgt(f'kube_pod_container_resource_requests{{namespace="$namespace",pod="orderbook-0",container="orderbook",resource="cpu"}}', "request (reservado)", "B")], "short",
   "Sin límite de CPU a propósito (el throttling añadiría latencia al secuenciador); el request solo reserva capacidad en el planificador.")
ts("Tráfico de red por pod", [tgt(f"sum by (pod) (rate(container_network_receive_bytes_total{NSQ}[{R}]))", "{{pod}} ↓ recibido", "A"),
                              tgt(f"sum by (pod) (rate(container_network_transmit_bytes_total{NSQ}[{R}]))", "{{pod}} ↑ enviado", "B")], "Bps",
   "Bytes por segundo que entran y salen de cada pod. El order book recibe las órdenes y envía las respuestas; Prometheus recibe las métricas.")
ts("Reinicios de contenedores por pod", [tgt(f"sum by (pod) (kube_pod_container_status_restarts_total{NSQ})", "{{pod}}")], "short",
   "Debe ser plano. Un escalón indica un crash o un OOM de ese pod.")

row("3 · Proceso del order book (métricas de la propia aplicación)", "Equivalente de plataforma para un único escritor: ¿arranca, se reinicia, cuánto consume?")
stat("Contenedor en marcha", f'time() - kube_pod_container_state_started{{namespace="$namespace",pod="orderbook-0",container="orderbook"}}', "s",
     steps((None, "yellow"), (60, "green")),
     "Tiempo desde que arrancó el contenedor del order book (kube-state-metrics). Vuelve a 0 si el pod se recrea o el contenedor se reinicia; amarillo = arrancó hace menos de 1 minuto.", decimals=0)
stat("Reinicios del contenedor", f'sum(kube_pod_container_status_restarts_total{{namespace="$namespace",pod="orderbook-0"}})', "short",
     steps((None, "green"), (1, "yellow"), (3, "red")),
     "Veces que Kubernetes reinició el contenedor (crash u OOM). Un pod recreado por el StatefulSet es un pod nuevo y se ve en el uptime, no aquí. "
     "(No se usa process_start_time_seconds: en Docker Desktop/WSL2 salta ±1 s y daba reinicios falsos.)", decimals=0)
stat("CPU del proceso (núcleos)", f'rate(process_cpu_seconds_total{{job="orderbook"}}[{R}])', "short", desc="Núcleos que consume el order book (sin límite de CPU en el pod, a propósito).", decimals=2)
stat("Memoria RSS", 'process_resident_memory_bytes{job="orderbook"}', "bytes", steps((None, "green"), (2.5 * 1024**3, "yellow"), (3.5 * 1024**3, "red")),
     "Memoria residente. El límite del pod es 4 GiB (local) y GOMEMLIMIT=3 GiB hace que el GC apriete antes.")
stat("Goroutines", 'go_goroutines{job="orderbook"}', "short", desc="Hilos ligeros del programa.", decimals=0)
stat("Descriptores abiertos", 'process_open_fds{job="orderbook"}', "short", desc="Archivos y sockets abiertos por el proceso.", decimals=0)
ts("CPU y memoria del proceso", [tgt(f'rate(process_cpu_seconds_total{{job="orderbook"}}[{R}])', "CPU (núcleos)", "A"),
                                 tgt('process_resident_memory_bytes{job="orderbook"} / 1024 / 1024 / 1024', "memoria RSS (GiB)", "B")], "short",
   "Consumo del pod del order book a lo largo de la prueba.")
ts("Objetivos de Prometheus (1 = arriba)", [tgt("up", "{{job}}")], "none", "Si un objetivo cae a 0, Prometheus dejó de ver ese componente.")

DASH = {"uid": "plataforma-k8s", "title": "Vibranium — Plataforma (Kubernetes)", "tags": ["vibranium", "kubernetes", "plataforma"],
        "timezone": "browser", "schemaVersion": 39, "version": 1, "refresh": "5s", "editable": True, "time": {"from": "now-15m", "to": "now"},
        "graphTooltip": 1, "annotations": {"list": []}, "links": [],
        "templating": {"list": [
            {"name": "namespace", "label": "Ambiente (namespace)", "type": "query", "datasource": DS, "query": "label_values(kube_pod_info, namespace)",
             "refresh": 2, "sort": 1, "hide": 0, "includeAll": False, "multi": False, "current": {}, "options": []},
            {"name": "rate", "label": "Ventana de cálculo", "type": "custom", "query": "30s,1m,5m",
                                 "current": {"selected": True, "text": "1m", "value": "1m"},
                                 "options": [{"selected": False, "text": "30s", "value": "30s"}, {"selected": True, "text": "1m", "value": "1m"},
                                             {"selected": False, "text": "5m", "value": "5m"}], "hide": 0}]},
        "panels": _panels}

if __name__ == "__main__":
    OUT.write_text(json.dumps(DASH, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"escrito {OUT}: {sum(1 for p in _panels if p['type'] not in ('row', 'text'))} paneles en {sum(1 for p in _panels if p['type'] == 'row')} secciones")
