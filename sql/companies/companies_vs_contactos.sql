-- ¿Qué tienen de especial las compañías? Compara cada compañía con su contacto (solo conteos).
-- Email de la compañía = campo 811750. Email del contacto = campo estándar EMAIL.
WITH comp AS (
  SELECT DISTINCT ON (company_id) company_id, payload
  FROM staging.companies_raw
  ORDER BY company_id, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
cont AS (
  SELECT DISTINCT ON (contact_id) contact_id, payload
  FROM staging.contacts_raw
  ORDER BY contact_id, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
cc AS (   -- una fila por compañía con su primer contacto
  SELECT c.company_id,
         (c.payload #>> '{_embedded,contacts,0,id}')::bigint AS contact_id,
         jsonb_array_length(c.payload #> '{_embedded,contacts}') AS n_contactos,
         lower(btrim(jsonb_path_query_first(c.payload,
           '$.custom_fields_values[*] ? (@.field_id == 811750).values[0].value') #>> '{}')) AS email_compania
  FROM comp c
  WHERE jsonb_typeof(c.payload #> '{_embedded,contacts}') = 'array'
    AND jsonb_array_length(c.payload #> '{_embedded,contacts}') > 0),
j AS (
  SELECT cc.*,
         lower(btrim(jsonb_path_query_first(k.payload,
           '$.custom_fields_values[*] ? (@.field_code == "EMAIL").values[0].value') #>> '{}')) AS email_contacto,
         k.contact_id IS NOT NULL AS contacto_en_bd,
         EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.contact_id = cc.contact_id) AS contacto_con_lead_vivo
  FROM cc LEFT JOIN cont k ON k.contact_id = cc.contact_id)
SELECT count(*)                                                                   AS companias_con_contacto,
       count(*) FILTER (WHERE n_contactos > 1)                                    AS con_varios_contactos,
       count(*) FILTER (WHERE NOT contacto_en_bd)                                 AS contacto_no_esta_en_bd,
       count(*) FILTER (WHERE email_compania IS NOT NULL AND email_compania = email_contacto) AS email_igual_al_del_contacto,
       count(*) FILTER (WHERE email_compania IS NOT NULL AND email_contacto IS NULL)          AS email_solo_en_la_compania,
       count(*) FILTER (WHERE email_compania IS NOT NULL AND email_contacto IS NOT NULL
                          AND email_compania <> email_contacto)                   AS email_distinto,
       count(*) FILTER (WHERE contacto_con_lead_vivo)                             AS contacto_con_lead_vivo,
       count(*) FILTER (WHERE NOT contacto_con_lead_vivo)                         AS contacto_sin_lead_vivo
FROM j;