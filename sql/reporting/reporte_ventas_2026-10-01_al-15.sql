-- =====================================================================
-- REPORTE DE VENTAS 1 al 15 de octubre de 2026  (Viajero Calificado)
-- Fuente: staging.leads_raw (último snapshot de cada lead). Solo lectura.
-- Ejecutar cada bloque por separado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0A. Chequeos previos (cobertura de datos)
-- ---------------------------------------------------------------------
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS lead_id,
         payload
  FROM staging.leads_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST,
           id DESC
)
SELECT
  count(*)                                                        AS leads_unicos,
  count(*) FILTER (WHERE jsonb_path_exists(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1016729)'))   AS con_fecha_compra,
  count(*) FILTER (WHERE jsonb_array_length(
        COALESCE(payload #> '{_embedded,contacts}', '[]'::jsonb)) > 0) AS con_contactos_en_payload
FROM ult;

-- ---------------------------------------------------------------------
-- BLOQUE 0B. Valores reales del campo Género (para confirmar qué significa cada uno)
-- ---------------------------------------------------------------------
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS lead_id,
         payload
  FROM staging.leads_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST,
           id DESC
)
SELECT v->>'value' AS valor, v->>'enum_id' AS enum_id, count(*) AS leads
FROM ult,
     jsonb_path_query(payload,
       '$.custom_fields_values[*] ? (@.field_id == 1020396).values[*]') AS v
GROUP BY 1, 2
ORDER BY leads DESC;

-- ---------------------------------------------------------------------
-- BLOQUE 1. DETALLE: una fila por venta (fecha de compra entre 1 y 15 oct, todos los pipelines)
-- ---------------------------------------------------------------------
WITH params AS (
  -- Rango del reporte (hora de Colombia). 'hasta_excl' es exclusivo: 16 oct 00:00 = incluye todo el 15.
  SELECT DATE '2026-10-01' AS desde,
         DATE '2026-10-16' AS hasta_excl
),
ult AS (
  -- Último snapshot de cada lead (leads_raw guarda varias versiones por lead)
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS lead_id,
         payload
  FROM staging.leads_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST,
           id DESC
),
leads AS (
  SELECT
    lead_id,
    payload->>'name'                         AS nombre_lead,
    (payload->>'pipeline_id')::bigint        AS pipeline_id,
    (payload->>'status_id')::bigint          AS stage_id,
    (payload->>'price')::numeric             AS precio,
    to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota' AS creado_en,
    to_timestamp(NULLIF(jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1016729).values[0].value') #>> '{}', '')::bigint)
      AT TIME ZONE 'America/Bogota'          AS fecha_compra,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1017098).values[0].value') #>> '{}' AS campana,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1009192).values[0].value') #>> '{}' AS destino,
    COALESCE(
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1009190).values[0].value') #>> '{}',
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1020628).values[0].value') #>> '{}'
    )                                        AS ciudad_lead,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1020396).values[0].value') #>> '{}' AS genero,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1043890).values[0].value') #>> '{}' AS personas_txt
  FROM ult
  WHERE COALESCE(payload->>'is_deleted', 'false') <> 'true'
),
l2 AS (
  SELECT *,
         -- primer número del texto; solo si tiene 1-2 dígitos (evita teléfonos u otros datos mal digitados en el campo)
         CASE WHEN (regexp_match(personas_txt, '\d+'))[1] ~ '^\d{1,2}$'
              THEN ((regexp_match(personas_txt, '\d+'))[1])::int END AS personas
  FROM leads
)
SELECT
  lead_id,
  nombre_lead,
  CASE pipeline_id WHEN 11608463 THEN 'VENTAS CALI'
                   WHEN 11608479 THEN 'VENTAS BGTA'
                   WHEN 10684275 THEN 'SERVICIO AL CLIENTE'
                   ELSE pipeline_id::text END          AS pipeline,
  fecha_compra::date                                    AS fecha_compra,
  creado_en::date                                       AS fecha_creacion_lead,
  (fecha_compra::date - creado_en::date)                AS dias_hasta_compra,
  campana,
  destino,
  ciudad_lead,
  genero,
  personas,
  CASE WHEN personas IS NULL THEN NULL
       WHEN personas = 1 THEN 'Individual'
       WHEN personas = 2 THEN 'Pareja (inferido)'
       ELSE 'Familia/grupo (inferido)' END              AS tipo_viaje,
  precio
FROM l2, params p
WHERE fecha_compra >= p.desde AND fecha_compra < p.hasta_excl
ORDER BY fecha_compra, lead_id;

-- ---------------------------------------------------------------------
-- BLOQUE 2. RESUMEN: ventas por dimensión, captación de leads y conversión
-- ---------------------------------------------------------------------
WITH params AS (
  -- Rango del reporte (hora de Colombia). 'hasta_excl' es exclusivo: 16 oct 00:00 = incluye todo el 15.
  SELECT DATE '2026-10-01' AS desde,
         DATE '2026-10-16' AS hasta_excl
),
ult AS (
  -- Último snapshot de cada lead (leads_raw guarda varias versiones por lead)
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS lead_id,
         payload
  FROM staging.leads_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST,
           id DESC
),
leads AS (
  SELECT
    lead_id,
    payload->>'name'                         AS nombre_lead,
    (payload->>'pipeline_id')::bigint        AS pipeline_id,
    (payload->>'status_id')::bigint          AS stage_id,
    (payload->>'price')::numeric             AS precio,
    to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota' AS creado_en,
    to_timestamp(NULLIF(jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1016729).values[0].value') #>> '{}', '')::bigint)
      AT TIME ZONE 'America/Bogota'          AS fecha_compra,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1017098).values[0].value') #>> '{}' AS campana,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1009192).values[0].value') #>> '{}' AS destino,
    COALESCE(
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1009190).values[0].value') #>> '{}',
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1020628).values[0].value') #>> '{}'
    )                                        AS ciudad_lead,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1020396).values[0].value') #>> '{}' AS genero,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1043890).values[0].value') #>> '{}' AS personas_txt
  FROM ult
  WHERE COALESCE(payload->>'is_deleted', 'false') <> 'true'
),
l2 AS (
  SELECT *,
         -- primer número del texto; solo si tiene 1-2 dígitos (evita teléfonos u otros datos mal digitados en el campo)
         CASE WHEN (regexp_match(personas_txt, '\d+'))[1] ~ '^\d{1,2}$'
              THEN ((regexp_match(personas_txt, '\d+'))[1])::int END AS personas
  FROM leads
),
ventas AS (
  SELECT l.* FROM l2 l, params p
  WHERE l.fecha_compra >= p.desde AND l.fecha_compra < p.hasta_excl
),
captados AS (   -- leads creados en el rango (todos los pipelines)
  SELECT l.* FROM l2 l, params p
  WHERE l.creado_en >= p.desde AND l.creado_en < p.hasta_excl
),
resumen AS (
  SELECT 1 AS ord, 'Ventas (total)' AS seccion, 'total' AS clave,
         count(*)::numeric AS n, NULL::numeric AS pct
  FROM ventas
  UNION ALL SELECT 2, 'Ventas por campaña', COALESCE(campana, '(sin dato)'),
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 3, 'Ventas por destino', COALESCE(destino, '(sin dato)'),
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 4, 'Ventas por ciudad (del lead)', COALESCE(ciudad_lead, '(sin dato)'),
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 5, 'Ventas por género (valor crudo)', COALESCE(genero, '(sin dato)'),
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 6, 'Ventas por personas que viajan', COALESCE(personas::text, '(sin dato)'),
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 7, 'Ventas por pipeline',
         CASE pipeline_id WHEN 11608463 THEN 'VENTAS CALI' WHEN 11608479 THEN 'VENTAS BGTA'
                          WHEN 10684275 THEN 'SERVICIO AL CLIENTE' ELSE pipeline_id::text END,
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 8, 'Ventas por día de compra', fecha_compra::date::text,
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM ventas GROUP BY 3
  UNION ALL SELECT 9, 'Días entre creación del lead y compra (promedio)', 'promedio',
         round(avg(fecha_compra::date - creado_en::date), 1), NULL FROM ventas
  UNION ALL SELECT 9, 'Días entre creación del lead y compra (mediana)', 'mediana',
         percentile_cont(0.5) WITHIN GROUP (ORDER BY (fecha_compra::date - creado_en::date))::numeric,
         NULL FROM ventas
  UNION ALL SELECT 10, 'Leads captados (creados en el rango)', 'total',
         count(*), NULL FROM captados
  UNION ALL SELECT 11, 'Leads captados por campaña', COALESCE(campana, '(sin dato)'),
         count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1)
         FROM captados GROUP BY 3
  UNION ALL SELECT 12, 'Conversión simple: ventas del periodo / leads captados del periodo', 'total',
         (SELECT count(*) FROM ventas),
         round(100.0 * (SELECT count(*) FROM ventas) / NULLIF((SELECT count(*) FROM captados), 0), 1)
  UNION ALL SELECT 13, 'Conversión de cohorte: leads captados en el rango que ya compraron', 'total',
         count(*) FILTER (WHERE fecha_compra IS NOT NULL),
         round(100.0 * count(*) FILTER (WHERE fecha_compra IS NOT NULL) / NULLIF(count(*), 0), 1)
         FROM captados
  UNION ALL SELECT 14, 'Conversión de cohorte por campaña (n = compraron)', COALESCE(campana, '(sin dato)'),
         count(*) FILTER (WHERE fecha_compra IS NOT NULL),
         round(100.0 * count(*) FILTER (WHERE fecha_compra IS NOT NULL) / NULLIF(count(*), 0), 1)
         FROM captados GROUP BY 3
)
SELECT seccion, clave, n, pct
FROM resumen
ORDER BY ord, n DESC NULLS LAST, clave;

-- ---------------------------------------------------------------------
-- BLOQUE 3. EDAD Y CIUDAD DEL CONTACTO (una fila por venta)
-- Correr SOLO cuando el bloque 0A muestre contactos en el payload (con_contactos_en_payload > 0).
-- Regla: contacto con is_main = true; si no hay principal, el de menor id.
-- Edad = años cumplidos a la fecha de compra. Si la fecha de nacimiento no se puede interpretar queda NULL.
-- ---------------------------------------------------------------------
WITH params AS (
  -- Rango del reporte (hora de Colombia). 'hasta_excl' es exclusivo: 16 oct 00:00 = incluye todo el 15.
  SELECT DATE '2026-10-01' AS desde,
         DATE '2026-10-16' AS hasta_excl
),
ult AS (
  -- Último snapshot de cada lead (leads_raw guarda varias versiones por lead)
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS lead_id,
         payload
  FROM staging.leads_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST,
           id DESC
),
leads AS (
  SELECT
    lead_id,
    payload->>'name'                         AS nombre_lead,
    (payload->>'pipeline_id')::bigint        AS pipeline_id,
    (payload->>'status_id')::bigint          AS stage_id,
    (payload->>'price')::numeric             AS precio,
    to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota' AS creado_en,
    to_timestamp(NULLIF(jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1016729).values[0].value') #>> '{}', '')::bigint)
      AT TIME ZONE 'America/Bogota'          AS fecha_compra,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1017098).values[0].value') #>> '{}' AS campana,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1009192).values[0].value') #>> '{}' AS destino,
    COALESCE(
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1009190).values[0].value') #>> '{}',
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1020628).values[0].value') #>> '{}'
    )                                        AS ciudad_lead,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1020396).values[0].value') #>> '{}' AS genero,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1043890).values[0].value') #>> '{}' AS personas_txt
  FROM ult
  WHERE COALESCE(payload->>'is_deleted', 'false') <> 'true'
),
l2 AS (
  SELECT *,
         -- primer número del texto; solo si tiene 1-2 dígitos (evita teléfonos u otros datos mal digitados en el campo)
         CASE WHEN (regexp_match(personas_txt, '\d+'))[1] ~ '^\d{1,2}$'
              THEN ((regexp_match(personas_txt, '\d+'))[1])::int END AS personas
  FROM leads
),
ventas AS (
  SELECT l.* FROM l2 l, params p
  WHERE l.fecha_compra >= p.desde AND l.fecha_compra < p.hasta_excl
),
vc AS (   -- contactos asociados a cada venta (vienen en _embedded.contacts del lead)
  SELECT u.lead_id,
         (c->>'id')::bigint AS contact_id,
         COALESCE((c->>'is_main')::boolean, false) AS is_main
  FROM ult u,
       jsonb_array_elements(COALESCE(u.payload #> '{_embedded,contacts}', '[]'::jsonb)) AS c
  WHERE u.lead_id IN (SELECT lead_id FROM ventas)
),
elegido AS (
  SELECT DISTINCT ON (lead_id)
         lead_id, contact_id,
         count(*) OVER (PARTITION BY lead_id) AS n_contactos
  FROM vc
  ORDER BY lead_id, is_main DESC, contact_id
),
cont AS (   -- último snapshot de cada contacto
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS contact_id, payload
  FROM staging.contacts_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
),
cont2 AS (
  SELECT contact_id,
         payload->>'name' AS nombre_contacto,
         jsonb_path_query_first(payload,
           '$.custom_fields_values[*] ? (@.field_id == 1008538).values[0].value') #>> '{}' AS ciudad_contacto,
         jsonb_path_query_first(payload,
           '$.custom_fields_values[*] ? (@.field_id == 1020420).values[0].value') #>> '{}' AS nacimiento_txt
  FROM cont
),
nac AS (   -- limpia espacios raros (incl. no separables) y pasa a minúsculas
  SELECT *,
         lower(btrim(regexp_replace(translate(nacimiento_txt, chr(160) || chr(8199) || chr(8239) || chr(8201) || chr(8203), '    '), '\s+', ' ', 'g'))) AS t
  FROM cont2
),
nac1 AS (
  SELECT *,
         -- mes en texto: "10 agosto 1983", "8 de marzo del 1976", "10-septiembre-1997"
         regexp_match(t, '^(\d{1,2})[ ./-]+(?:del? )?([a-záéíóú]+)[ ./-]+(?:del? )?(\d{4})$') AS ma,
         -- numérica día/mes/año: "27/09/1990", "12/ 04 /1976"
         regexp_match(t, '^(\d{1,2}) ?[./-] ?(\d{1,2}) ?[./-] ?(\d{4})$') AS mb
  FROM nac
),
nac2 AS (
  SELECT *,
         COALESCE(ma[1], mb[1])::int AS dia,
         CASE WHEN ma IS NOT NULL
                   THEN array_position(ARRAY['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'], left(ma[2], 3))
              WHEN mb IS NOT NULL THEN (mb[2])::int END AS mes,
         COALESCE(ma[3], mb[3])::int AS anio
  FROM nac1
),
nac3 AS (   -- fecha válida o NULL (31 de febrero, mes 13, etc. quedan NULL; no se inventa nada)
  SELECT *,
         CASE WHEN mes BETWEEN 1 AND 12 AND anio BETWEEN 1900 AND 2100 AND dia BETWEEN 1 AND 31
              THEN CASE WHEN extract(month FROM make_date(anio, mes, 1) + (dia - 1)) = mes
                        THEN make_date(anio, mes, 1) + (dia - 1) END
         END AS fecha_nacimiento,
         CASE WHEN mb IS NOT NULL AND (mb[1])::int <= 12 AND (mb[2])::int <= 12
                   AND (mb[1])::int <> (mb[2])::int
              THEN 'dd/mm asumido (ambigua)' END AS nota_fecha
  FROM nac2
),
detalle AS (
  SELECT v.lead_id, v.nombre_lead, v.fecha_compra::date AS fecha_compra,
         e.contact_id, e.n_contactos,
         c.nombre_contacto, c.ciudad_contacto, v.ciudad_lead,
         COALESCE(c.ciudad_contacto, v.ciudad_lead) AS ciudad_cliente,
         c.nacimiento_txt, c.fecha_nacimiento, c.nota_fecha,
         CASE WHEN date_part('year', age(v.fecha_compra::date, c.fecha_nacimiento)) BETWEEN 14 AND 100
              THEN date_part('year', age(v.fecha_compra::date, c.fecha_nacimiento))::int END AS edad
  FROM ventas v
  LEFT JOIN elegido e ON e.lead_id = v.lead_id
  LEFT JOIN nac3 c    ON c.contact_id = e.contact_id
)
SELECT * FROM detalle ORDER BY fecha_compra, lead_id;

-- ---------------------------------------------------------------------
-- BLOQUE 3B. Ventas por rango de edad
-- ---------------------------------------------------------------------
WITH params AS (
  -- Rango del reporte (hora de Colombia). 'hasta_excl' es exclusivo: 16 oct 00:00 = incluye todo el 15.
  SELECT DATE '2026-10-01' AS desde,
         DATE '2026-10-16' AS hasta_excl
),
ult AS (
  -- Último snapshot de cada lead (leads_raw guarda varias versiones por lead)
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS lead_id,
         payload
  FROM staging.leads_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST,
           id DESC
),
leads AS (
  SELECT
    lead_id,
    payload->>'name'                         AS nombre_lead,
    (payload->>'pipeline_id')::bigint        AS pipeline_id,
    (payload->>'status_id')::bigint          AS stage_id,
    (payload->>'price')::numeric             AS precio,
    to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota' AS creado_en,
    to_timestamp(NULLIF(jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1016729).values[0].value') #>> '{}', '')::bigint)
      AT TIME ZONE 'America/Bogota'          AS fecha_compra,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1017098).values[0].value') #>> '{}' AS campana,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1009192).values[0].value') #>> '{}' AS destino,
    COALESCE(
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1009190).values[0].value') #>> '{}',
      jsonb_path_query_first(payload,
        '$.custom_fields_values[*] ? (@.field_id == 1020628).values[0].value') #>> '{}'
    )                                        AS ciudad_lead,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1020396).values[0].value') #>> '{}' AS genero,
    jsonb_path_query_first(payload,
      '$.custom_fields_values[*] ? (@.field_id == 1043890).values[0].value') #>> '{}' AS personas_txt
  FROM ult
  WHERE COALESCE(payload->>'is_deleted', 'false') <> 'true'
),
l2 AS (
  SELECT *,
         -- primer número del texto; solo si tiene 1-2 dígitos (evita teléfonos u otros datos mal digitados en el campo)
         CASE WHEN (regexp_match(personas_txt, '\d+'))[1] ~ '^\d{1,2}$'
              THEN ((regexp_match(personas_txt, '\d+'))[1])::int END AS personas
  FROM leads
),
ventas AS (
  SELECT l.* FROM l2 l, params p
  WHERE l.fecha_compra >= p.desde AND l.fecha_compra < p.hasta_excl
),
vc AS (   -- contactos asociados a cada venta (vienen en _embedded.contacts del lead)
  SELECT u.lead_id,
         (c->>'id')::bigint AS contact_id,
         COALESCE((c->>'is_main')::boolean, false) AS is_main
  FROM ult u,
       jsonb_array_elements(COALESCE(u.payload #> '{_embedded,contacts}', '[]'::jsonb)) AS c
  WHERE u.lead_id IN (SELECT lead_id FROM ventas)
),
elegido AS (
  SELECT DISTINCT ON (lead_id)
         lead_id, contact_id,
         count(*) OVER (PARTITION BY lead_id) AS n_contactos
  FROM vc
  ORDER BY lead_id, is_main DESC, contact_id
),
cont AS (   -- último snapshot de cada contacto
  SELECT DISTINCT ON ((payload->>'id')::bigint)
         (payload->>'id')::bigint AS contact_id, payload
  FROM staging.contacts_raw
  WHERE payload->>'id' IS NOT NULL
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
),
cont2 AS (
  SELECT contact_id,
         payload->>'name' AS nombre_contacto,
         jsonb_path_query_first(payload,
           '$.custom_fields_values[*] ? (@.field_id == 1008538).values[0].value') #>> '{}' AS ciudad_contacto,
         jsonb_path_query_first(payload,
           '$.custom_fields_values[*] ? (@.field_id == 1020420).values[0].value') #>> '{}' AS nacimiento_txt
  FROM cont
),
nac AS (   -- limpia espacios raros (incl. no separables) y pasa a minúsculas
  SELECT *,
         lower(btrim(regexp_replace(translate(nacimiento_txt, chr(160) || chr(8199) || chr(8239) || chr(8201) || chr(8203), '    '), '\s+', ' ', 'g'))) AS t
  FROM cont2
),
nac1 AS (
  SELECT *,
         -- mes en texto: "10 agosto 1983", "8 de marzo del 1976", "10-septiembre-1997"
         regexp_match(t, '^(\d{1,2})[ ./-]+(?:del? )?([a-záéíóú]+)[ ./-]+(?:del? )?(\d{4})$') AS ma,
         -- numérica día/mes/año: "27/09/1990", "12/ 04 /1976"
         regexp_match(t, '^(\d{1,2}) ?[./-] ?(\d{1,2}) ?[./-] ?(\d{4})$') AS mb
  FROM nac
),
nac2 AS (
  SELECT *,
         COALESCE(ma[1], mb[1])::int AS dia,
         CASE WHEN ma IS NOT NULL
                   THEN array_position(ARRAY['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'], left(ma[2], 3))
              WHEN mb IS NOT NULL THEN (mb[2])::int END AS mes,
         COALESCE(ma[3], mb[3])::int AS anio
  FROM nac1
),
nac3 AS (   -- fecha válida o NULL (31 de febrero, mes 13, etc. quedan NULL; no se inventa nada)
  SELECT *,
         CASE WHEN mes BETWEEN 1 AND 12 AND anio BETWEEN 1900 AND 2100 AND dia BETWEEN 1 AND 31
              THEN CASE WHEN extract(month FROM make_date(anio, mes, 1) + (dia - 1)) = mes
                        THEN make_date(anio, mes, 1) + (dia - 1) END
         END AS fecha_nacimiento,
         CASE WHEN mb IS NOT NULL AND (mb[1])::int <= 12 AND (mb[2])::int <= 12
                   AND (mb[1])::int <> (mb[2])::int
              THEN 'dd/mm asumido (ambigua)' END AS nota_fecha
  FROM nac2
),
detalle AS (
  SELECT v.lead_id, v.nombre_lead, v.fecha_compra::date AS fecha_compra,
         e.contact_id, e.n_contactos,
         c.nombre_contacto, c.ciudad_contacto, v.ciudad_lead,
         COALESCE(c.ciudad_contacto, v.ciudad_lead) AS ciudad_cliente,
         c.nacimiento_txt, c.fecha_nacimiento, c.nota_fecha,
         CASE WHEN date_part('year', age(v.fecha_compra::date, c.fecha_nacimiento)) BETWEEN 14 AND 100
              THEN date_part('year', age(v.fecha_compra::date, c.fecha_nacimiento))::int END AS edad
  FROM ventas v
  LEFT JOIN elegido e ON e.lead_id = v.lead_id
  LEFT JOIN nac3 c    ON c.contact_id = e.contact_id
)
SELECT CASE WHEN edad IS NULL THEN '(sin edad)'
            WHEN edad < 26 THEN '18-25' WHEN edad < 36 THEN '26-35'
            WHEN edad < 46 THEN '36-45' WHEN edad < 56 THEN '46-55'
            ELSE '56+' END AS rango_edad,
       count(*) AS ventas,
       round(avg(edad), 1) AS edad_promedio
FROM detalle
GROUP BY 1
ORDER BY 1;