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
