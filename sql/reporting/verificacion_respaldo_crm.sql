-- ============================================================
-- ¿Está todo lo del CRM en la base de datos?  (solo lectura)
-- Ejecuta cada bloque por separado y compara con los números de Kommo.
-- ============================================================

-- BLOQUE 1: ¿Los flujos están alimentando la BD? (frescura)
-- minutos_desde debe ser < ~40 para leads y contactos. Compañías puede tardar más
-- si no hubo cambios en Kommo.
SELECT 'leads' AS entidad, max(extracted_at) AS ultima_extraccion,
       round(extract(epoch FROM now() - max(extracted_at)) / 60) AS minutos_desde
FROM staging.leads_raw
UNION ALL
SELECT 'contactos', max(extracted_at), round(extract(epoch FROM now() - max(extracted_at)) / 60)
FROM staging.contacts_raw
UNION ALL
SELECT 'companias', max(extracted_at), round(extract(epoch FROM now() - max(extracted_at)) / 60)
FROM staging.companies_raw;

-- BLOQUE 2: staging (fotos) vs crm (tablas limpias). Las diferencias deben ser ~0.
SELECT 'leads' AS entidad,
       (SELECT count(DISTINCT (payload->>'id')::bigint) FROM staging.leads_raw)           AS en_staging,
       (SELECT count(*) FROM crm.leads)                                                    AS en_crm,
       (SELECT count(*) FROM (SELECT DISTINCT (payload->>'id')::bigint AS id FROM staging.leads_raw) s
         WHERE NOT EXISTS (SELECT 1 FROM crm.leads x WHERE x.lead_id = s.id))              AS en_staging_y_no_en_crm
UNION ALL
SELECT 'contactos',
       (SELECT count(DISTINCT contact_id) FROM staging.contacts_raw),
       (SELECT count(*) FROM crm.contacts),
       (SELECT count(*) FROM (SELECT DISTINCT contact_id FROM staging.contacts_raw) s
         WHERE NOT EXISTS (SELECT 1 FROM crm.contacts x WHERE x.contact_id = s.contact_id))
UNION ALL
SELECT 'companias',
       (SELECT count(DISTINCT company_id) FROM staging.companies_raw),
       (SELECT count(*) FROM crm.companies),
       (SELECT count(*) FROM (SELECT DISTINCT company_id FROM staging.companies_raw) s
         WHERE NOT EXISTS (SELECT 1 FROM crm.companies x WHERE x.company_id = s.company_id));

-- BLOQUE 3: integridad de las fotos guardadas (todo debe dar 0)
SELECT 'leads_raw' AS tabla,
       count(*) FILTER (WHERE payload IS NULL OR jsonb_typeof(payload) <> 'object')       AS payload_invalido,
       count(*) FILTER (WHERE lead_id IS DISTINCT FROM (payload->>'id')::bigint)           AS id_no_coincide
FROM staging.leads_raw
UNION ALL
SELECT 'contacts_raw',
       count(*) FILTER (WHERE payload IS NULL OR jsonb_typeof(payload) <> 'object'),
       count(*) FILTER (WHERE contact_id IS DISTINCT FROM (payload->>'id')::bigint)
FROM staging.contacts_raw
UNION ALL
SELECT 'companies_raw',
       count(*) FILTER (WHERE payload IS NULL OR jsonb_typeof(payload) <> 'object'),
       count(*) FILTER (WHERE company_id IS DISTINCT FROM (payload->>'id')::bigint)
FROM staging.companies_raw;

-- BLOQUE 4: leads por pipeline en la BD, para comparar con el total de cada pipeline en Kommo.
-- "vivos probables" = su última foto ya incluye la lista de contactos (posterior al backfill).
-- "posiblemente borrados" = última foto vieja: ya no existen en Kommo o no cambian desde antes.
-- OJO: hasta que hagamos la conciliación de IDs, los borrados siguen contando como vivos en la BD.
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC)
SELECT COALESCE(p.pipeline_name, (u.payload->>'pipeline_id')) AS pipeline,
       count(*) FILTER (WHERE jsonb_typeof(u.payload #> '{_embedded,contacts}') = 'array')     AS vivos_probables,
       count(*) FILTER (WHERE jsonb_typeof(u.payload #> '{_embedded,contacts}') IS DISTINCT FROM 'array') AS posiblemente_borrados,
       count(*) AS total_en_bd
FROM ult u
LEFT JOIN crm.dim_pipeline p ON p.pipeline_id = (u.payload->>'pipeline_id')::bigint
GROUP BY 1 ORDER BY 2 DESC;

-- BLOQUE 5: relación lead <-> contacto
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) (payload->>'id')::bigint AS lead_id, payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
vivos AS (SELECT * FROM ult WHERE jsonb_typeof(payload #> '{_embedded,contacts}') = 'array')
SELECT count(*)                                                                         AS leads_vivos_probables,
       count(*) FILTER (WHERE jsonb_array_length(payload #> '{_embedded,contacts}') = 0) AS sin_contacto_en_kommo,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id = vivos.lead_id)) AS con_relacion_en_bd,
       count(*) FILTER (WHERE jsonb_array_length(payload #> '{_embedded,contacts}') > 0
                          AND NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id = vivos.lead_id)) AS con_contacto_pero_sin_relacion
FROM vivos;

-- BLOQUE 6: pendientes de procesar (deben estar cerca de 0 entre ciclos)
SELECT 'contactos' AS entidad, count(*) AS sin_procesar FROM staging.contacts_raw WHERE NOT is_processed
UNION ALL
SELECT 'companias', count(*) FROM staging.companies_raw WHERE NOT is_processed;