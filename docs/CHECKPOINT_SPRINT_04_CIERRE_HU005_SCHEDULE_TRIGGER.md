# VIAJERO DATA PLATFORM

## CHECKPOINT — Sprint 4, cierre de HU-005: Backlog procesado, bug de comas resuelto, sincronización automatizada

**Fecha:** Septiembre 2026

## Contexto

Continuación directa de `CHECKPOINT_SPRINT_04_HU005_PAGINACION_INCREMENTAL.md`.
En esa sesión quedó pendiente: activar el Schedule Trigger, correr
`02_PROCESS_LEADS` contra el volumen completo, y limpiar workflows
obsoletos. Todo esto se resolvió en esta sesión, más un bug nuevo
descubierto y corregido en el camino.

------------------------------------------------------------------------

# 1. Bug nuevo descubierto y resuelto: comas en texto libre rompen "Query Parameters"

## Síntoma

Al correr `02_PROCESS_LEADS` contra el backlog completo (21.074 registros
pendientes), falló con:
```
invalid input syntax for type bigint: "Familia y Suerte"
```//
Lead afectado: `lead_id 22200746`, `lead_name: "Dios, Familia y Suerte"`.

## Causa raíz — confirmada como bug conocido de n8n

El campo **"Query Parameters"** del nodo Postgres (operación Execute
Query) funciona como un string separado por comas. Cuando un valor
contiene una coma literal (como en un nombre de lead), el parser del
nodo lo confunde con un separador entre parámetros, cortando el valor
en dos y **corriendo todos los parámetros siguientes una posición hacia
adelante**. Confirmado en los issues oficiales de n8n:
- `github.com/n8n-io/n8n/issues/14955`
- `github.com/n8n-io/n8n/issues/16354`

Ambos cerrados como "not planned" por el equipo de n8n — no hay
corrección oficial prevista, la solución debe aplicarse del lado del
workflow.

## Solución aplicada

En vez de escribir el campo "Query Parameters" como texto con múltiples
expresiones `{{ }}` separadas por comas, se reemplaza por **una sola
expresión que evalúa a un arreglo de JavaScript**:

```
={{ [ $json.lead_id, $json.lead_name, $json.pipeline_id, $json.stage_id, $json.responsible_user_id, $json.price, $json.created_at, $json.updated_at, $json.closed_at, $json.source_id, $json.source_name, $json.staging_id ] }}
```

Cuando n8n detecta que el resultado ya es un array de JS, lo pasa
directo al driver de PostgreSQL sin volver a intentar separar por
comas — inmune a comas embebidas en cualquier campo de texto libre.

**⚠️ Importante para replicar en Contacts/Companies (Sprint 5):** este
mismo riesgo aplica a cualquier campo de texto libre (nombres,
direcciones, notas, nombres de empresas). Aplicar este mismo patrón de
arreglo desde el inicio en los nuevos UPSERT, no esperar a que falle.

------------------------------------------------------------------------

# 2. Ajuste de volumen en el nodo de lectura de staging

## Problema encontrado

El nodo que lee de `staging.leads_raw` tenía:
```sql
SELECT id, lead_id, payload
FROM staging.leads_raw
WHERE is_processed = FALSE
ORDER BY id
LIMIT 100;
```
Con 21.074 registros pendientes acumulados, este límite fijo solo
procesaba 100 por ejecución — habría requerido más de 200 corridas
manuales para cubrir el backlog.

## Ajuste aplicado

Se subió el límite a `25000` para cubrir el backlog completo en una
sola corrida. **Pendiente a futuro (no bloqueante):** una vez la
sincronización esté estabilizada en modo incremental normal (sin
backlog grande acumulándose), bajar este límite a un valor más
conservador (ej. `1000`-`5000`) para las corridas rutinarias.

------------------------------------------------------------------------

# 3. Validación completa Bronze → Silver, cerrada con éxito

## Resultados confirmados

- `staging.leads_raw` con `is_processed = FALSE`: **0 pendientes**
  después de la corrida completa (backlog de 21.074 procesado sin
  errores tras el fix del bug de comas).
- Lead 17081049 (Johana Manrique, capturado antes de eliminarse en
  Kommo — pipeline Remarketing / etapa "No llamar más"): confirmado
  presente tanto en `staging.leads_raw` como en `crm.leads`. **Caso de
  protección de datos validado de punta a punta.**
- Lead 22200746 ("Dios, Familia y Suerte", el caso del bug de comas):
  confirmado en `crm.leads` con todos los campos correctos
  (`pipeline_id`, `stage_id` como valores numéricos, no corrompidos).
- `SELECT COUNT(*) FROM crm.leads`: **15.124** registros — coherente
  con el total de `lead_id` únicos en staging (~15.102, con leve
  variación por nuevos leads sincronizados en el intervalo).

## Caso de control (limitación conocida, documentada, no un bug)

Lead 23431618: eliminado en Kommo antes de que cualquier sincronización
lo hubiera capturado. No existe en staging ni en Kommo (`204 No
Content` al consultarlo). **Confirma el límite de diseño esperado:** la
plataforma protege desde el momento en que empezó a sincronizar hacia
adelante, no retroactivamente antes de su implementación.

------------------------------------------------------------------------

# 4. Limpieza de workflows obsoletos — completada

Se eliminaron desde la interfaz de n8n:
- `01_kommo_extract_leads_raw`
- `My workflow`

**Workflows activos actuales (3 en total):**
1. `00_SYNC_MASTER_DATA`
2. `01_SYNC_LEADS`
3. `02_PROCESS_LEADS`

**Pendiente de confirmar:** si se alcanzó a exportar/respaldar el JSON
de los workflows eliminados antes de borrarlos. Si no se hizo, no es
crítico (ya se había confirmado que no tenían lógica necesaria), pero
debe quedar registrado así en la documentación en vez de asumir que el
respaldo existe.

**Pendiente de acción:** actualizar `README.md` / `docs/workflows.md`
en el repositorio con la lista final de 3 workflows activos, y hacer
commit.

------------------------------------------------------------------------

# 5. Automatización — Schedule Trigger configurado

## Configuración aplicada a `01_SYNC_LEADS`

- Nodo **Schedule Trigger** agregado, en paralelo al Manual Trigger
  existente (ambos disparan el mismo flujo, sin reemplazar el manual).
- **Trigger Rule:** Interval — cada **30 minutos**.
- Conectado directamente al nodo **"GET LAST SYNC"** (primer nodo real
  del flujo, después de cualquiera de los dos triggers).
- Confirmado **"Limit Pages Fetched" en OFF** antes de activar, para
  que la sincronización automática siempre traiga el total de páginas
  pendiente, sin límite artificial.
- Workflow marcado como **Active**.

## Pendiente de verificar en la próxima sesión

- Confirmar que la primera ejecución disparada automáticamente por el
  Schedule Trigger (no manual) aparezca en "Executions" con estado
  Success.
- Si el intervalo de 30 minutos resulta muy frecuente o insuficiente
  según el volumen real de cambios diarios, ajustar.

------------------------------------------------------------------------

# 6. Estado consolidado del proyecto

## Resuelto en esta sesión

- Bug de comas en Query Parameters — identificado, documentado y
  corregido con el patrón de arreglo JS.
- Backlog completo de staging (21.074 registros) procesado hacia
  `crm.leads` sin errores.
- Validación de punta a punta (Bronze → Silver) de dos casos reales:
  uno de protección exitosa (Johana Manrique) y uno de límite de diseño
  conocido (lead eliminado antes de cualquier sync).
- Limpieza de los 2 workflows obsoletos en n8n.
- Automatización activada vía Schedule Trigger (cada 30 min).

## Pendiente para la próxima sesión (en orden de prioridad)

1. Confirmar la primera ejecución automática del Schedule Trigger.
2. Actualizar `README.md`/`docs/workflows.md` con los 3 workflows
   activos y hacer commit.
3. Aplicar el mismo patrón de arreglo JS (Query Parameters) de forma
   preventiva al construir los UPSERT de Contacts/Companies — no
   esperar a que falle con un nombre o dirección que tenga coma.
4. Replicar el patrón completo (paginación nativa + sync_control +
   incremental) para `03_SYNC_CONTACTS` (Sprint 5) — recordar que
   Contactos/Compañías también estaban cerca del límite del plan
   Kommo (68.380/75.000 al momento del checkpoint anterior).
5. Validación exhaustiva automatizada Kommo↔BD más allá de las muestras
   manuales (sigue pendiente desde el checkpoint anterior).
6. Bajar el `LIMIT` del nodo de lectura de staging en
   `02_PROCESS_LEADS` a un valor rutinario (1000-5000) una vez
   confirmado que el backlog se mantiene bajo con la sincronización
   incremental funcionando.

------------------------------------------------------------------------

# Instrucciones para el siguiente chat

1. Leer este documento junto con
   `CHECKPOINT_SPRINT_04_HU005_PAGINACION_INCREMENTAL.md` (checkpoint
   previo) antes de continuar.
2. No reconstruir nada de lo ya resuelto: paginación, sync incremental,
   bug de comas, y Schedule Trigger ya están funcionando.
3. Prioridad inmediata: confirmar la primera corrida automática, luego
   avanzar a replicar el patrón completo para Contacts, aplicando desde
   el inicio el fix de Query Parameters como arreglo JS.
4. Mantener el estilo de trabajo establecido: pasos concretos y
   accionables con el porqué breve; toda query o nodo nuevo se prueba
   primero en modo controlado antes de aplicarse al volumen completo.
