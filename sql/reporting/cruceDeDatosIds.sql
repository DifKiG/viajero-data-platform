-- ============================================================
-- Conciliación de IDs: detecta en la BD lo que ya NO existe en Kommo
-- Se ejecuta UNA SOLA VEZ (seguro de repetir).
-- No borra nada: solo marca con archived_in_crm_at (y lo quita si reaparece).
-- ============================================================
ALTER TABLE crm.leads     ADD COLUMN IF NOT EXISTS archived_in_crm_at timestamp;
ALTER TABLE crm.contacts  ADD COLUMN IF NOT EXISTS archived_in_crm_at timestamp;
ALTER TABLE crm.companies ADD COLUMN IF NOT EXISTS archived_in_crm_at timestamp;

CREATE TABLE IF NOT EXISTS staging.kommo_ids_vivos (
  entity  text      NOT NULL,          -- 'leads' | 'contacts' | 'companies'
  id      bigint    NOT NULL,
  seen_at timestamp NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_kommo_ids_vivos ON staging.kommo_ids_vivos (entity, id);

-- Marca como archivados los registros que ya no están en la lista de IDs vivos de Kommo.
-- p_min_ratio: protección. Si la lista de Kommo trae menos de ese % de lo que la BD
-- considera activo, la función se detiene (probable descarga incompleta).
CREATE OR REPLACE FUNCTION crm.reconcile_deleted(p_entity text, p_min_ratio numeric DEFAULT 0.8)
RETURNS TABLE (archivados integer, restaurados integer, ids_en_kommo integer, activos_antes integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_ids    integer;
  v_active integer;
  v_start  timestamp;
  v_arch   integer := 0;
  v_rest   integer := 0;
BEGIN
  SELECT count(DISTINCT id), min(seen_at) INTO v_ids, v_start
  FROM staging.kommo_ids_vivos WHERE entity = p_entity;

  IF p_entity = 'leads' THEN
    SELECT count(*) INTO v_active FROM crm.leads WHERE archived_in_crm_at IS NULL;
  ELSIF p_entity = 'contacts' THEN
    SELECT count(*) INTO v_active FROM crm.contacts WHERE archived_in_crm_at IS NULL;
  ELSIF p_entity = 'companies' THEN
    SELECT count(*) INTO v_active FROM crm.companies WHERE archived_in_crm_at IS NULL;
  ELSE
    RAISE EXCEPTION 'Entidad no válida: %', p_entity;
  END IF;

  IF v_ids = 0 THEN
    RAISE EXCEPTION 'No hay IDs de % en staging.kommo_ids_vivos: no se archiva nada', p_entity;
  END IF;
  IF v_ids < p_min_ratio * v_active THEN
    RAISE EXCEPTION 'Kommo trajo % IDs de % pero la BD tiene % activos (menos del % %%): descarga incompleta, no se archiva nada',
                    v_ids, p_entity, v_active, round(p_min_ratio * 100);
  END IF;

  IF p_entity = 'leads' THEN
    UPDATE crm.leads SET archived_in_crm_at = now()
     WHERE archived_in_crm_at IS NULL
       AND created_at < v_start - interval '1 hour'
       AND NOT EXISTS (SELECT 1 FROM staging.kommo_ids_vivos k WHERE k.entity = 'leads' AND k.id = lead_id);
    GET DIAGNOSTICS v_arch = ROW_COUNT;
    UPDATE crm.leads SET archived_in_crm_at = NULL
     WHERE archived_in_crm_at IS NOT NULL
       AND EXISTS (SELECT 1 FROM staging.kommo_ids_vivos k WHERE k.entity = 'leads' AND k.id = lead_id);
    GET DIAGNOSTICS v_rest = ROW_COUNT;
  ELSIF p_entity = 'contacts' THEN
    UPDATE crm.contacts SET archived_in_crm_at = now()
     WHERE archived_in_crm_at IS NULL
       AND created_at < v_start - interval '1 hour'
       AND NOT EXISTS (SELECT 1 FROM staging.kommo_ids_vivos k WHERE k.entity = 'contacts' AND k.id = contact_id);
    GET DIAGNOSTICS v_arch = ROW_COUNT;
    UPDATE crm.contacts SET archived_in_crm_at = NULL
     WHERE archived_in_crm_at IS NOT NULL
       AND EXISTS (SELECT 1 FROM staging.kommo_ids_vivos k WHERE k.entity = 'contacts' AND k.id = contact_id);
    GET DIAGNOSTICS v_rest = ROW_COUNT;
  ELSE
    UPDATE crm.companies SET archived_in_crm_at = now()
     WHERE archived_in_crm_at IS NULL
       AND created_at < v_start - interval '1 hour'
       AND NOT EXISTS (SELECT 1 FROM staging.kommo_ids_vivos k WHERE k.entity = 'companies' AND k.id = company_id);
    GET DIAGNOSTICS v_arch = ROW_COUNT;
    UPDATE crm.companies SET archived_in_crm_at = NULL
     WHERE archived_in_crm_at IS NOT NULL
       AND EXISTS (SELECT 1 FROM staging.kommo_ids_vivos k WHERE k.entity = 'companies' AND k.id = company_id);
    GET DIAGNOSTICS v_rest = ROW_COUNT;
  END IF;

  archivados := v_arch; restaurados := v_rest; ids_en_kommo := v_ids; activos_antes := v_active;
  RETURN NEXT;
END;
$fn$;