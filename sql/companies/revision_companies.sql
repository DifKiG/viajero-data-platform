-- Revisión de staging.companies_raw (solo lectura; sin nombres ni datos personales)
-- Ejecuta cada bloque por separado.

-- 1) Totales
SELECT count(*) AS filas, count(DISTINCT company_id) AS companias_unicas FROM staging.companies_raw;

-- 2) Calidad básica (última foto por compañía)
WITH ult AS (
  SELECT DISTINCT ON (company_id) payload
  FROM staging.companies_raw
  ORDER BY company_id, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
x AS (
  SELECT payload,
         CASE WHEN jsonb_typeof(payload->'custom_fields_values') = 'array'
              THEN jsonb_array_length(payload->'custom_fields_values') ELSE 0 END AS n_campos,
         CASE WHEN jsonb_typeof(payload#>'{_embedded,contacts}') = 'array'
              THEN jsonb_array_length(payload#>'{_embedded,contacts}') ELSE 0 END AS n_contactos,
         CASE WHEN jsonb_typeof(payload#>'{_embedded,leads}') = 'array'
              THEN jsonb_array_length(payload#>'{_embedded,leads}') ELSE 0 END AS n_leads
  FROM ult)
SELECT count(*)                                                      AS companias,
       count(*) FILTER (WHERE btrim(COALESCE(payload->>'name','')) = '')   AS sin_nombre,
       count(*) FILTER (WHERE payload->>'name' ~ '^[0-9+ ().-]+$')         AS nombre_solo_numeros,
       count(*) FILTER (WHERE n_campos = 0)                          AS sin_campos_personalizados,
       count(*) FILTER (WHERE n_contactos > 0)                       AS con_contactos,
       count(*) FILTER (WHERE n_leads > 0)                           AS con_leads,
       count(*) FILTER (WHERE n_contactos = 0 AND n_leads = 0)       AS sin_contactos_ni_leads,
       min(to_timestamp((payload->>'created_at')::bigint))::date     AS creada_mas_antigua,
       max(to_timestamp((payload->>'created_at')::bigint))::date     AS creada_mas_reciente
FROM x;

-- 3) Campos personalizados más usados
WITH ult AS (
  SELECT DISTINCT ON (company_id) payload
  FROM staging.companies_raw
  ORDER BY company_id, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC)
SELECT f->>'field_id' AS field_id, f->>'field_name' AS campo, count(*) AS companias
FROM ult,
     jsonb_array_elements(CASE WHEN jsonb_typeof(payload->'custom_fields_values') = 'array'
                               THEN payload->'custom_fields_values' ELSE '[]'::jsonb END) f
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20;

-- 4) Creadas por año
SELECT date_part('year', to_timestamp((payload->>'created_at')::bigint))::int AS anio,
       count(DISTINCT company_id) AS companias
FROM staging.companies_raw GROUP BY 1 ORDER BY 1;

-- 5) Días con más compañías creadas (¿importación masiva?)
SELECT to_timestamp((payload->>'created_at')::bigint)::date AS dia, count(DISTINCT company_id) AS companias
FROM staging.companies_raw GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

-- 6) ¿Quién las creó? (por usuario; sin nombres de clientes)
SELECT payload->>'created_by' AS creado_por_user_id, count(DISTINCT company_id) AS companias
FROM staging.companies_raw GROUP BY 1 ORDER BY 2 DESC LIMIT 10;