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


DROP FUNCTION IF EXISTS reporte.financiero_detalle(date, date);


CREATE OR REPLACE FUNCTION reporte._m(p numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN p IS NULL THEN 'sin dato' ELSE '$' || replace(to_char(p, 'FM999,999,999,999'), ',', '.') END;
$f$;


CREATE OR REPLACE FUNCTION reporte.financiero_detalle(p_desde date, p_hasta_excl date) RETURNS TABLE (lead_id bigint, nombre_lead text, fecha_compra date, pipeline text, presupuesto numeric, total_plan numeric, valor_incremento numeric, valor_proveedor numeric, ingreso_incremento numeric, ingreso_proveedor numeric, pagado numeric, saldo numeric, metodo_pago text, tipo_pago text, fecha_pendiente date, pend_incremento numeric, pend_proveedor numeric, alertas text, consistente boolean) LANGUAGE sql STABLE AS $f$
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
    FROM v WHERE v.fc >= p_desde AND v.fc < p_hasta_excl AND COALESCE((v.p->>'price')::numeric, 0) > 0
  ),
  c AS (
    SELECT b.*, COALESCE(NULLIF(b.tot_campo, 0), b.presupuesto) AS total,
           CASE WHEN b.vinc IS NOT NULL AND b.vprov IS NOT NULL THEN b.vinc + b.vprov ELSE COALESCE(NULLIF(b.tot_campo, 0), b.presupuesto) END AS base_cobro,
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
        CASE WHEN c.vinc IS NOT NULL AND c.vprov IS NOT NULL AND abs(c.vinc + c.vprov - c.total) > 1
             THEN 'aviso: el plan difiere de incremento+proveedor en ' || reporte._m(c.total - c.vinc - c.vprov) END,
        CASE WHEN c.pag IS NOT NULL AND c.iinc IS NOT NULL AND c.iprov IS NOT NULL AND abs(c.iinc + c.iprov - c.pag) > 1 THEN 'ingresos <> pagado' END,
        CASE WHEN c.pag IS NOT NULL AND c.sal IS NOT NULL AND abs(c.base_cobro - c.pag - c.sal) > 1 AND abs(c.total - c.pag - c.sal) > 1
             THEN 'saldo <> total - pagado: debería ser ' || reporte._m(c.total - c.pag) || ' (o ' || reporte._m(c.base_cobro - c.pag) || ' según incremento+proveedor)' END,
        CASE WHEN NULLIF(c.tot_campo, 0) IS NOT NULL AND c.presupuesto IS NOT NULL AND abs(c.tot_campo - c.presupuesto) > 1 THEN 'aviso: valor total del plan difiere del presupuesto' END,
        CASE WHEN c.tiene_sac THEN 'tiene datos SAC (revisar cuál set aplica)' END) AS alertas
    FROM c
  )
  SELECT d.lead_id, d.p->>'name', d.fecha_compra,
         CASE d.pipeline_id WHEN '11608463' THEN 'VENTAS CALI' WHEN '11608479' THEN 'VENTAS BGTA' WHEN '10684275' THEN 'SERVICIO AL CLIENTE'
                            WHEN '10423839' THEN 'INCOMING LEADS' ELSE d.pipeline_id END,
         d.presupuesto, d.total, d.vinc, d.vprov, d.iinc, d.iprov, d.pag, d.sal, d.metodo, d.tipo, d.fpend, d.vinc - d.iinc, d.vprov - d.iprov, d.alertas,
         (d.alertas !~ 'miles|falta|<>')   -- consistente: sin errores graves (los avisos SAC no cuentan)
  FROM d ORDER BY d.fecha_compra, d.lead_id;
$f$;

-- Clientes con movimiento de abonos en el periodo que NO son ventas nuevas del periodo
-- (venta anterior, o con fecha de compra en el rango pero sin valor de plan).
-- Abono = aumento del "Pagado Hoy" (acumulado) entre el último snapshot anterior al periodo y el último del periodo.
-- Solo se detecta si el lead ya existía en la base antes del periodo.
-- Si cambian las columnas que devuelve, PostgreSQL exige borrar la función antes de recrearla

DROP FUNCTION IF EXISTS reporte.abonos_periodo(date, date);


CREATE OR REPLACE FUNCTION reporte.abonos_periodo(p_desde date, p_hasta_excl date) RETURNS TABLE (lead_id bigint, nombre_lead text, fecha_compra date, abono numeric, abono_incremento numeric, abono_proveedor numeric, pend_incremento numeric, pend_proveedor numeric, saldo numeric, fecha_pendiente date, nota text, pag_ini numeric, pag_fin numeric, confiable boolean) LANGUAGE sql STABLE AS $f$
  WITH lim AS (
    SELECT extract(epoch FROM (p_desde::timestamp AT TIME ZONE 'America/Bogota'))::bigint AS e_d,
           extract(epoch FROM (p_hasta_excl::timestamp AT TIME ZONE 'America/Bogota'))::bigint AS e_h
  ),
  snaps AS (
    SELECT (payload->>'id')::bigint AS lead_id, payload, (payload->>'updated_at')::bigint AS ua, id
    FROM staging.leads_raw WHERE payload->>'id' IS NOT NULL
  ),
  cand AS (SELECT DISTINCT s.lead_id FROM snaps s, lim WHERE s.ua >= lim.e_d AND s.ua < lim.e_h),
  ini AS (SELECT DISTINCT ON (s.lead_id) s.lead_id, s.payload FROM snaps s JOIN cand USING (lead_id), lim
          WHERE s.ua < lim.e_d ORDER BY s.lead_id, s.ua DESC, s.id DESC),
  fin AS (SELECT DISTINCT ON (s.lead_id) s.lead_id, s.payload FROM snaps s JOIN cand USING (lead_id), lim
          WHERE s.ua < lim.e_h ORDER BY s.lead_id, s.ua DESC, s.id DESC),
  cur AS (SELECT DISTINCT ON (s.lead_id) s.lead_id, s.payload FROM snaps s JOIN cand USING (lead_id)
          ORDER BY s.lead_id, s.ua DESC, s.id DESC),
  nuevas AS (SELECT vd.lead_id FROM reporte.ventas_detalle(p_desde, p_hasta_excl) vd),
  m AS (
    SELECT i.lead_id, c.payload AS cp,
           reporte._num(f.payload, ARRAY[1008406]) - COALESCE(reporte._num(i.payload, ARRAY[1008406]), 0) AS d_pag,
           COALESCE(reporte._num(i.payload, ARRAY[1008406]), 0) AS p_ini, reporte._num(f.payload, ARRAY[1008406]) AS p_fin,
           COALESCE(reporte._num(f.payload, ARRAY[1021276,1039829,1044186]), 0) - COALESCE(reporte._num(i.payload, ARRAY[1021276,1039829,1044186]), 0) AS d_inc,
           COALESCE(reporte._num(f.payload, ARRAY[1021274,1039831,1044188]), 0) - COALESCE(reporte._num(i.payload, ARRAY[1021274,1039831,1044188]), 0) AS d_prov
    FROM ini i JOIN fin f USING (lead_id) JOIN cur c USING (lead_id)
    WHERE i.lead_id NOT IN (SELECT lead_id FROM nuevas)
      AND COALESCE(c.payload->>'is_deleted','false') <> 'true'
  )
  SELECT m.lead_id, m.cp->>'name',
         (to_timestamp(NULLIF(reporte._raw(m.cp, 1016729), '')::bigint) AT TIME ZONE 'America/Bogota')::date,
         m.d_pag, m.d_inc, m.d_prov,
         reporte._num(m.cp, ARRAY[1021270,1039823,1044182]) - reporte._num(m.cp, ARRAY[1021276,1039829,1044186]),
         reporte._num(m.cp, ARRAY[1021272,1039827,1044184]) - reporte._num(m.cp, ARRAY[1021274,1039831,1044188]),
         reporte._num(m.cp, ARRAY[1016737]),
         reporte._ts(m.cp, ARRAY[1008416,1039835,1044192])::date,
         concat_ws('; ',
           CASE WHEN abs(m.d_inc + m.d_prov - m.d_pag) > 1 THEN 'el reparto incremento/proveedor no cuadra con el abono' END,
           CASE WHEN COALESCE((m.cp->>'price')::numeric, 0) = 0 THEN 'sin valor de plan en el presupuesto' END),
         m.p_ini, m.p_fin,
         (m.d_inc >= 0 AND m.d_prov >= 0 AND abs(m.d_inc + m.d_prov - m.d_pag) <= 1
          AND COALESCE(reporte._num(m.cp, ARRAY[1021270,1039823,1044182]) - reporte._num(m.cp, ARRAY[1021276,1039829,1044186]), -1) >= 0
          AND COALESCE(reporte._num(m.cp, ARRAY[1021272,1039827,1044184]) - reporte._num(m.cp, ARRAY[1021274,1039831,1044188]), -1) >= 0
          AND NOT COALESCE((SELECT bool_or(x > 0 AND x < 100000) FROM unnest(ARRAY[
                reporte._num(m.cp, ARRAY[1021270,1039823,1044182]), reporte._num(m.cp, ARRAY[1021272,1039827,1044184]),
                reporte._num(m.cp, ARRAY[1021276,1039829,1044186]), reporte._num(m.cp, ARRAY[1021274,1039831,1044188]),
                reporte._num(m.cp, ARRAY[1016737])]) x), false))
  FROM m WHERE m.d_pag > 0
  ORDER BY m.d_pag DESC, m.lead_id;
$f$;


CREATE OR REPLACE FUNCTION reporte.gerencia(p_desde date, p_hasta_excl date) RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, cuerpo text) LANGUAGE plpgsql AS $f$
DECLARE
  base text; fin text; n int; n_ok int; n_mal int; t_pres numeric; t_pres_ok numeric; t_venc numeric; n_venc int;
  t_plan numeric; t_vend numeric; t_pi numeric; t_pp numeric; t_inc numeric; t_prov numeric; t_pag numeric; t_ii numeric; t_ip numeric; t_sal numeric;
  es_mes boolean := (p_hasta_excl - p_desde) > 8; n_ab int; n_ab_ok int; t_ab numeric; t_abi numeric; t_abp numeric; t_pai numeric; t_pap numeric;
BEGIN
  base := reporte.ventas_whatsapp(p_desde, p_hasta_excl);
  DROP TABLE IF EXISTS _rf;
  CREATE TEMP TABLE _rf AS SELECT * FROM reporte.financiero_detalle(p_desde, p_hasta_excl);
  SELECT count(*), count(*) FILTER (WHERE consistente) INTO n, n_ok FROM _rf;
  n_mal := n - n_ok;
  SELECT COALESCE(sum(presupuesto), 0), COALESCE(sum(presupuesto) FILTER (WHERE consistente), 0) INTO t_pres, t_pres_ok FROM _rf;
  SELECT COALESCE(sum(saldo), 0), count(*) INTO t_venc, n_venc FROM _rf WHERE consistente AND saldo > 0 AND fecha_pendiente < (now() AT TIME ZONE 'America/Bogota')::date;
  SELECT sum(COALESCE(presupuesto, 0)) INTO t_vend FROM _rf;
  SELECT sum(total_plan), sum(valor_incremento), sum(valor_proveedor), sum(pagado), sum(ingreso_incremento), sum(ingreso_proveedor), sum(saldo)
    INTO t_plan, t_inc, t_prov, t_pag, t_ii, t_ip, t_sal FROM _rf WHERE consistente;
  SELECT sum(pend_incremento), sum(pend_proveedor) INTO t_pi, t_pp FROM _rf WHERE consistente;
  DROP TABLE IF EXISTS _ra;
  CREATE TEMP TABLE _ra AS SELECT * FROM reporte.abonos_periodo(p_desde, p_hasta_excl);
  SELECT count(*), count(*) FILTER (WHERE confiable),
         COALESCE(sum(abono) FILTER (WHERE confiable),0), COALESCE(sum(abono_incremento) FILTER (WHERE confiable),0), COALESCE(sum(abono_proveedor) FILTER (WHERE confiable),0),
         COALESCE(sum(pend_incremento) FILTER (WHERE confiable),0), COALESCE(sum(pend_proveedor) FILTER (WHERE confiable),0)
    INTO n_ab, n_ab_ok, t_ab, t_abi, t_abp, t_pai, t_pap FROM _ra;

  t_plan := COALESCE(t_plan, 0); t_inc := COALESCE(t_inc, 0); t_prov := COALESCE(t_prov, 0); t_pag := COALESCE(t_pag, 0);
  t_ii := COALESCE(t_ii, 0); t_ip := COALESCE(t_ip, 0); t_sal := COALESCE(t_sal, 0); t_pi := COALESCE(t_pi, 0); t_pp := COALESCE(t_pp, 0);
  fin := E'\n\n💰 *FINANCIERO (solo gerencia)*' || E'\n'
      || '• Valor de las ' || n || ' ventas (presupuesto): ' || reporte._m(t_pres) || E'\n'
      || '• Con datos completos y consistentes (' || n_ok || ' ventas): ' || reporte._m(t_pres_ok) || E'\n'
      || '• Excluidas por datos inconsistentes (' || n_mal || ' ventas): ' || reporte._m(t_pres - t_pres_ok) || E'\n'
      || E'\n*Análisis de las ' || n_ok || ' ventas consistentes* (valor total ' || reporte._m(t_plan) || ')' || E'\n'
      || '• Incremento (utilidad): pactado ' || reporte._m(t_inc) || ' | recaudado ' || reporte._m(t_ii) || ' | *por cobrar ' || reporte._m(t_inc - t_ii) || '*' || E'\n'
      || '• Proveedor: pactado ' || reporte._m(t_prov) || ' | recaudado ' || reporte._m(t_ip) || ' | *por cobrar ' || reporte._m(t_prov - t_ip) || '*' || E'\n'
      || '• Total recaudado: ' || reporte._m(t_pag) || ' (' || CASE WHEN t_plan > 0 THEN replace(round(100.0 * t_pag / t_plan, 1)::text, '.', ',') ELSE '0' END || ' % del total)' || E'\n'
      || '• Saldo total por cobrar: ' || reporte._m(t_sal) || E'\n'
      || '• De ese saldo, con fecha de pago ya vencida: ' || reporte._m(t_venc) || ' (' || n_venc || ' ventas)' || E'\n';
  IF n_mal > 0 THEN
    fin := fin || '⚠️ Las cifras de arriba no incluyen las ' || n_mal || ' ventas con datos por corregir (ver al final).' || E'\n';
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
      || E'\n\n💳 *ABONOS DE CLIENTES CON VENTA ANTERIOR* (no son ventas nuevas del periodo)' || E'\n'
      || CASE WHEN n_ab = 0 THEN 'Sin abonos detectados en el periodo.' ELSE
           n_ab_ok || ' clientes con datos confiables abonaron ' || reporte._m(t_ab) || ' (incremento ' || reporte._m(t_abi) || ' | proveedor ' || reporte._m(t_abp) || ')' || E'\n'
           || 'Siguen debiendo (esos clientes): incremento ' || reporte._m(t_pai) || ' | proveedor ' || reporte._m(t_pap) || E'\n'
           || COALESCE((SELECT string_agg('• ' || nombre_lead || ' (' || lead_id || '): abonó ' || reporte._m(abono) || ' [incr ' || reporte._m(abono_incremento) || ' | prov ' || reporte._m(abono_proveedor)
                   || '] | debe incr ' || reporte._m(pend_incremento) || ' | prov ' || reporte._m(pend_proveedor) || ' | saldo ' || reporte._m(saldo)
                   || COALESCE(' | vence ' || to_char(fecha_pendiente, 'DD/MM/YYYY'), '') || CASE WHEN nota <> '' THEN ' [' || nota || ']' ELSE '' END, E'\n' ORDER BY abono DESC) FROM _ra WHERE confiable), '')
           || CASE WHEN n_ab > n_ab_ok THEN E'\n\n*Abonos con reparto por revisar* (el valor abonado es el aumento del "Pagado Hoy"; el reparto incremento/proveedor no es confiable)' || E'\n'
                || (SELECT string_agg('• ' || nombre_lead || ' (' || lead_id || '): abonó ' || reporte._m(abono) || ' (pagado de ' || reporte._m(pag_ini) || ' a ' || reporte._m(pag_fin) || ') | saldo en Kommo ' || reporte._m(saldo), E'\n' ORDER BY abono DESC) FROM _ra WHERE NOT confiable) ELSE '' END
         END
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


CREATE OR REPLACE FUNCTION reporte.gerencia_semanal() RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, cuerpo text) LANGUAGE sql AS $f$
  SELECT g.* FROM reporte.semana_anterior() s, LATERAL reporte.gerencia(s.desde, s.hasta_excl) g;
$f$;


CREATE OR REPLACE FUNCTION reporte.gerencia_mensual(p_mes date DEFAULT NULL) RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, cuerpo text) LANGUAGE sql AS $f$
  WITH m AS (SELECT CASE WHEN p_mes IS NULL
                         THEN (date_trunc('month', (now() AT TIME ZONE 'America/Bogota')::date) - interval '1 month')::date
                         ELSE date_trunc('month', p_mes)::date END AS d)
  SELECT g.* FROM m, LATERAL reporte.gerencia(m.d, (m.d + interval '1 month')::date) g;
$f$;

SELECT cuerpo FROM reporte.gerencia('2026-10-01', '2026-11-01');