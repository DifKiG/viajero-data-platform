-- ============================================================
-- Compañías: tablas limpias + función de procesamiento
-- Se ejecuta UNA SOLA VEZ (seguro de repetir). Zona horaria: UTC.
-- Campos de compañía en Kommo: 811750 Email, 811748 Phone, 811754 Address
-- ============================================================
CREATE TABLE IF NOT EXISTS crm.companies (
  company_id          bigint PRIMARY KEY,
  company_name        text,
  email               text,
  phone               text,
  address             text,
  responsible_user_id bigint,
  created_by          bigint,
  created_at          timestamp,
  updated_at          timestamp,
  is_deleted          boolean   NOT NULL DEFAULT false,
  archived_in_crm_at  timestamp,           -- se llena cuando la compañía se borra de Kommo
  synced_at           timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS crm.company_contacts (
  company_id bigint NOT NULL,
  contact_id bigint NOT NULL,
  synced_at  timestamp NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, contact_id)
);
CREATE INDEX IF NOT EXISTS idx_company_contacts_contact ON crm.company_contacts (contact_id);

CREATE OR REPLACE FUNCTION crm.process_companies()
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_max bigint;
  n     integer := 0;
BEGIN
  SELECT max(id) INTO v_max FROM staging.companies_raw WHERE NOT is_processed;
  IF v_max IS NULL THEN
    RETURN 0;
  END IF;

  DROP TABLE IF EXISTS _comp;
  CREATE TEMP TABLE _comp AS
  SELECT DISTINCT ON (company_id) company_id, payload
  FROM staging.companies_raw
  WHERE NOT is_processed AND id <= v_max
  ORDER BY company_id, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC;

  WITH ins AS (
    INSERT INTO crm.companies
      (company_id, company_name, email, phone, address, responsible_user_id, created_by,
       created_at, updated_at, is_deleted, synced_at)
    SELECT company_id,
           NULLIF(btrim(payload->>'name'), ''),
           NULLIF(lower(btrim(jsonb_path_query_first(payload,
             '$.custom_fields_values[*] ? (@.field_id == 811750).values[0].value') #>> '{}')), ''),
           NULLIF(btrim(jsonb_path_query_first(payload,
             '$.custom_fields_values[*] ? (@.field_id == 811748).values[0].value') #>> '{}'), ''),
           NULLIF(btrim(jsonb_path_query_first(payload,
             '$.custom_fields_values[*] ? (@.field_id == 811754).values[0].value') #>> '{}'), ''),
           (payload->>'responsible_user_id')::bigint,
           (payload->>'created_by')::bigint,
           to_timestamp((payload->>'created_at')::bigint) AT TIME ZONE 'UTC',
           to_timestamp((payload->>'updated_at')::bigint) AT TIME ZONE 'UTC',
           COALESCE((payload->>'is_deleted')::boolean, false),
           now()
    FROM _comp
    ON CONFLICT (company_id) DO UPDATE SET
      company_name        = EXCLUDED.company_name,
      email               = EXCLUDED.email,
      phone               = EXCLUDED.phone,
      address             = EXCLUDED.address,
      responsible_user_id = EXCLUDED.responsible_user_id,
      created_by          = EXCLUDED.created_by,
      created_at          = EXCLUDED.created_at,
      updated_at          = EXCLUDED.updated_at,
      is_deleted          = EXCLUDED.is_deleted,
      synced_at           = EXCLUDED.synced_at
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  -- relación compañía <-> contacto (solo para compañías cuya foto trae la lista de contactos)
  DELETE FROM crm.company_contacts cc
  USING (SELECT company_id FROM _comp
         WHERE jsonb_typeof(payload #> '{_embedded,contacts}') = 'array') x
  WHERE cc.company_id = x.company_id;

  INSERT INTO crm.company_contacts (company_id, contact_id, synced_at)
  SELECT DISTINCT c.company_id, (k->>'id')::bigint, now()
  FROM _comp c, jsonb_array_elements(c.payload #> '{_embedded,contacts}') k
  WHERE jsonb_typeof(c.payload #> '{_embedded,contacts}') = 'array'
    AND (k->>'id') IS NOT NULL
  ON CONFLICT DO NOTHING;

  DROP TABLE IF EXISTS _comp;

  UPDATE staging.companies_raw
     SET is_processed = true, processed_at = now()
   WHERE NOT is_processed AND id <= v_max;

  RETURN n;
END;
$fn$;

SELECT crm.process_companies();