-- ============================================================
-- Compañías de Kommo: clasificación para limpieza + exportación a CSV
-- Requiere haber corrido crear_companies_crm.sql y crm.process_companies().
-- Solo lectura. Guarda el CSV de la consulta B FUERA del VPS.
-- ============================================================

-- A) Resumen por categoría
WITH base AS (
  SELECT c.company_id, c.email, c.phone, c.created_by, c.created_at,
         (SELECT count(*) FROM crm.company_contacts cc WHERE cc.company_id = c.company_id) AS n_contactos,
         EXISTS (SELECT 1 FROM crm.company_contacts cc
                 JOIN crm.lead_contacts lc ON lc.contact_id = cc.contact_id
                 WHERE cc.company_id = c.company_id)   AS tiene_lead_vivo
  FROM crm.companies c
  WHERE c.archived_in_crm_at IS NULL)
SELECT CASE WHEN tiene_lead_vivo THEN '1 CONSERVAR: su contacto tiene lead vivo'
            WHEN n_contactos = 0 THEN '2 REVISAR: sin contacto'
            WHEN n_contactos > 1 THEN '3 REVISAR: varios contactos'
            ELSE '4 CANDIDATA a borrar (1 contacto, sin lead vivo)' END AS categoria,
       count(*)                                    AS companias,
       count(*) FILTER (WHERE email IS NOT NULL)   AS con_email,
       count(*) FILTER (WHERE phone IS NOT NULL)   AS con_telefono
FROM base GROUP BY 1 ORDER BY 1;

-- B) EXPORTACIÓN de las candidatas (guardar como CSV fuera del VPS)
SELECT c.company_id, cc.contact_id, c.email, c.phone, c.created_at::date AS creada, c.created_by
FROM crm.companies c
JOIN crm.company_contacts cc ON cc.company_id = c.company_id
WHERE c.archived_in_crm_at IS NULL
  AND (SELECT count(*) FROM crm.company_contacts x WHERE x.company_id = c.company_id) = 1
  AND NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.contact_id = cc.contact_id)
ORDER BY c.company_id;