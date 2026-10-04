

WITH latest AS (
    SELECT DISTINCT ON (sr.lead_id)
        sr.lead_id,
        sr.payload
    FROM staging.leads_raw sr
    WHERE sr.lead_id IN (
        22665076,
        22684836,
        22753708,
        22664188,
        22815660
    )
    ORDER BY sr.lead_id, sr.id DESC
)
SELECT
    lead_id,
    jsonb_pretty(payload->'custom_fields_values') AS custom_fields
FROM latest
ORDER BY lead_id;