# Plataforma: escalabilidad, resiliencia y observabilidad

Este documento explica **qué hace la plataforma, por qué** y **qué no hace todavía**. Usa la misma convención que
`DECISIONES.md` de la app: se distingue lo comprobado de lo supuesto.

## 1. Qué es esto

Un único conjunto de manifiestos (`base/`) más un overlay por ambiente. El objetivo no es la cantidad de piezas sino que el
despliegue sea **declarativo, repetible y seguro por defecto**: lo mismo en local y en un cluster real, con diferencias explícitas
y mínimas.

## 2. Reutilización sin duplicar lógica

- `base/` contiene todo lo común. Cada overlay (`local`, `staging`, `prod`) solo declara lo que cambia: namespace, imagen/versión,
  hosts del ingress, tamaños y, en prod, recursos. Añadir un ambiente son 3 archivos.
- Dashboards y alertas **no se reescriben aquí**: se sincronizan desde el repo de la app (`scripts/sync-observability.sh`) y
  `base/observability/SOURCE` guarda el commit de origen. Una sola fuente de verdad.
- Los ConfigMaps se generan con sufijo hash: si cambia un dashboard o una alerta, los pods que lo usan se reinician solos.

## 3. Escalabilidad (la parte que hay que explicar bien)

**Hecho:** el order book es de **un solo escritor por diseño** (secuenciador único, journal en disco, lock de instancia). Dos
réplicas escribiendo romperían el orden total y la conservación. Por eso:

- El escritor es un `StatefulSet` con **`replicas: 1`**, sin HPA, y `scripts/policy.py` **falla el CI** si alguien lo cambia.
- Escala **en vertical**: `requests`/`limits` por ambiente (prod: 2 CPU y 4–8 GiB). No se fija límite de CPU a propósito: la
  limitación de CFS añadiría latencia al secuenciador.
- La capacidad medida es la de un escritor: ≈ 5.3 K órdenes/s sostenidas 30 min en el sandbox, ≈ 11 K/s en 10 min en una laptop
  (ver `DEFENSA_TECNICA.md` en el repo de la app). No se promete más.

**Hipótesis / camino futuro (no implementado):** el siguiente escalón real es *shardear por mercado* (un escritor por par),
no añadir réplicas del mismo. Las lecturas del historial (Postgres) podrían separarse en un servicio sin estado escalable
horizontalmente; hoy viven en el mismo binario.

**Lo que SÍ escala/se adapta aquí:** Grafana es un `Deployment` sin estado; el ingress admite más réplicas; el tamaño de los volúmenes y
los recursos se ajustan por overlay sin tocar la base.

## 4. Resiliencia

| Falla | Comportamiento esperado | Mecanismo | Verificación |
|---|---|---|---|
| El proceso/pod del order book muere | Se recrea solo; reproduce el journal; **mismo estado** | `StatefulSet` + PVC con el journal; `startupProbe` tolera hasta 5 min de reproducción | `scripts/chaos.sh kill-pod` ✅ (estado idéntico; RTO 4.1 s con journal casi vacío) |
| El pod arranca pero aún no está listo | No recibe tráfico | `readinessProbe` sobre `/readyz` (secuenciador activo) | smoke ✅ |
| El proceso se cuelga | Se reinicia el contenedor | `livenessProbe` sobre `/healthz` | — |
| Postgres cae | El **mercado sigue**; el historial responde 503 y se reconcilia al volver | diseño de la app (el journal es la verdad) | `scripts/chaos.sh postgres-down` ✅ |
| Cambio de configuración/imagen | Reinicio ordenado (30 s de gracia) | `terminationGracePeriodSeconds`, hash en ConfigMaps | — |
| Disco del journal lleno | Fail-stop y alerta antes de llegar (`JournalDiskLow`) | métrica `journal_disk_free_bytes` | alertas (promtool) |

**Limitaciones (hechos):**
- **No hay alta disponibilidad del escritor.** Hay *recuperación rápida* (reproducir el journal tarda ≈ 8 s por millón de registros),
  durante la cual no se aceptan órdenes. RTO = tiempo de arranque + reproducción. **Medido: 4.1 s** con el journal casi vacío (un solo dato; ver `EVIDENCIA.md`); con un journal grande hay que sumar ≈ 8 s por millón de registros.
- El volumen del journal está atado a un nodo en kind (`local-path`). Si el nodo muere, el pod no se mueve solo. En un cluster
  cloud, un volumen de red con replicación (por zona) resuelve la parte del volumen; la HA del escritor requeriría una réplica
  seguidora, que **no está implementada** (ver `DECISIONES.md` de la app).
- **No se define `PodDisruptionBudget` para el escritor, a propósito:** con una sola réplica, `minAvailable: 1` bloquearía
  para siempre un `kubectl drain`, y `maxUnavailable: 1` no protege nada.

## 5. Observabilidad

- Mismo dashboard (43 paneles) y mismas 13 alertas que en docker-compose, provisionados desde ConfigMaps.
- Prometheus con volumen (2 días de retención) y Grafana provisionado, ambos con sondas y límites.
- `/metrics` y pprof están en el **puerto 9102, que no se publica por el ingress**; solo Prometheus lo alcanza (NetworkPolicy).
  `scripts/smoke.sh` comprueba que `/metrics` y `/debug/pprof` responden distinto de 200 por el ingress.
- `scripts/smoke.sh` también verifica que Prometheus ve el target `up` y que las 13 alertas están cargadas.
- **No incluido (limitaciones):** Alertmanager (las alertas se evalúan y se ven en la UI, igual que en la app), métricas de
  Kubernetes (`kube-state-metrics`, cAdvisor) y agregación de logs. Se agregarían con `kube-prometheus-stack` y Loki; se omitió
  para no sobredimensionar.

## 6. Seguridad por defecto

- **Pod Security Standards `restricted`** aplicado al namespace de cada ambiente: el cluster rechaza pods que no sean no-root,
  con privilegios o sin seccomp. Todos los contenedores fijan `runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop: [ALL]`; el order book
  además usa sistema de archivos raíz de solo lectura (solo escribe en `/data`).
- **NetworkPolicy**: se deniega todo el tráfico entrante y se abren solo las rutas necesarias (ingress → API, Prometheus → 9102,
  orderbook → Postgres, Grafana → Prometheus). *Comprobado:* una NetworkPolicy solo se aplica si el CNI la implementa; en el kind del CI **sí se aplican**
  (`scripts/smoke.sh` §6: un pod sin etiqueta no alcanza a Postgres). En otro cluster, el script lo vuelve a informar.
- **Secretos fuera de git** en staging/prod (`scripts/create-secret.sh`, contraseñas aleatorias, no sobrescribe uno existente).
  `local` usa credenciales de demo, aisladas en `components/demo-secrets` y rechazadas por la política en cualquier otro ambiente.
- Imágenes con versión fija; `prod` exige una versión inmutable (la política lo verifica). `deploy.sh` exige confirmar el contexto de
  `kubectl` para no tocar el cluster equivocado.
- **Limitación heredada:** la API no tiene autenticación (MVP, documentado en la app). El ingress no añade TLS ni autenticación.

## 7. Decisiones

| # | Decisión | Por qué |
|---|---|---|
| P1 | Kustomize (base + overlays) y no Helm ni Terraform | Es lo mínimo que logra reutilización sin plantillas ni lenguaje propio; `kubectl apply -k` ya lo incluye |
| P2 | Repo separado de la app | La infraestructura evoluciona y se revisa por separado; el CI de este repo prueba contra el código de la app |
| P3 | 1 réplica del escritor, sin HPA | Un solo escritor por diseño (§3) |
| P4 | `StatefulSet` + PVC para order book, Postgres y Prometheus | El journal es la fuente de verdad y debe sobrevivir al pod |
| P5 | Scripts en bash en lugar de Makefile obligatorio | El usuario trabaja en Git Bash (Windows), que no trae `make`; hay un Makefile opcional |
| P6 | kind + ingress-nginx fijado, entrada por `localhost:8080` | El tráfico entra por un ingress real; JMeter no necesita cambios |
| P7 | Dashboards/alertas sincronizados, no copiados a mano | Una sola fuente de verdad (§2) |

## 8. Pendiente / siguientes pasos (no implementado)

TLS con cert-manager; despliegue continuo con Argo CD o Flux (hoy el despliegue es `kubectl apply -k` desde un script); Alertmanager;
`kube-state-metrics`; secretos con External Secrets o Sealed Secrets; copias del journal con `VolumeSnapshot`; aprovisionar el cluster
cloud con Terraform (EKS/GKE); réplica seguidora para HA del escritor; shardear por mercado.

## 9. Verificación

Ver el cuadro de estado en el `README.md` y el detalle en `docs/EVIDENCIA.md`. La validación estática y el despliegue en un kind real
(humo y caos) están **ejecutados en el CI**. Siguen sin probarse: staging/prod, carga sostenida a través del ingress, un journal grande
en el RTO y la ejecución en Docker Desktop; no deben presentarse como comprobados.
