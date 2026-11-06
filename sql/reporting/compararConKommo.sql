-- Después de la conciliación: lo activo en la BD debe coincidir con Kommo.
-- Compara estos números con los que muestra Kommo (leads, y contactos + compañías).
SELECT 'leads activos' AS concepto, count(*) AS en_bd FROM crm.leads     WHERE archived_in_crm_at IS NULL
UNION ALL SELECT 'contactos activos',  count(*) FROM crm.contacts  WHERE archived_in_crm_at IS NULL
UNION ALL SELECT 'compañías activas',  count(*) FROM crm.companies WHERE archived_in_crm_at IS NULL
UNION ALL SELECT 'contactos + compañías activos',
         (SELECT count(*) FROM crm.contacts WHERE archived_in_crm_at IS NULL)
       + (SELECT count(*) FROM crm.companies WHERE archived_in_crm_at IS NULL);

-- Leads activos por pipeline (compáralos con cada pipeline en Kommo)
SELECT COALESCE(p.pipeline_name, l.pipeline_id::text) AS pipeline, count(*) AS leads_activos
FROM crm.leads l LEFT JOIN crm.dim_pipeline p ON p.pipeline_id = l.pipeline_id
WHERE l.archived_in_crm_at IS NULL
GROUP BY 1 ORDER BY 2 DESC;

-- Los 22 leads que están en crm.leads pero no en staging (investigación)
SELECT pipeline_id, is_deleted, count(*) AS leads,
       min(created_at)::date AS creado_min, max(created_at)::date AS creado_max,
       min(synced_at)::date  AS sync_min,   max(synced_at)::date  AS sync_max
FROM crm.leads l
WHERE NOT EXISTS (SELECT 1 FROM staging.leads_raw s WHERE (s.payload->>'id')::bigint = l.lead_id)
GROUP BY 1, 2 ORDER BY 3 DESC;