-- ============================================================
-- Funciones para automatizar contactos y relación lead<->contacto
-- Se ejecuta UNA SOLA VEZ (crea funciones + filas de control).
-- Es seguro repetirlo.
-- Zona horaria de created_at/updated_at: UTC (igual que crm.leads)
-- ============================================================

-- 1) Filas de control del sync
INSERT INTO staging.sync_control (entity, last_sync)
SELECT 'contacts', COALESCE(min(extracted_at), now()) - interval '1 hour'
FROM staging.contacts_raw
ON CONFLICT (entity) DO NOTHING;

INSERT INTO staging.sync_control (entity, last_sync)
VALUES ('lead_contacts', '2000-01-01 00:00:00')
ON CONFLICT (entity) DO NOTHING;

-- 2) Procesa contactos nuevos (staging.contacts_raw -> crm.contacts)
CREATE OR REPLACE FUNCTION crm.process_contacts()
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_max bigint;
  n     integer := 0;
BEGIN
  SELECT max(id) INTO v_max FROM staging.contacts_raw WHERE NOT is_processed;
  IF v_max IS NULL THEN
    RETURN 0;
  END IF;

  WITH ult AS (
    SELECT DISTINCT ON ((payload->>'id')::bigint) payload
    FROM staging.contacts_raw
    WHERE NOT is_processed AND id <= v_max
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
             '$.custom_fields_values[*] ? (@.field_id == 1020420).values[0].value') #>> '{}'       AS nac_txt,
           jsonb_path_query_first(payload,
             '$.custom_fields_values[*] ? (@.field_id == 1047800).values[0].value') #>> '{}'       AS nac_nuevo
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
      regexp_match(t, '^(\d{1,2}) ?[./-] ?(\d{1,2}) ?[./-] ?(\d{4})$')                       AS mb,
      regexp_match(btrim(COALESCE(nac_nuevo,'')), '^(\d{4})-(\d{2})-(\d{2})')                  AS mc
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
      END AS birth_viejo,
      -- campo nuevo (tipo fecha): Unix timestamp o texto AAAA-MM-DD
      CASE WHEN btrim(COALESCE(nac_nuevo,'')) ~ '^\d{9,11}$'
             THEN ((to_timestamp(btrim(nac_nuevo)::bigint) + interval '12 hours') AT TIME ZONE 'UTC')::date
           WHEN mc IS NOT NULL AND (mc[1])::int BETWEEN 1900 AND 2100
                AND (mc[2])::int BETWEEN 1 AND 12 AND (mc[3])::int BETWEEN 1 AND 31
             THEN CASE WHEN extract(month FROM make_date((mc[1])::int, (mc[2])::int, 1) + ((mc[3])::int - 1)) = (mc[2])::int
                       THEN make_date((mc[1])::int, (mc[2])::int, 1) + ((mc[3])::int - 1) END
      END AS birth_nuevo
    FROM n2
  ),
  ins AS (
    INSERT INTO crm.contacts
      (contact_id, contact_name, responsible_user_id, group_id, created_at, updated_at,
       is_deleted, birth_date, city, synced_at)
    SELECT contact_id, contact_name, responsible_user_id, group_id, created_at, updated_at,
           is_deleted,
           CASE WHEN COALESCE(birth_nuevo, birth_viejo) BETWEEN DATE '1900-01-01' AND current_date
                THEN COALESCE(birth_nuevo, birth_viejo) END,
           city, now()
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
      synced_at           = EXCLUDED.synced_at
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  UPDATE staging.contacts_raw
     SET is_processed = true, processed_at = now()
   WHERE NOT is_processed AND id <= v_max;

  RETURN n;
END;
$fn$;

-- 3) Relación lead <-> contacto (staging.leads_raw -> crm.lead_contacts)
--    Revisa los snapshots de las últimas 24 h antes del último corte (reintenta
--    relaciones cuyo contacto aún no estaba cargado).
CREATE OR REPLACE FUNCTION crm.process_lead_contacts()
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_from timestamp;
  v_to   timestamp := now();
  n      integer := 0;
BEGIN
  SELECT last_sync - interval '1 day' INTO v_from
  FROM staging.sync_control WHERE entity = 'lead_contacts';
  v_from := COALESCE(v_from, timestamp '2000-01-01');

  DROP TABLE IF EXISTS _rel;
  CREATE TEMP TABLE _rel AS
  WITH ult AS (
    SELECT DISTINCT ON ((payload->>'id')::bigint) payload
    FROM staging.leads_raw
    WHERE extracted_at >= v_from
    ORDER BY (payload->>'id')::bigint,
             (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
  )
  SELECT (u.payload->>'id')::bigint AS lead_id,
         (c->>'id')::bigint         AS contact_id,
         COALESCE((c->>'is_main')::boolean, false) AS is_main
  FROM ult u
  LEFT JOIN LATERAL jsonb_array_elements(u.payload #> '{_embedded,contacts}') c ON true
  WHERE jsonb_typeof(u.payload #> '{_embedded,contacts}') = 'array';

  DELETE FROM crm.lead_contacts lc
  USING (SELECT DISTINCT lead_id FROM _rel) x
  WHERE lc.lead_id = x.lead_id;

  INSERT INTO crm.lead_contacts (lead_id, contact_id, is_main, synced_at)
  SELECT r.lead_id, r.contact_id, r.is_main, now()
  FROM _rel r
  JOIN crm.leads    l ON l.lead_id    = r.lead_id
  JOIN crm.contacts c ON c.contact_id = r.contact_id
  WHERE r.contact_id IS NOT NULL
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;

  DROP TABLE IF EXISTS _rel;

  UPDATE staging.sync_control SET last_sync = v_to WHERE entity = 'lead_contacts';
  RETURN n;
END;
$fn$;


SELECT crm.process_contacts() AS contactos,
       crm.process_lead_contacts() AS relaciones;

SELECT entity, last_sync FROM staging.sync_control ORDER BY entity;

WITH ultl AS (
  SELECT DISTINCT ON ((payload->>'id')::bigint) payload
  FROM staging.leads_raw
  ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC),
rel AS (
  SELECT (u.payload->>'id')::bigint AS lead_id, (c->>'id')::bigint AS contact_id
  FROM ultl u, jsonb_array_elements(COALESCE(u.payload #> '{_embedded,contacts}','[]')) c)
SELECT
  (SELECT count(*) FROM rel r WHERE NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id=r.lead_id AND lc.contact_id=r.contact_id)
     AND NOT EXISTS (SELECT 1 FROM crm.contacts x WHERE x.contact_id=r.contact_id)) AS huerf_contacto_no_existe,
  (SELECT count(*) FROM rel r WHERE NOT EXISTS (SELECT 1 FROM crm.lead_contacts lc WHERE lc.lead_id=r.lead_id AND lc.contact_id=r.contact_id)
     AND NOT EXISTS (SELECT 1 FROM crm.leads x WHERE x.lead_id=r.lead_id)) AS huerf_lead_no_existe;

SELECT now()                                                         AS ahora_bd,
       (SELECT last_sync FROM staging.sync_control WHERE entity='contacts') AS ultimo_corte,
       (SELECT max(extracted_at) FROM staging.contacts_raw)           AS ultima_extraccion,
       (SELECT count(*) FROM staging.contacts_raw
         WHERE extracted_at > now() - interval '12 hours')            AS filas_ultimas_12h,
       (SELECT max(synced_at) FROM crm.contacts)                      AS ultimo_proceso;