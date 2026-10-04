/*SELECT
    DATE_TRUNC('month', fecha_compra)::date AS mes,
    TO_CHAR(DATE_TRUNC('month', fecha_compra), 'TMMonth YYYY') AS nombre_mes,
    COUNT(*) AS ventas
FROM (
    SELECT DISTINCT ON (l.lead_id)

        l.lead_id,

        to_timestamp((
            SELECT elem->'values'->0->>'value'
            FROM jsonb_array_elements(
                CASE
                    WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
                    THEN sr.payload->'custom_fields_values'
                    ELSE '[]'::jsonb
                END
            ) elem
            WHERE (elem->>'field_id')::int = 1016729
        )::bigint) AS fecha_compra

    FROM crm.leads l

    JOIN staging.leads_raw sr
        ON sr.lead_id = l.lead_id

    WHERE
        -- Solo ventas realizadas durante julio, agosto y septiembre
        to_timestamp((
            SELECT elem->'values'->0->>'value'
            FROM jsonb_array_elements(
                CASE
                    WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
                    THEN sr.payload->'custom_fields_values'
                    ELSE '[]'::jsonb
                END
            ) elem
            WHERE (elem->>'field_id')::int = 1016729
        )::bigint)::date >= '2026-07-01'

        AND to_timestamp((
            SELECT elem->'values'->0->>'value'
            FROM jsonb_array_elements(
                CASE
                    WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
                    THEN sr.payload->'custom_fields_values'
                    ELSE '[]'::jsonb
                END
            ) elem
            WHERE (elem->>'field_id')::int = 1016729
        )::bigint)::date < '2026-10-01'

    ORDER BY
        l.lead_id,
        sr.id DESC
) ventas

GROUP BY
    DATE_TRUNC('month', fecha_compra)

ORDER BY
    mes;*/

/*WITH latest AS (
    SELECT DISTINCT ON (sr.lead_id)
        sr.lead_id,
        sr.id AS staging_id,
        sr.payload
    FROM staging.leads_raw sr
    ORDER BY sr.lead_id, sr.id DESC
),
ventas AS (
    SELECT
        l.lead_id,
        l.lead_name,
        l.pipeline_id,
        to_timestamp(
            (
                SELECT elem->'values'->0->>'value'
                FROM jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(latest.payload->'custom_fields_values') = 'array'
                        THEN latest.payload->'custom_fields_values'
                        ELSE '[]'::jsonb
                    END
                ) elem
                WHERE (elem->>'field_id')::int = 1016729
                LIMIT 1
            )::bigint
        ) AS fecha_compra
    FROM latest
    JOIN crm.leads l
        ON l.lead_id = latest.lead_id
)
SELECT
    lead_id,
    lead_name,
    fecha_compra,
    fecha_compra AT TIME ZONE 'America/Bogota' AS fecha_compra_colombia
FROM ventas
WHERE fecha_compra >= '2026-07-01'
  AND fecha_compra < '2026-10-01'
ORDER BY fecha_compra;*/

WITH latest AS (
    SELECT DISTINCT ON (sr.lead_id)
        sr.lead_id,
        sr.payload
    FROM staging.leads_raw sr
    ORDER BY sr.lead_id, sr.id DESC
),
ventas AS (
    SELECT
        l.lead_id,
        to_timestamp(
            (
                SELECT elem->'values'->0->>'value'
                FROM jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(latest.payload->'custom_fields_values') = 'array'
                        THEN latest.payload->'custom_fields_values'
                        ELSE '[]'::jsonb
                    END
                ) elem
                WHERE (elem->>'field_id')::int = 1016729
                LIMIT 1
            )::bigint
        ) AT TIME ZONE 'America/Bogota' AS fecha_compra
    FROM latest
    JOIN crm.leads l
        ON l.lead_id = latest.lead_id
)
SELECT
    DATE_TRUNC('month', fecha_compra)::date AS mes,
    COUNT(*) AS ventas
FROM ventas
WHERE fecha_compra >= '2026-07-01'
  AND fecha_compra < '2026-10-01'
GROUP BY DATE_TRUNC('month', fecha_compra)
ORDER BY mes;


WITH latest AS (
    SELECT DISTINCT ON (sr.lead_id)
        sr.lead_id,
        sr.payload
    FROM staging.leads_raw sr
    ORDER BY sr.lead_id, sr.id DESC
),
ventas AS (
    SELECT
        l.lead_id,
        l.lead_name,
        to_timestamp(
            (
                SELECT elem->'values'->0->>'value'
                FROM jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(latest.payload->'custom_fields_values') = 'array'
                        THEN latest.payload->'custom_fields_values'
                        ELSE '[]'::jsonb
                    END
                ) elem
                WHERE (elem->>'field_id')::int = 1016729
                LIMIT 1
            )::bigint
        ) AT TIME ZONE 'America/Bogota' AS fecha_compra
    FROM latest
    JOIN crm.leads l
        ON l.lead_id = latest.lead_id
)
SELECT
    lead_id,
    lead_name,
    fecha_compra
FROM ventas
WHERE fecha_compra >= '2026-07-01'
  AND fecha_compra < '2026-10-01'
ORDER BY fecha_compra;