/*SELECT id, payload->'custom_fields_values' AS custom_fields
FROM staging.leads_raw
WHERE lead_id = 23928236
ORDER BY id DESC;
*/

/*SELECT sr.id, elem->>'field_id' AS field_id, elem->>'field_name' AS field_name, elem->'values' AS values
FROM staging.leads_raw sr,
     jsonb_array_elements(sr.payload->'custom_fields_values') elem
WHERE sr.lead_id = 23928236
ORDER BY sr.id DESC;*/

/*SELECT 
    id,
    lead_id,
    (
        SELECT elem->'values'->0->>'value'
        FROM jsonb_array_elements(payload->'custom_fields_values') elem
        WHERE (elem->>'field_id')::int = 1009192
    ) AS destino
FROM staging.leads_raw
WHERE lead_id = 23928236
ORDER BY id DESC;*/

-- TOTAL DE LEADS QUE INGRESARON EN EL RANGO DE FECHAS ESTABLECIDAS --
SELECT COUNT(*) AS total_leads_ingresados
FROM crm.leads
WHERE created_at BETWEEN '2026-07-17' AND '2026-09-25 23:59:59';




    -- CONFIRMAR NOMBRE DE CAMPAÑAS --
/*SELECT DISTINCT
CASE WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array' THEN (
    SELECT elem->'values'->0->>'value'
    FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
    WHERE (elem ->>'field_id')::int =1017098
) END AS campaña
FROM crm.leads l 
JOIN staging.leads_raw sr ON sr.lead_id = l.lead_id
WHERE l.created_at BETWEEN '2026-07-17' AND '2026-09-25 23:59:59';*/

-- CANTIDAD TOTAL DE VENTAS EN EL RANGO (RESUMEN)
/*SELECT COUNT(DISTINCT l.lead_id) AS total_ventas
FROM crm.leads l
WHERE l.created_at BETWEEN '2026-07-17' AND '2026-09-05 23:59:59'
AND (
    l.pipeline_id IN (11608463, 11608479)
    OR l.stage_id = 104996631
);*/


-- 4. Chequeo específico: ¿la campaña de Estados Unidos tuvo ventas en el rango?
SELECT DISTINCT ON (l.lead_id)
    l.lead_id, l.lead_name, l.created_at
FROM crm.leads l
JOIN staging.leads_raw sr ON sr.lead_id = l.lead_id
WHERE l.created_at >= '2026-07-17' AND l.created_at < '2026-09-25'
  AND l.pipeline_id IN (11608463, 11608479)
  AND (
        SELECT elem->'values'->0->>'value'
        FROM jsonb_array_elements(
            CASE
                WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
                THEN sr.payload->'custom_fields_values'
                ELSE '[]'::jsonb
            END
        ) elem
        WHERE (elem->>'field_id')::int = 1017098
      ) ILIKE '%estados unidos%'
ORDER BY l.lead_id, sr.id DESC;


-- TOTAL DE VENTAS POR CAMPAÑA Y DESTINO EN EL RANGO DE FECHAS ESTABLECIDO --
SELECT DISTINCT ON (l.lead_id)

    l.lead_id,
    l.lead_name,

    -- Fecha en que ingresó el lead
    l.created_at AS fecha_creacion,

    -- Fecha real de compra
    to_timestamp((
        CASE
            WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
            THEN (
                SELECT elem->'values'->0->>'value'
                FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
                WHERE (elem->>'field_id')::int = 1016729
            )
        END
    )::bigint) AS fecha_compra,

    -- Pipeline donde se encuentra la venta
    dp.pipeline_name AS pipeline,

    -- Etapa
    ds.stage_name AS etapa,

    -- Campaña
    CASE
        WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
        THEN (
            SELECT elem->'values'->0->>'value'
            FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
            WHERE (elem->>'field_id')::int = 1017098
        )
    END AS campaña,

    -- Destino
    CASE
        WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
        THEN (
            SELECT elem->'values'->0->>'value'
            FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
            WHERE (elem->>'field_id')::int = 1009192
        )
    END AS destino,

    -- Días entre ingreso y compra
    (
        to_timestamp((
            CASE
                WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
                THEN (
                    SELECT elem->'values'->0->>'value'
                    FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
                    WHERE (elem->>'field_id')::int = 1016729
                )
            END
        )::bigint)::date - l.created_at::date
    ) AS Dias_de_Conversion

FROM crm.leads l

JOIN staging.leads_raw sr
    ON sr.lead_id = l.lead_id

LEFT JOIN crm.dim_pipeline dp
    ON dp.pipeline_id = l.pipeline_id

LEFT JOIN crm.dim_stage ds
    ON ds.stage_id = l.stage_id

WHERE
    -- PERÍODO DE VENTAS: 17/07/2026 → 25/09/2026
     to_timestamp((
        CASE
            WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
            THEN (
                SELECT elem->'values'->0->>'value'
                FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
                WHERE (elem->>'field_id')::int = 1016729
            )
        END
    )::bigint)::date >= '2026-07-17'

    AND to_timestamp((
        CASE
            WHEN jsonb_typeof(sr.payload->'custom_fields_values') = 'array'
            THEN (
                SELECT elem->'values'->0->>'value'
                FROM jsonb_array_elements(sr.payload->'custom_fields_values') elem
                WHERE (elem->>'field_id')::int = 1016729
            )
        END
    )::bigint)::date <= '2026-09-25'

ORDER BY
    l.lead_id,
    sr.id DESC;