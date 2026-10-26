# Evidencia de ejecución

Todo lo de este documento se **ejecutó de verdad** en un cluster kind creado por el CI de este repositorio (GitHub Actions,
`ubuntu-latest`, un nodo, imagen de la app construida desde `vibranium-orderbook-meli@main`). Cada fila enlaza a la ejecución
para poder comprobarla. **No es una prueba de rendimiento** y **no corrió en un cluster cloud**.

## Ejecuciones

| # | Commit | Resultado | Qué pasó |
|---|---|---|---|
| 1 | `a562382` | ❌ humo 18/19 | Todo el despliegue funcionó (cluster, ingress, imagen, 4 rollouts en ~16 s). Falló **una comprobación de mi prueba**: consultaba el target de Prometheus 6 s después de arrancarlo, antes de su primer scrape (`health: unknown`). No era un fallo de la plataforma. [log](https://github.com/AdminMod18/vibranium-orderbook-infra/actions/runs/40392156158) |
| 2 | `a7cb033` | ✅ todo | La prueba espera el primer scrape y añade dos comprobaciones nuevas (historial y NetworkPolicy). [log](https://github.com/AdminMod18/vibranium-orderbook-infra/actions/runs/40392630656) |
| 3 | `b891b15` | ✅ todo | Sondas del order book cada 2 s en lugar de 5 s. [log](https://github.com/AdminMod18/vibranium-orderbook-infra/actions/runs/40393090703) |

## Dashboard de plataforma (ejecuciones 8-10)

Se añadió un segundo dashboard (`plataforma-k8s`: ingress-nginx y pod del order book) y el smoke pasó a comprobar contra el Prometheus real que **cada métrica
que usa existe** (un panel con "No data" falla el CI). Esa comprobación encontró dos problemas reales, ambos corregidos:

| Ejecución | Hallazgo | Corrección |
|---|---|---|
| 8 ❌ | 3 métricas `nginx_ingress_controller_*` sin datos: el manifiesto oficial de kind trae `--enable-metrics=false` | Se activa con un parche que lleva un `test` (si cambia la versión y el argumento se mueve, el build falla en vez de aplicar algo distinto). |
| 8 ❌ | Mi comprobación `up{job="ingress-nginx"}` solo miraba que el target **existiera**, no que valiera 1: habría dado por bueno un target caído | Ahora exige valor `1`. |
| 9 ❌ | `kill-pod`: la comparación antes/después difirió. El estado "antes" incluía `GET /orders/{id}`, que lee del historial (eventualmente consistente) y aún no tenía la orden recién creada. Era una **carrera de mi prueba**, no un fallo de recuperación | El seed espera a que el historial alcance al journal antes de fotografiar el estado. |
| 10 ✅ | Smoke con todas las métricas y las dos pruebas de caos | [log](https://github.com/AdminMod18/vibranium-orderbook-infra/actions/runs/40401914740) |
| 12 ✅ | Se añaden **cAdvisor y kube-state-metrics** (CPU/memoria/red por pod, reinicios, límites declarados). El smoke exige que existan 17 métricas y que `up = 1` en los jobs `ingress-nginx`, `cadvisor` y `kube-state-metrics`; pasó a la primera. | [log](https://github.com/AdminMod18/vibranium-orderbook-infra/actions/runs/40402738808) |

| 14 ✅ | Hallazgos de la primera corrida con carga en la laptop (ver abajo): el ingress no contaba el tráfico del order book y "Reinicios" mostraba valores falsos. El smoke ahora exige la serie `ingress="orderbook"`. | [log](https://github.com/AdminMod18/vibranium-orderbook-infra/actions/runs/40406139590) |

**Lo que NO se comprobó:** que los paneles del dashboard de plataforma *se vean bien* en un navegador. El CI verifica que las métricas existen y el dashboard se provisiona, no el aspecto.

## Carga con JMeter a través del ingress, en la laptop del autor (10 min, GUI)

JMeter apuntando a `localhost:8080` (ingress del cluster kind), plan `vibranium-load.jmx`, 10 min 4 s:

| Dato (Summary Report de JMeter) | Valor |
|---|---|
| Muestras totales | **4,343,425** (`POST /orders` 4,047,370) |
| **% de error, todas las filas** | **0.00%**, incluidos los 6 rechazos esperados (400, 404, 409, 422) y `TEARDOWN GET /audit` (invariantes y conservación) |
| Rendimiento medio | 7,183 peticiones/s en total; **6,745 `POST /orders`/s** |
| Latencia media / máximo | 15 ms / 2,150 ms (`POST`); el máximo de 3,160 ms es la auditoría final |
| Order book (dashboard de plataforma) | CPU pico ≈ 2.3 núcleos; memoria RSS ≈ 2.4-2.5 GiB (límite del pod: 4 GiB) |

**Limitaciones (hechos):** no es la corrida de 5,000/s del plan: el ritmo medio fue ~6.7 K órdenes/s. Es el modo GUI de JMeter, en la misma máquina que el cluster, Grafana y el navegador; **no** es una medición de capacidad. El máximo de ~2 s afecta a todos los endpoints a la vez (parada global: la escritura periódica del snapshot, limitación ya documentada). El lag del historial en Postgres sube a ritmos altos y se recupera al terminar (comportamiento conocido).

**Dos fallos del dashboard que esta corrida destapó (y que el CI no veía), ya corregidos:**

| Hallazgo | Causa | Corrección |
|---|---|---|
| El panel del ingress mostraba ~7 peticiones/s (solo Grafana) mientras el servidor contaba ~10 K/s; "p95/p99 en el ingress" salía **No data** | El controlador solo registra métricas de hosts declarados en algún Ingress; el del order book no declara host (para aceptar `localhost`) y sus peticiones se descartaban. Causa inferida de ese comportamiento y del síntoma; **confirmada en la laptop** tras aplicar el arreglo: aparece la serie `orderbook` en el ingress (≈ 8.2 K req/s, p95 ≈ 21 ms, p99 ≈ 33 ms, 0 errores 5xx), y las peticiones del ingress coinciden con las del servidor. | `--metrics-per-host=false`; el smoke exige la serie `ingress="orderbook"` (no podía detectarlo antes: el humo solo consultaba que existiera *alguna* serie del ingress, y las de Grafana la satisfacían). |
| "Reinicios (1 h)" mostraba **62 y luego 94** sin que el pod hubiera reiniciado | `process_start_time_seconds` salta ±1 s en Docker Desktop/WSL2 y `changes()` cuenta cada salto | Uptime y reinicios salen ahora de kube-state-metrics (`kube_pod_container_state_started`, `kube_pod_container_status_restarts_total`). |

## Observación abierta: segunda corrida con timeouts de lectura (en análisis)

En una segunda corrida de JMeter (GUI, mismo cluster, sin reiniciarlo desde la primera) se vieron muestras `POST /orders` con `java.net.SocketTimeoutException: Read timed out`
(el plan espera hasta 10 s por respuesta) a partir de los ~6 min. Datos disponibles hasta ahora, **sin conclusión todavía**:

- A los 3 min la corrida estaba sana: ingress ≈ 8.2 K req/s, p95 21 ms, p99 33 ms, 0 errores 5xx, 5 pods listos, 0 reinicios.
- El order book usaba ≈ 3.4-3.7 GiB (working set de cAdvisor) sobre su límite de 4 GiB, mientras su RSS era ≈ 2.3 GiB: la diferencia (~1 GiB) es memoria que el cgroup cuenta pero el proceso no, p. ej. caché de página del journal (hipótesis).
- El cluster acumulaba ya el estado de la primera corrida (≈ 4.3 M órdenes y su journal) más esta.
- Un tramo de latencia de 1.6-1.8 s se ve en el panel ingress-vs-servidor (compatible con una pausa de snapshot ya documentada, pero un timeout de 10 s no lo es).

Pendiente: reinicios/OOM del pod, logs del order book, panel de fsync y de GC de la app. No se debe presentar esta corrida como "0 errores".

## Ejecución en la laptop del autor (Docker Desktop, Windows, Git Bash)

| Qué | Resultado |
|---|---|
| Entorno | Windows + Docker Desktop, `kind v0.33.0`, nodo `kindest/node:v1.37.0`, scripts ejecutados desde Git Bash |
| `kind-up.sh` → `build-image.sh` → `deploy.sh local` | ✅ cluster, ingress, imagen y 4 pods `Running` (3 PVC enlazados) en ~34 s tras construir la imagen |
| `smoke.sh` | ✅ **19/19** (`SMOKE OK`), incluido el historial con lag 0 y NetworkPolicy aplicadas |
| Caos `kill-pod` | ✅ pod recreado (uid distinto); saldos, orden parcial con su trade y auditoría **idénticos**; vuelve a aceptar órdenes. **RTO = 10.7 s** |
| Caos `postgres-down` | ✅ el mercado sigue (201), `/readyz` 200, historial 503, y al volver `lag 0` y saldos consistentes |
| Carga con JMeter a través del ingress | ⏳ pendiente |

**RTO en la laptop (10.7 s) vs CI (4.1 s):** una sola muestra en cada entorno, mismo journal casi vacío (10 registros). La diferencia **no está explicada**;
hipótesis (no verificadas): arranque de contenedores más lento en Docker Desktop/WSL2 y CPU compartida con el resto de aplicaciones del equipo. Para el RTO conviene
reportar el **rango observado (4.1-10.7 s)** y no uno solo; con un journal grande se suma ≈ 8 s por millón de registros.

**Problema real encontrado solo en Windows (y corregido):** `build-image.sh` falló con `unable to prepare context: path ".../vibranium-orderbook-meli" not found`.
La causa era `MSYS_NO_PATHCONV=1` (necesario para otros comandos): hacía que `docker.exe` recibiera una ruta estilo `/c/Users/...`, que no entiende.
Ahora el script la convierte con `cygpath -m` solo para `docker build` (commit `fb0ec48`). El CI en Linux no podía detectarlo, y por eso es útil ejecutar también en la máquina del autor.

## Prueba de humo (ejecución 2 y 3): 19/19 comprobaciones

- El tráfico entra **por el ingress**: `/readyz` y `/healthz` = 200.
- Ciclo de órdenes: depósitos 204, venta y compra 201, mismo id → 409, id inválido → 400, auditoría de conservación `ok:true`.
- **Superficie expuesta:** `/metrics` y `/debug/pprof` responden 404 por el ingress (el puerto de administración 9102 no se publica).
- **Observabilidad conectada:** Prometheus ve el target en `up`, las **13 alertas** están cargadas, Grafana responde y el dashboard `orderbook-overview` está provisionado.
- **Historial en Postgres a través de las NetworkPolicy:** `lag = 0` y saldo del historial == saldo del motor.
- **Las NetworkPolicy se aplican de verdad en kind:** un pod sin etiqueta **no** alcanza a Postgres (resultado de la sonda `np-probe`). Esto corrige la duda que dejé en `PLATAFORMA.md` §6.

## Caos 1: crash del pod sin apagado ordenado (`chaos.sh kill-pod`)

Estado previo: dos usuarios con saldos, una orden de venta **parcialmente ejecutada** (4 de 10, con 1 trade) y una compra en reposo. Se mata `orderbook-0` con
`--grace-period=0 --force`.

| Comprobación | Resultado |
|---|---|
| El pod fue recreado (uid distinto) | ✅ |
| Saldos de ambos usuarios, la orden parcial con su trade y la auditoría (`total_brl`, `total_vib`) | ✅ **idénticos** antes y después |
| El servicio acepta órdenes de nuevo | ✅ (201) |
| **Tiempo hasta `/readyz = 200`** | **7.1 s** con sondas cada 5 s → **4.1 s** con sondas cada 2 s |

**Limitaciones de esta medición (hechos):** una sola muestra por configuración; el journal casi vacío (10 registros), así que **no incluye el coste de reproducir un
journal grande** (≈ 8 s por millón de registros según `DEFENSA_TECNICA.md` de la app); imagen ya presente en el nodo. Es el piso del RTO, no el valor para producción.
La mejora de 7.1 s a 4.1 s es consecuencia directa del periodo de la sonda (el periodo se suma al tiempo de recuperación), no de la app.

## Caos 2: Postgres caído (`chaos.sh postgres-down`)

| Con Postgres apagado (réplicas 0, volumen conservado) | Resultado |
|---|---|
| El mercado sigue aceptando órdenes | ✅ 201 |
| `/readyz` | ✅ 200 (Postgres no es requisito para recibir tráfico) |
| Endpoints de historial | ✅ 503 (degradación explícita) |
| Al restaurarlo, el historial se pone al día solo | ✅ `lag 0` en unos 3 s |
| Saldo del historial == saldo del motor | ✅ |

## Lo que sigue SIN probarse

- Staging y prod: validados estáticamente, **nunca desplegados**.
- Carga sostenida a través del ingress (JMeter contra el cluster): no ejecutada. La capacidad medida en la app se midió sin ingress.
- Pérdida de un **nodo** (el volumen `standard` de kind está atado al nodo): no aplica con un solo nodo.
- RTO con un journal grande, y arranque en frío con la imagen sin cachear.
- Ejecución en la laptop del autor (Docker Desktop/WSL2): solo el CI de GitHub la ha corrido hasta ahora.
