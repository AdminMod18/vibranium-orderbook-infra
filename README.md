# vibranium-orderbook-infra

Infraestructura como código (Kubernetes + Kustomize) para [`vibranium-orderbook-meli`](https://github.com/AdminMod18/vibranium-orderbook-meli).
**Un solo conjunto de manifiestos reutilizable** que se despliega en varios ambientes (local, staging, prod) cambiando solo
lo que de verdad difiere, sin copiar lógica. El diseño, las decisiones y las limitaciones están en [`docs/PLATAFORMA.md`](docs/PLATAFORMA.md).

```
Cliente / JMeter ──► Ingress (nginx) ──► Service orderbook:8080 ──► StatefulSet orderbook (1 escritor + PVC con el journal)
                         │                                              │  :9102 /metrics (NO sale por el ingress)
                         └──► Grafana ◄── Prometheus (PVC) ─────────────┘
                                                     orderbook ──► StatefulSet postgres (historial, PVC)
```

## Estructura

| Ruta | Qué es |
|---|---|
| `base/` | Todo lo común: order book, Postgres, Prometheus, Grafana, ingress, NetworkPolicy. Dashboards y alertas en `base/observability/` |
| `overlays/{local,staging,prod}/` | Lo que cambia por ambiente: namespace, imagen, hosts, tamaños, secretos (3 archivos pequeños cada uno) |
| `components/demo-secrets/` | Credenciales de demo, **solo** para `local` |
| `platform/ingress-nginx/` | Controlador de ingress, versión fijada |
| `kind/cluster.yaml` | Cluster local de un nodo con el puerto 8080 del host hacia el ingress |
| `scripts/` | `kind-up`, `build-image`, `deploy`, `smoke`, `chaos`, `validate`, `create-secret`, `sync-observability`, `kind-down` |
| `.github/workflows/ci.yaml` | Valida cada overlay y, además, levanta kind y ejecuta humo y caos |

## Requisitos

Docker Desktop (en marcha), [`kind`](https://kind.sigs.k8s.io/) y `kubectl`. En Windows: `winget install Kubernetes.kind`
(kubectl viene con Docker Desktop). Clone **al lado** el repo de la app (`../vibranium-orderbook-meli`) o defina `APP_DIR`.
Los scripts se ejecutan en Git Bash. **Detenga antes `docker compose` de la app** (ambos usan el puerto 8080; con `HTTP_PORT=8081` se cambia).

## Uso (ambiente local)

```bash
scripts/kind-up.sh          # cluster kind + ingress-nginx
scripts/build-image.sh      # construye la imagen de la app y la carga en el cluster
scripts/deploy.sh local     # aplica overlays/local y espera a que todo esté listo
scripts/smoke.sh            # humo: ingress, ciclo de órdenes, /metrics cerrado, Prometheus/Grafana conectados
scripts/chaos.sh kill-pod       # mata el pod sin apagado ordenado y comprueba que el estado sobrevive
scripts/chaos.sh postgres-down  # apaga Postgres: el mercado sigue, el historial se reconcilia
```

- API: <http://localhost:8080> · Grafana: <http://grafana.localtest.me:8080> (admin/admin en local) · Prometheus: `kubectl -n vibranium-local port-forward svc/prometheus 9090`
- **JMeter contra el cluster** (desde el repo de la app, todo el tráfico entra por el ingress):
  `HOST=localhost PORT=8080 jmeter/run-jmeter.sh gradual` (o abra `vibranium-load.jmx` en la GUI con host `localhost` y puerto `8080`).
- Eliminar todo (**borra los datos del cluster**): `scripts/kind-down.sh`

## Otros ambientes

```bash
scripts/validate.sh                                           # estático, sin cluster
CONFIRM_CONTEXT=<ctx> scripts/create-secret.sh staging        # contraseñas aleatorias, fuera de git
CONFIRM_CONTEXT=<ctx> scripts/deploy.sh staging               # exige confirmar el contexto de kubectl
```

**Añadir un ambiente** = copiar `overlays/staging/` a `overlays/<nombre>/` y cambiar namespace, imagen y hosts. El resto se hereda de `base/`.

## Estado de la verificación

| Qué | Estado |
|---|---|
| Los 3 overlays compilan, cumplen el esquema de Kubernetes 1.31 (kubeconform) y las políticas de `scripts/policy.py` | ✅ ejecutado (CI en cada push) |
| Las políticas detectan imagen `latest`, réplicas ≠ 1 en el escritor y Secrets en git (mutaciones) | ✅ ejecutado |
| Despliegue real en kind (CI): cluster, ingress, imagen, 4 rollouts | ✅ ejecutado |
| Humo 19/19: tráfico por el ingress, `/metrics` cerrado, 13 alertas, Grafana, historial, NetworkPolicy aplicadas | ✅ ejecutado |
| Caos: crash del pod → estado idéntico, **RTO 4.1 s** (journal casi vacío); Postgres caído → el mercado sigue y el historial se reconcilia | ✅ ejecutado |
| Ejecución en Docker Desktop (laptop del autor): despliegue + humo 19/19 | ✅ ejecutado · caos y carga: ⏳ pendientes |
| Staging y prod | plantillas validadas estáticamente; no desplegadas |

Detalle, enlaces a cada ejecución y lo que **no** se probó: [`docs/EVIDENCIA.md`](docs/EVIDENCIA.md).
