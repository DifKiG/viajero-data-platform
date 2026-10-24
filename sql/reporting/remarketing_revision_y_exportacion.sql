-- ============================================================
-- REMARKETING (pipeline 11608495)
-- Ejecuta cada consulta por separado.
-- 1) REVISION por etapa   2) EXPORTACION a CSV (guardar fuera del VPS)
-- ============================================================

-- 1) REVISION
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
l AS (
  SELECT (payload->>'id')::bigint AS lead_id,
         (payload->>'status_id')::bigint AS stage_id,
         (payload->>'created_at')::bigint AS cr, (payload->>'updated_at')::bigint AS up,
         COALESCE((payload->>'price')::numeric,0) AS price,
         jsonb_path_exists(payload,'$.custom_fields_values[*] ? (@.field_id == 1016729)') AS compra,
         jsonb_typeof(payload #> '{_embedded,contacts}') = 'array' AS vivo
  FROM ult WHERE (payload->>'pipeline_id')::bigint = 11608495)
SELECT COALESCE(s.stage_name, l.stage_id::text) AS etapa,
       count(*) FILTER (WHERE vivo)                                   AS vivos_en_kommo,
       count(*) FILTER (WHERE NOT vivo)                               AS ya_borrados_en_kommo,
       count(*) FILTER (WHERE vivo AND compra)                        AS vivos_con_compra,
       count(*) FILTER (WHERE vivo AND price > 0)                     AS vivos_con_precio,
       count(*) FILTER (WHERE vivo AND EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id = l.lead_id)) AS vivos_con_contacto_en_bd,
       count(*) FILTER (WHERE vivo AND to_timestamp(up) > now() - interval '30 days') AS vivos_movidos_ult_30d,
       min(to_timestamp(cr))::date AS creado_min
FROM l LEFT JOIN crm.dim_stage s ON s.stage_id = l.stage_id
GROUP BY 1 ORDER BY 2 DESC;

-- 2) EXPORTACION (vivos en Kommo; exportar resultado a CSV)
WITH ultl AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
ultc AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.contacts_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
l AS (
  SELECT (payload->>'id')::bigint AS lead_id, payload->>'name' AS lead_nombre,
         (payload->>'status_id')::bigint AS stage_id,
         to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota' AS creado
  FROM ultl
  WHERE (payload->>'pipeline_id')::bigint = 11608495
    AND jsonb_typeof(payload #> '{_embedded,contacts}') = 'array'),
p AS (
  SELECT DISTINCT ON (lc.lead_id) lc.lead_id, lc.contact_id
  FROM crm.lead_contacts lc ORDER BY lc.lead_id, lc.is_main DESC, lc.contact_id)
SELECT l.lead_id, l.lead_nombre, COALESCE(s.stage_name, l.stage_id::text) AS etapa, l.creado::date AS creado,
       c.contact_id, c.contact_name, c.city AS ciudad,
       (SELECT v #>> '{}' FROM jsonb_path_query(uc.payload,
          '$.custom_fields_values[*] ? (@.field_code == "PHONE").values[*].value') v LIMIT 1) AS telefono
FROM l
LEFT JOIN crm.dim_stage s ON s.stage_id = l.stage_id
LEFT JOIN p            ON p.lead_id = l.lead_id
LEFT JOIN crm.contacts c ON c.contact_id = p.contact_id
LEFT JOIN ultc uc      ON (uc.payload->>'id')::bigint = c.contact_id
ORDER BY etapa, l.lead_id;