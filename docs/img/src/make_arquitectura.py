#!/usr/bin/env python3
"""Genera docs/img/arquitectura-kubernetes.svg (el diagrama de cómo la plataforma se conecta con la app).

    python3 docs/img/src/make_arquitectura.py            # escribe el SVG
    node docs/img/src/render.js docs/img/arquitectura-kubernetes.svg   # opcional: PNG (usa Playwright)

Solo biblioteca estándar. El SVG es el entregable; el script permite revisar el diagrama como código.
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "arquitectura-kubernetes.svg"
W, H = 1800, 1170
BLUE, GREEN, AMBER, GRAY, INK = "#2563eb", "#059669", "#d97706", "#64748b", "#0f172a"
F = "Inter, 'Segoe UI', Roboto, Arial, sans-serif"
o = []


def add(s):
    o.append(s)


def rect(x, y, w, h, fill="#fff", stroke=GRAY, sw=1.5, rx=12, dash=None, extra=""):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d} {extra}/>')


def text(x, y, s, size=15, weight=400, fill=INK, anchor="start"):
    s = s.replace("&", "&amp;").replace("<", "&lt;")
    add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{s}</text>')


def box(x, y, w, h, title, lines=(), color=GRAY, fill="#fff", tsize=16):
    rect(x, y, w, h, fill=fill, stroke=color, sw=2)
    text(x + 14, y + 26, title, tsize, 700, color if color != GRAY else INK)
    for i, ln in enumerate(lines):
        text(x + 14, y + 50 + i * 21, ln, 14, 400, "#334155")


def pvc(x, y, w, h, title, sub):
    rect(x, y, w, h, fill="#ecfdf5", stroke=GREEN, sw=2, rx=10)
    add(f'<ellipse cx="{x+24}" cy="{y+h/2}" rx="11" ry="14" fill="#fff" stroke="{GREEN}" stroke-width="2"/>')
    text(x + 46, y + h / 2 - 3, title, 14.5, 700, GREEN)
    text(x + 46, y + h / 2 + 16, sub, 12.5, 400, "#065f46")


def arrow(pts, color, dash=None, label=None, lx=None, ly=None, sw=2.6, np=False):
    d = "M " + " L ".join(f"{x},{y}" for x, y in pts)
    da = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{da} marker-end="url(#a-{color[1:]})"/>')
    if label:
        w = len(label) * 7.0 + 18
        rect(lx - 4, ly - 17, w, 24, fill="#ffffff", stroke="none", rx=6, extra='opacity="0.92"')
        text(lx + 5, ly, label, 13, 600, color)
    if np:
        mx, my = lx, ly + 20
        rect(mx - 4, my - 13, 30, 19, fill="#eef2ff", stroke="#6366f1", sw=1.2, rx=9)
        text(mx + 11, my + 1, "NP", 11, 700, "#4338ca", "middle")


def num(x, y, n, color=BLUE):
    add(f'<circle cx="{x}" cy="{y}" r="14" fill="{color}"/>')
    text(x, y + 5, str(n), 15, 800, "#fff", "middle")


add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="{F}">')
add("<defs>" + "".join(
    f'<marker id="a-{c[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
    for c in (BLUE, GREEN, AMBER, GRAY)) + "</defs>")
rect(0, 0, W, H, fill="#ffffff", stroke="none", rx=0)

text(40, 54, "Vibranium Order Book · Plataforma en Kubernetes", 30, 800)
text(40, 84, "Cómo se conecta la infraestructura con la aplicación. Entorno local: kind (1 nodo). Staging y prod usan los mismos manifiestos (Kustomize).", 15.5, 400, "#475569")

# --- clientes
box(40, 250, 250, 120, "JMeter · evaluador", ["curl / robots de órdenes", "→ http://localhost:8080"], BLUE, "#eff6ff")
box(40, 560, 250, 110, "Navegador", ["Grafana (admin/admin local)", "→ grafana.localtest.me:8080"], AMBER, "#fffbeb")

# --- cluster
rect(330, 110, 1440, 1020, fill="#f8fafc", stroke="#94a3b8", sw=2.5, rx=18)
text(352, 142, "Cluster Kubernetes · kind (1 nodo) dentro de Docker Desktop", 17, 700, "#334155")

# ns ingress-nginx
rect(360, 190, 300, 640, fill="#fff", stroke="#94a3b8", sw=1.6, rx=14, dash="7 5")
text(376, 218, "ns ingress-nginx", 15, 700, "#475569")
box(385, 240, 250, 570, "ingress-nginx-controller", [
    "Única entrada de tráfico.", "", "Escucha :80 (el puerto 8080",
    "de tu máquina llega aquí).", "", "Enruta por reglas Ingress:",
    "  · cualquier host → orderbook", "  · grafana.localtest.me → grafana", "",
    "Solo publica la API (:8080).", "NO publica /metrics ni pprof", "(puerto de administración 9102).", "",
    "Métricas propias en :10254", "(Prometheus las raspa)."], BLUE, "#eff6ff")

# ns vibranium-local
rect(700, 150, 1040, 840, fill="#fff", stroke="#94a3b8", sw=1.6, rx=14, dash="7 5")
text(716, 178, "ns vibranium-local", 15, 700, "#475569")
text(880, 178, "Pod Security «restricted» · NetworkPolicy: se deniega todo y solo se abren las rutas dibujadas (NP)", 13, 400, "#6366f1")

box(730, 232, 210, 100, "Ingress + Service", ["orderbook :8080", "(admin :9102 solo interno)"], BLUE, "#eff6ff")
box(1000, 200, 380, 240, "StatefulSet orderbook-0", [], BLUE, "#eff6ff", 17)
text(1014, 252, "1 réplica: es un SOLO ESCRITOR por diseño", 13.5, 600, "#1d4ed8")
for i, ln in enumerate(["valida · idempotencia · cola acotada (503 si llena)", "secuenciador único: libro + billeteras",
                        "UN fsync del journal por lote → luego responde", "fail-stop si el disco/journal falla", "admin :9102 → /metrics (sin autenticación, interno)"]):
    text(1014, 280 + i * 23, ln, 13.5, 400, "#334155")
pvc(1000, 462, 240, 62, "PVC journal 5 Gi", "fuente de verdad")
box(1490, 200, 220, 120, "StatefulSet postgres-0", ["Historial y trazabilidad", "(órdenes, trades, libro mayor)"], GREEN, "#f0fdf4")
pvc(1490, 340, 220, 62, "PVC datos 5 Gi", "modelo de lectura")

box(730, 552, 210, 92, "Ingress + Service", ["grafana :3000"], AMBER, "#fffbeb")
box(1000, 540, 380, 112, "Deployment grafana", ["2 dashboards provisionados:", "aplicación y plataforma"], AMBER, "#fffbeb")

box(1000, 760, 380, 134, "StatefulSet prometheus-0", ["Raspa cada 5 s: orderbook :9102,", "ingress :10254, kube-state-metrics,", "cAdvisor · 13 alertas cargadas"], AMBER, "#fffbeb")
pvc(1000, 912, 240, 62, "PVC métricas 2 Gi", "retención 2 días")
box(1490, 770, 220, 112, "kube-state-metrics", ["estado, reinicios y límites", "declarados de cada pod"], AMBER, "#fffbeb")

box(1000, 1030, 380, 74, "Nodo · kubelet (cAdvisor)", ["CPU, memoria y red reales por pod"], GRAY, "#f1f5f9")

# --- flechas: orden (azul)
arrow([(290, 310), (385, 310)], BLUE)
num(338, 286, 1)
arrow([(635, 282), (730, 282)], BLUE, label="②", lx=668, ly=268, np=True)
arrow([(940, 282), (1000, 282)], BLUE, label=None)
# persistencia (verde)
arrow([(1190, 440), (1190, 462)], GREEN, label=None)
arrow([(1380, 258), (1490, 258)], GREEN, label="④ asíncrono", lx=1384, ly=240, np=True)
arrow([(1600, 320), (1600, 340)], GREEN)
# observabilidad (ámbar)
arrow([(290, 612), (385, 612)], AMBER, label="⑥", lx=318, ly=596)
arrow([(635, 598), (730, 598)], AMBER, np=True, label=None, lx=668, ly=578)
arrow([(940, 598), (1000, 598)], AMBER)
arrow([(1190, 652), (1190, 760)], AMBER, label="⑥ consulta PromQL :9090", lx=1198, ly=712, np=True)
arrow([(1380, 856), (1490, 856)], AMBER, dash="7 5", label="⑤ :8080", lx=1396, ly=842)
arrow([(1380, 800), (1425, 800), (1425, 392), (1380, 392)], AMBER, dash="7 5", label="⑤ :9102", lx=1432, ly=560, np=True)
arrow([(1000, 790), (635, 790)], AMBER, dash="7 5", label="⑤ :10254", lx=790, ly=772)
arrow([(1300, 894), (1300, 1030)], AMBER, dash="7 5", label="⑤ cAdvisor", lx=1312, ly=972)

# --- leyenda
box(40, 700, 282, 430, "Cómo viaja una orden", [], INK, "#fff")
steps = ["① JMeter llama a localhost:8080;", "   kind lo publica en el nodo.",
         "② El ingress enruta al Service;", "   solo él entra al 8080 (NP).",
         "③ El pod valida, encola, empareja", "   y confirma tras UN fsync.",
         "④ Lo confirmado se copia a Postgres", "   (historial), sin bloquear.",
         "⑤ Prometheus raspa pod, ingress,", "   estado de pods y cAdvisor.",
         "⑥ Grafana consulta a Prometheus", "   y se ve por el mismo ingress."]
for i, ln in enumerate(steps):
    text(54, 758 + i * 26, ln, 13, 600 if ln[0] != " " else 400, "#334155")
add(f'<line x1="56" y1="1074" x2="100" y2="1074" stroke="{BLUE}" stroke-width="3"/>'); text(108, 1079, "orden", 13)
add(f'<line x1="160" y1="1074" x2="204" y2="1074" stroke="{GREEN}" stroke-width="3"/>'); text(212, 1079, "datos", 13)
add(f'<line x1="56" y1="1100" x2="100" y2="1100" stroke="{AMBER}" stroke-width="3" stroke-dasharray="7 5"/>'); text(108, 1105, "métricas", 13)
rect(176, 1088, 30, 19, fill="#eef2ff", stroke="#6366f1", sw=1.2, rx=9); text(191, 1102, "NP", 11, 700, "#4338ca", "middle"); text(214, 1103, "NetworkPolicy", 13)

add("</svg>")
OUT.write_text("\n".join(o), encoding="utf-8")
print("escrito", OUT)
