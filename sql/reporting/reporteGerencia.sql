-- =====================================================================
-- REPORTE PARA GERENCIA = reporte de ventas/marketing + sección financiera
-- Requiere haber ejecutado antes crear_reporte_semanal.sql
-- Funciones (esquema reporte):
--   _num / _txt / _ts          lectura segura de campos Kommo (primer set con dato)
--   financiero_detalle(d,h)    una fila por venta con campos financieros y alertas
--   gerencia(d,h)              texto completo para correo de gerencia
--   gerencia_semanal()         semana anterior (viernes a jueves)
--   gerencia_mensual(mes)      mes anterior o el mes de la fecha dada
-- Sets de campos: principal (asesor) primero; si está vacío, SAC 10398xx; luego SAC 10441xx.
-- Los valores son los ACTUALES del lead (Pagado = acumulado a la fecha de generación).
-- Se puede ejecutar varias veces sin problema.
-- =====================================================================

CREATE OR REPLACE FUNCTION reporte._raw(p jsonb, p_id bigint) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT NULLIF(btrim(jsonb_path_query_first(p,
    '$.custom_fields_values[*] ? (@.field_id == $id).values[0].value', jsonb_build_object('id', p_id)) #>> '{}'), '');
$f$;

CREATE OR REPLACE FUNCTION reporte._num(p jsonb, ids bigint[]) RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$
  SELECT (v)::numeric
  FROM unnest(ids) WITH ORDINALITY u(id, ord), LATERAL (SELECT reporte._raw(p, u.id) AS v) x
  WHERE v ~ '^-?\d+(\.\d+)?$'
  ORDER BY ord LIMIT 1;
$f$;

CREATE OR REPLACE FUNCTION reporte._txt(p jsonb, ids bigint[]) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT v FROM unnest(ids) WITH ORDINALITY u(id, ord), LATERAL (SELECT reporte._raw(p, u.id) AS v) x
  WHERE v IS NOT NULL ORDER BY ord LIMIT 1;
$f$;

CREATE OR REPLACE FUNCTION reporte._ts(p jsonb, ids bigint[]) RETURNS timestamp LANGUAGE sql IMMUTABLE AS $f$
  SELECT to_timestamp((v)::bigint) AT TIME ZONE 'America/Bogota'
  FROM unnest(ids) WITH ORDINALITY u(id, ord), LATERAL (SELECT reporte._raw(p, u.id) AS v) x
  WHERE v ~ '^\d{9,11}$' ORDER BY ord LIMIT 1;
$f$;

CREATE OR REPLACE FUNCTION reporte.financiero_detalle(p_desde date, p_hasta_excl date)
RETURNS TABLE (lead_id bigint, nombre_lead text, fecha_compra date, pipeline text, presupuesto numeric,
               total_plan numeric, valor_incremento numeric, valor_proveedor numeric,
               ingreso_incremento numeric, ingreso_proveedor numeric, pagado numeric, saldo numeric,
               metodo_pago text, tipo_pago text, fecha_pendiente date,
               alertas text, consistente boolean)
LANGUAGE sql STABLE AS $f$
  WITH ult AS (
    SELECT DISTINCT ON ((payload->>'id')::bigint) (payload->>'id')::bigint AS lead_id, payload
    FROM staging.leads_raw WHERE payload->>'id' IS NOT NULL
    ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
  ),
  v AS (
    SELECT u.lead_id, u.payload AS p,
           to_timestamp(NULLIF(reporte._raw(u.payload, 1016729), '')::bigint) AT TIME ZONE 'America/Bogota' AS fc
    FROM ult u WHERE COALESCE(u.payload->>'is_deleted','false') <> 'true'
  ),
  b AS (
    SELECT v.lead_id, v.p, v.fc::date AS fecha_compra,
           (v.p->>'price')::numeric AS presupuesto,
           reporte._num(v.p, ARRAY[1045050,1039825,1044180]) AS tot_campo,
           reporte._num(v.p, ARRAY[1021270,1039823,1044182]) AS vinc,
           reporte._num(v.p, ARRAY[1021272,1039827,1044184]) AS vprov,
           reporte._num(v.p, ARRAY[1021276,1039829,1044186]) AS iinc,
           reporte._num(v.p, ARRAY[1021274,1039831,1044188]) AS iprov,
           reporte._num(v.p, ARRAY[1008406]) AS pag,
           reporte._num(v.p, ARRAY[1016737]) AS sal,
           reporte._txt(v.p, ARRAY[812200,1039833,1044190]) AS metodo,
           reporte._txt(v.p, ARRAY[812208]) AS tipo,
           reporte._ts(v.p, ARRAY[1008416,1039835,1044192])::date AS fpend,
           jsonb_path_exists(v.p, '$.custom_fields_values[*] ? (@.field_id == 1039823 || @.field_id == 1039825 || @.field_id == 1039827 || @.field_id == 1039829 || @.field_id == 1039831 || @.field_id == 1039833 || @.field_id == 1039835 || @.field_id == 1044180 || @.field_id == 1044182 || @.field_id == 1044184 || @.field_id == 1044186 || @.field_id == 1044188 || @.field_id == 1044190 || @.field_id == 1044192)') AS tiene_sac,
           v.p->>'pipeline_id' AS pipeline_id
    FROM v WHERE v.fc >= p_desde AND v.fc < p_hasta_excl
  ),
  c AS (
    SELECT b.*, COALESCE(b.tot_campo, b.presupuesto) AS total,
           (SELECT bool_or(x > 0 AND x < 100000) FROM unnest(ARRAY[b.tot_campo, b.vinc, b.vprov, b.iinc, b.iprov, b.pag, b.sal]) x) AS en_miles
    FROM b
  ),
  d AS (
    SELECT c.*,
      concat_ws('; ',
        CASE WHEN c.en_miles THEN 'valor en miles (probable): corregir en Kommo' END,
        CASE WHEN c.vinc IS NULL OR c.vprov IS NULL THEN 'falta valor incremento/proveedor' END,
        CASE WHEN c.pag IS NULL OR c.sal IS NULL THEN 'falta pagado hoy/saldo' END,
        CASE WHEN c.iinc IS NULL OR c.iprov IS NULL THEN 'falta ingreso incremento/proveedor' END,
        CASE WHEN c.metodo IS NULL THEN 'falta método de pago' END,
        CASE WHEN c.fpend IS NULL AND COALESCE(c.sal, 1) > 0 THEN 'falta fecha pendiente de pago' END,
        CASE WHEN c.vinc IS NOT NULL AND c.vprov IS NOT NULL AND abs(c.vinc + c.vprov - c.total) > 1 THEN 'incremento + proveedor <> total' END,
        CASE WHEN c.pag IS NOT NULL AND c.iinc IS NOT NULL AND c.iprov IS NOT NULL AND abs(c.iinc + c.iprov - c.pag) > 1 THEN 'ingresos <> pagado' END,
        CASE WHEN c.pag IS NOT NULL AND c.sal IS NOT NULL AND abs(c.total - c.pag - c.sal) > 1 THEN 'saldo <> total - pagado' END,
        CASE WHEN c.tot_campo IS NOT NULL AND c.presupuesto IS NOT NULL AND abs(c.tot_campo - c.presupuesto) > 1 THEN 'valor total del plan <> presupuesto' END,
        CASE WHEN c.tiene_sac THEN 'tiene datos SAC (revisar cuál set aplica)' END) AS alertas
    FROM c
  )
  SELECT d.lead_id, d.p->>'name', d.fecha_compra,
         CASE d.pipeline_id WHEN '11608463' THEN 'VENTAS CALI' WHEN '11608479' THEN 'VENTAS BGTA' WHEN '10684275' THEN 'SERVICIO AL CLIENTE'
                            WHEN '10423839' THEN 'INCOMING LEADS' ELSE d.pipeline_id END,
         d.presupuesto, d.total, d.vinc, d.vprov, d.iinc, d.iprov, d.pag, d.sal, d.metodo, d.tipo, d.fpend, d.alertas,
         (d.alertas !~ 'miles|falta|<>')   -- consistente: sin errores graves (los avisos SAC no cuentan)
  FROM d ORDER BY d.fecha_compra, d.lead_id;
$f$;

CREATE OR REPLACE FUNCTION reporte._m(p numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN p IS NULL THEN 'sin dato' ELSE '$' || replace(to_char(p, 'FM999,999,999,999'), ',', '.') END;
$f$;

CREATE OR REPLACE FUNCTION reporte.gerencia(p_desde date, p_hasta_excl date)
RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, cuerpo text)
LANGUAGE plpgsql AS $f$
DECLARE
  base text; fin text; n int; n_ok int; n_mal int;
  t_plan numeric; t_inc numeric; t_prov numeric; t_pag numeric; t_ii numeric; t_ip numeric; t_sal numeric;
  es_mes boolean := (p_hasta_excl - p_desde) > 8;
BEGIN
  base := reporte.ventas_whatsapp(p_desde, p_hasta_excl);
  DROP TABLE IF EXISTS _rf;
  CREATE TEMP TABLE _rf AS SELECT * FROM reporte.financiero_detalle(p_desde, p_hasta_excl);
  SELECT count(*), count(*) FILTER (WHERE consistente) INTO n, n_ok FROM _rf;
  n_mal := n - n_ok;
  SELECT sum(total_plan), sum(valor_incremento), sum(valor_proveedor), sum(pagado), sum(ingreso_incremento), sum(ingreso_proveedor), sum(saldo)
    INTO t_plan, t_inc, t_prov, t_pag, t_ii, t_ip, t_sal FROM _rf WHERE consistente;

  t_plan := COALESCE(t_plan, 0); t_inc := COALESCE(t_inc, 0); t_prov := COALESCE(t_prov, 0); t_pag := COALESCE(t_pag, 0);
  t_ii := COALESCE(t_ii, 0); t_ip := COALESCE(t_ip, 0); t_sal := COALESCE(t_sal, 0);
  fin := E'\n\n💰 *FINANCIERO (solo gerencia)*' || E'\n'
      || 'Ventas con datos financieros completos y consistentes: ' || n_ok || ' de ' || n || E'\n'
      || '• Valor total de los planes: ' || reporte._m(t_plan) || E'\n'
      || '• Incremento (utilidad) pactado: ' || reporte._m(t_inc) || E'\n'
      || '• Proveedor pactado: ' || reporte._m(t_prov) || E'\n'
      || '• Pagado a la fecha: ' || reporte._m(t_pag) || ' (' || CASE WHEN t_plan > 0 THEN replace(round(100.0 * t_pag / t_plan, 1)::text, '.', ',') ELSE '0' END || ' % del total)' || E'\n'
      || '   – Aplicado a incremento: ' || reporte._m(t_ii) || E'\n'
      || '   – Aplicado a proveedor: ' || reporte._m(t_ip) || E'\n'
      || '• Saldo pendiente: ' || reporte._m(t_sal) || E'\n';
  IF n_mal > 0 THEN
    fin := fin || '⚠️ ' || n_mal || ' venta(s) excluidas de estas sumas por datos inconsistentes (ver detalle abajo).' || E'\n';
  END IF;
  fin := fin || E'\n*Por método de pago* (pagado a la fecha)' || E'\n'
      || COALESCE((SELECT string_agg('• ' || COALESCE(metodo_pago, '(sin dato)') || ': ' || c || ' ventas, ' || reporte._m(s), E'\n' ORDER BY s DESC)
                   FROM (SELECT metodo_pago, count(*) c, sum(pagado) s FROM _rf WHERE consistente GROUP BY 1) x), '(sin datos)')
      || E'\n\n*Detalle por venta*' || E'\n'
      || COALESCE((SELECT string_agg('• ' || nombre_lead || ' (' || lead_id || ') ' || fecha_compra || ': plan ' || reporte._m(total_plan)
                      || ' | incr ' || reporte._m(valor_incremento) || ' | prov ' || reporte._m(valor_proveedor)
                      || ' | pagado ' || reporte._m(pagado) || ' | saldo ' || reporte._m(saldo)
                      || ' | ' || COALESCE(metodo_pago, 'sin método') || COALESCE(' | vence ' || to_char(fecha_pendiente, 'DD/MM/YYYY'), ''),
                      E'\n' ORDER BY fecha_compra, lead_id) FROM _rf), '(sin ventas)')
      || E'\n\n⚠️ *Datos por corregir en Kommo*' || E'\n'
      || COALESCE((SELECT string_agg('• ' || nombre_lead || ' (' || lead_id || '): ' || alertas, E'\n' ORDER BY fecha_compra, lead_id)
                   FROM _rf WHERE alertas <> ''), 'Ninguno.')
      || E'\n\nNota: valores actuales de cada lead; "pagado" es el acumulado a hoy, no solo lo pagado el día de la venta.';

  desde := p_desde; hasta_excl := p_hasta_excl; n_ventas := n;
  asunto := 'GERENCIA - Reporte de ventas y financiero: ' || to_char(p_desde, 'DD/MM/YYYY') || ' al ' || to_char(p_hasta_excl - 1, 'DD/MM/YYYY');
  cuerpo := base || fin;
  RETURN NEXT;
END;
$f$;

CREATE OR REPLACE FUNCTION reporte.gerencia_semanal() RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, cuerpo text)
LANGUAGE sql AS $f$
  SELECT g.* FROM reporte.semana_anterior() s, LATERAL reporte.gerencia(s.desde, s.hasta_excl) g;
$f$;

CREATE OR REPLACE FUNCTION reporte.gerencia_mensual(p_mes date DEFAULT NULL) RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, cuerpo text)
LANGUAGE sql AS $f$
  WITH m AS (SELECT CASE WHEN p_mes IS NULL
                         THEN (date_trunc('month', (now() AT TIME ZONE 'America/Bogota')::date) - interval '1 month')::date
                         ELSE date_trunc('month', p_mes)::date END AS d)
  SELECT g.* FROM m, LATERAL reporte.gerencia(m.d, (m.d + interval '1 month')::date) g;
$f$;