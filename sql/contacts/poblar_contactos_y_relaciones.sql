-- ============================================================
-- Llena crm.contacts y crm.lead_contacts desde staging
-- Seguro de repetir (idempotente). Corre TODO el archivo de una vez.
-- Zona horaria de created_at/updated_at: America/Bogota
-- (verifica con el bloque 0 que coincide con crm.leads)
-- ============================================================

-- BLOQUE 0 (solo lectura): ¿crm.leads guarda la hora en Bogotá o en UTC?
-- Si created_at_crm = bogota -> bien. Si = utc -> cambia 'America/Bogota' por 'UTC' en el bloque 1.
SELECT l.lead_id,
       l.created_at                                                             AS created_at_crm,
       to_timestamp((r.payload->>'created_at')::bigint) AT TIME ZONE 'UTC' AS bogota,
       to_timestamp((r.payload->>'created_at')::bigint) AT TIME ZONE 'UTC'            AS utc
FROM crm.leads l
JOIN LATERAL (SELECT payload FROM staging.leads_raw
              WHERE lead_id = l.lead_id ORDER BY id DESC LIMIT 1) r ON true
LIMIT 3;

BEGIN;

-- BLOQUE 1: contactos (última foto de cada contacto)
INSERT INTO crm.contacts
  (contact_id, contact_name, responsible_user_id, group_id, created_at, updated_at,
   is_deleted, birth_date, city, synced_at)
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.contacts_raw
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
),
b AS (
  SELECT (payload->>'id')::bigint                    AS contact_id,
         payload->>'name'                            AS contact_name,
         (payload->>'responsible_user_id')::bigint   AS responsible_user_id,
         (payload->>'group_id')::bigint              AS group_id,
         to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'UTC' AS created_at,
         to_timestamp((payload->>'updated_at')::bigint) AT TIME ZONE 'UTC' AS updated_at,
         COALESCE((payload->>'is_deleted')::boolean, false) AS is_deleted,
         NULLIF(btrim(jsonb_path_query_first(payload,
           '$.custom_fields_values[*] ? (@.field_id == 1008538).values[0].value') #>> '{}'), '') AS city,
         jsonb_path_query_first(payload,
           '$.custom_fields_values[*] ? (@.field_id == 1020420).values[0].value') #>> '{}'       AS nac_txt
  FROM ult
),
n0 AS (
  SELECT *, lower(btrim(regexp_replace(
              translate(nac_txt, chr(160)||chr(8199)||chr(8239)||chr(8201)||chr(8203), '    '),
              '\s+', ' ', 'g'))) AS t
  FROM b
),
n1 AS (
  SELECT *,
    regexp_match(t, '^(\d{1,2})[ ./-]+(?:del? )?([a-záéíóú]+)[ ./-]+(?:del? )?(\d{4})$') AS ma,
    regexp_match(t, '^(\d{1,2}) ?[./-] ?(\d{1,2}) ?[./-] ?(\d{4})$')                       AS mb
  FROM n0
),
n2 AS (
  SELECT *,
    COALESCE(ma[1], mb[1])::int AS dia,
    CASE WHEN ma IS NOT NULL
           THEN array_position(ARRAY['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'], left(ma[2],3))
         WHEN mb IS NOT NULL THEN (mb[2])::int END AS mes,
    COALESCE(ma[3], mb[3])::int AS anio
  FROM n1
),
n3 AS (
  SELECT *,
    CASE WHEN mes BETWEEN 1 AND 12 AND anio BETWEEN 1900 AND 2100 AND dia BETWEEN 1 AND 31
         THEN CASE WHEN extract(month FROM make_date(anio, mes, 1) + (dia - 1)) = mes
                   THEN make_date(anio, mes, 1) + (dia - 1) END
    END AS birth_date
  FROM n2
)
SELECT contact_id, contact_name, responsible_user_id, group_id, created_at, updated_at,
       is_deleted, birth_date, city, now()
FROM n3
ON CONFLICT (contact_id) DO UPDATE SET
  contact_name        = EXCLUDED.contact_name,
  responsible_user_id = EXCLUDED.responsible_user_id,
  group_id            = EXCLUDED.group_id,
  created_at          = EXCLUDED.created_at,
  updated_at          = EXCLUDED.updated_at,
  is_deleted          = EXCLUDED.is_deleted,
  birth_date          = EXCLUDED.birth_date,
  city                = EXCLUDED.city,
  synced_at           = EXCLUDED.synced_at;

-- BLOQUE 2: relación lead <-> contacto
-- Solo toca leads cuya última foto trae la lista de contactos (with=contacts).
CREATE TEMP TABLE _rel ON COMMIT DROP AS
WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint,
           (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
)
SELECT (u.payload->>'id')::bigint AS lead_id,
       (c->>'id')::bigint         AS contact_id,
       COALESCE((c->>'is_main')::boolean, false) AS is_main
FROM ult u
LEFT JOIN LATERAL jsonb_array_elements(u.payload #> '{_embedded,contacts}') c ON true
WHERE jsonb_typeof(u.payload #> '{_embedded,contacts}') = 'array';

-- quita relaciones viejas de esos leads y vuelve a insertar las actuales
DELETE FROM crm.lead_contacts lc
USING (SELECT DISTINCT lead_id FROM _rel) x
WHERE lc.lead_id = x.lead_id;

INSERT INTO crm.lead_contacts (lead_id, contact_id, is_main, synced_at)
SELECT r.lead_id, r.contact_id, r.is_main, now()
FROM _rel r
JOIN crm.leads    l ON l.lead_id    = r.lead_id
JOIN crm.contacts c ON c.contact_id = r.contact_id
WHERE r.contact_id IS NOT NULL;

COMMIT;

-- BLOQUE 3 (solo lectura): resultados
SELECT 'contacts'      AS tabla, count(*) AS filas FROM crm.contacts
UNION ALL SELECT 'lead_contacts', count(*) FROM crm.lead_contacts
UNION ALL SELECT 'contactos con ciudad',      count(*) FROM crm.contacts WHERE city IS NOT NULL
UNION ALL SELECT 'contactos con fecha nac.',  count(*) FROM crm.contacts WHERE birth_date IS NOT NULL
UNION ALL SELECT 'leads con >=1 contacto',    count(DISTINCT lead_id) FROM crm.lead_contacts
UNION ALL SELECT 'leads sin contacto',        count(*) FROM crm.leads l
          WHERE NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id = l.lead_id);

-- Relaciones que NO se pudieron guardar (el contacto no está en contacts_raw o el lead no está en crm.leads)
SELECT count(*) AS relaciones_huerfanas FROM (
  SELECT (c->>'id')::bigint AS contact_id, (u.payload->>'id')::bigint AS lead_id
  FROM (SELECT DISTINCT ON ((payload->>'id')::bigint) payload
        FROM staging.leads_raw
        ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC) u,
       jsonb_array_elements(COALESCE(u.payload #> '{_embedded,contacts}','[]')) c
) x
WHERE NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id = x.lead_id AND lc.contact_id = x.contact_id);



WITH ultc AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.contacts_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
ultl AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
rel AS (
  SELECT (u.payload->>'id')::bigint AS lead_id, (c->>'id')::bigint AS contact_id
  FROM ultl u, jsonb_array_elements(COALESCE(u.payload #> '{_embedded,contacts}','[]')) c)
SELECT
  -- 1) zona horaria: debe ser 0 (contactos cuya hora no coincide con UTC)
  (SELECT count(*) FROM crm.contacts c
     JOIN ultc u ON (u.payload->>'id')::bigint = c.contact_id
    WHERE c.created_at IS DISTINCT FROM to_timestamp((u.payload->>'created_at')::bigint) AT TIME ZONE 'UTC') AS tz_no_coincide,
  -- 2) campos en el origen, para comparar con 690 y 455
  (SELECT count(*) FROM ultc WHERE jsonb_path_exists(payload,'$.custom_fields_values[*] ? (@.field_id == 1008538)')) AS raw_con_ciudad,
  (SELECT count(*) FROM ultc WHERE jsonb_path_exists(payload,'$.custom_fields_values[*] ? (@.field_id == 1020420)')) AS raw_con_nacimiento,
  -- 3) huérfanas por causa
  (SELECT count(*) FROM rel r WHERE NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id=r.lead_id AND lc.contact_id=r.contact_id)
      AND NOT EXISTS (SELECT 1 FROM crm.contacts x WHERE x.contact_id=r.contact_id)) AS huerf_contacto_no_existe,
  (SELECT count(*) FROM rel r WHERE NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id=r.lead_id AND lc.contact_id=r.contact_id)
      AND NOT EXISTS (SELECT 1 FROM crm.leads x WHERE x.lead_id=r.lead_id)) AS huerf_lead_no_existe;



WITH ult AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.contacts_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC)
SELECT jsonb_path_query_first(u.payload,
         '$.custom_fields_values[*] ? (@.field_id == 1020420).values[0].value') #>> '{}' AS texto_nacimiento,
       count(*) AS veces
FROM ult u
JOIN crm.contacts c ON c.contact_id = (u.payload->>'id')::bigint
WHERE c.birth_date IS NULL
  AND jsonb_path_exists(u.payload, '$.custom_fields_values[*] ? (@.field_id == 1020420)')
GROUP BY 1
ORDER BY 2 DESC, 1
LIMIT 80;