-- =====================================================================
-- REPORTE SEMANAL DE VENTAS (viernes a jueves) - funciones en esquema "reporte"
--   reporte.semana_anterior()                  -> rango desde / hasta_excl (viernes a jueves anterior)
--   reporte.ventas_detalle(desde, hasta_excl)  -> una fila por venta (también sirve para Looker)
--   reporte.ventas_whatsapp(desde, hasta_excl) -> texto listo para WhatsApp
--   reporte.ventas_alertas(desde, hasta_excl)  -> ventas sin fecha de nacimiento / destino / campaña
--   reporte.semanal()                          -> TODO junto para n8n (rango, texto, alertas, n ventas)
-- Se puede ejecutar varias veces sin problema.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS reporte;

CREATE OR REPLACE FUNCTION reporte.semana_anterior(p_hoy date DEFAULT NULL)
RETURNS TABLE (desde date, hasta_excl date)
LANGUAGE sql STABLE AS $f$
  WITH h AS (SELECT COALESCE(p_hoy, (now() AT TIME ZONE 'America/Bogota')::date) AS hoy),
  v AS (SELECT hoy - (((extract(dow FROM hoy))::int - 5 + 7) % 7) AS viernes FROM h)
  SELECT (viernes - 7)::date, viernes::date FROM v;
$f$;

CREATE OR REPLACE FUNCTION reporte.ventas_detalle(p_desde date, p_hasta_excl date)
RETURNS TABLE (lead_id bigint, nombre_lead text, pipeline text, fecha_compra date, fecha_creacion date,
               campana text, destino text, ciudad_lead text, ciudad_cliente text, personas int,
               precio numeric, contact_id bigint, fecha_nacimiento date, edad int)
LANGUAGE sql STABLE AS $f$
  WITH ult AS (
    SELECT DISTINCT ON ((payload->>'id')::bigint) (payload->>'id')::bigint AS lead_id, payload
    FROM staging.leads_raw WHERE payload->>'id' IS NOT NULL
    ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
  ),
  l AS (
    SELECT u.lead_id, u.payload->>'name' AS nombre_lead, (u.payload->>'pipeline_id')::bigint AS pipeline_id,
           (u.payload->>'price')::numeric AS precio,
           to_timestamp((u.payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota' AS creado_en,
           to_timestamp(NULLIF(jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1016729).values[0].value') #>> '{}','')::bigint) AT TIME ZONE 'America/Bogota' AS fecha_compra,
           jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1017098).values[0].value') #>> '{}' AS campana,
           jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1009192).values[0].value') #>> '{}' AS destino,
           COALESCE(jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1009190).values[0].value') #>> '{}',
                    jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1020628).values[0].value') #>> '{}') AS ciudad_lead,
           jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1043890).values[0].value') #>> '{}' AS personas_txt,
           u.payload #> '{_embedded,contacts}' AS contactos
    FROM ult u
    WHERE COALESCE(u.payload->>'is_deleted','false') <> 'true'
  ),
  v AS (SELECT * FROM l WHERE fecha_compra >= p_desde AND fecha_compra < p_hasta_excl),
  vc AS (
    SELECT DISTINCT ON (v.lead_id) v.lead_id, (c->>'id')::bigint AS contact_id
    FROM v, jsonb_array_elements(CASE WHEN jsonb_typeof(v.contactos)='array' THEN v.contactos ELSE '[]'::jsonb END) c
    ORDER BY v.lead_id, COALESCE((c->>'is_main')::boolean,false) DESC, (c->>'id')::bigint
  ),
  ct AS (   -- ciudad del contacto (último snapshot)
    SELECT DISTINCT ON ((payload->>'id')::bigint) (payload->>'id')::bigint AS contact_id,
           jsonb_path_query_first(payload,'$.custom_fields_values[*] ? (@.field_id == 1008538).values[0].value') #>> '{}' AS ciudad
    FROM staging.contacts_raw
    WHERE (payload->>'id')::bigint IN (SELECT contact_id FROM vc)
    ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
  )
  SELECT v.lead_id, v.nombre_lead,
         CASE v.pipeline_id WHEN 11608463 THEN 'VENTAS CALI' WHEN 11608479 THEN 'VENTAS BGTA'
                            WHEN 10684275 THEN 'SERVICIO AL CLIENTE' WHEN 10423839 THEN 'INCOMING LEADS' WHEN 11608451 THEN 'GESTION CALI'
                            WHEN 11608455 THEN 'GESTION BGTA' WHEN 11608495 THEN 'REMARKETING' ELSE v.pipeline_id::text END,
         v.fecha_compra::date, v.creado_en::date, v.campana, v.destino, v.ciudad_lead,
         COALESCE(NULLIF(btrim(ct.ciudad),''), v.ciudad_lead),
         CASE WHEN (regexp_match(v.personas_txt,'\d+'))[1] ~ '^\d{1,2}$' THEN ((regexp_match(v.personas_txt,'\d+'))[1])::int END,
         v.precio, vc.contact_id, cc.birth_date,
         CASE WHEN date_part('year', age(v.fecha_compra::date, cc.birth_date)) BETWEEN 14 AND 100
              THEN date_part('year', age(v.fecha_compra::date, cc.birth_date))::int END
  FROM v
  LEFT JOIN vc ON vc.lead_id = v.lead_id
  LEFT JOIN ct ON ct.contact_id = vc.contact_id
  LEFT JOIN crm.contacts cc ON cc.contact_id = vc.contact_id
  ORDER BY v.fecha_compra, v.lead_id;
$f$;

CREATE OR REPLACE FUNCTION reporte._fmt_fecha(p date) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT (ARRAY['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])[extract(dow FROM p)::int + 1]
         || ' ' || extract(day FROM p)::int;
$f$;


CREATE OR REPLACE FUNCTION reporte.leads_captados(p_desde date, p_hasta_excl date)
RETURNS TABLE (lead_id bigint, campana text, compro boolean)
LANGUAGE sql STABLE AS $f$
  WITH ult AS (
    SELECT DISTINCT ON ((payload->>'id')::bigint) (payload->>'id')::bigint AS lead_id, payload
    FROM staging.leads_raw WHERE payload->>'id' IS NOT NULL
    ORDER BY (payload->>'id')::bigint, (payload->>'updated_at')::bigint DESC NULLS LAST, id DESC
  )
  SELECT u.lead_id,
         jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1017098).values[0].value') #>> '{}',
         NULLIF(jsonb_path_query_first(u.payload,'$.custom_fields_values[*] ? (@.field_id == 1016729).values[0].value') #>> '{}','') IS NOT NULL
  FROM ult u
  WHERE COALESCE(u.payload->>'is_deleted','false') <> 'true'
    AND (to_timestamp((u.payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota') >= p_desde
    AND (to_timestamp((u.payload->>'created_at')::bigint) AT TIME ZONE 'America/Bogota') <  p_hasta_excl;
$f$;

-- Lista "• clave: n (pct %)" agrupando una expresión de una tabla temporal
CREATE OR REPLACE FUNCTION reporte._bloque(p_expr text, p_tabla text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
  EXECUTE format($q$
    SELECT string_agg('• ' || k || ': ' || c || ' (' || replace(round(p,1)::text,'.',',') || ' %%)', E'\n' ORDER BY c DESC, k)
    FROM (SELECT k, c, 100.0 * c / sum(c) OVER () AS p
          FROM (SELECT COALESCE((%s)::text,'(sin dato)') AS k, count(*) AS c FROM %s GROUP BY 1) a) b
  $q$, p_expr, p_tabla) INTO r;
  RETURN r;
END;
$f$;

CREATE OR REPLACE FUNCTION reporte.ventas_whatsapp(p_desde date, p_hasta_excl date)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  meses text[] := ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
  hasta date := p_hasta_excl - 1;
  periodo text; txt text; n int; total numeric; cap int; cap_ok int; prom numeric; med numeric;
  edades text; es_mes boolean; n_nuevos int;
BEGIN
  DROP TABLE IF EXISTS _rv; DROP TABLE IF EXISTS _rc;
  CREATE TEMP TABLE _rv AS SELECT * FROM reporte.ventas_detalle(p_desde, p_hasta_excl);
  CREATE TEMP TABLE _rc AS SELECT * FROM reporte.leads_captados(p_desde, p_hasta_excl);

  es_mes := (p_hasta_excl - p_desde) > 8;
  periodo := CASE WHEN es_mes AND extract(day FROM p_desde) = 1 AND extract(day FROM p_hasta_excl) = 1
                       AND p_hasta_excl = (p_desde + interval '1 month')::date
                  THEN 'Mes de ' || meses[extract(month FROM p_desde)::int] || ' de ' || extract(year FROM p_desde)::int
                  WHEN extract(month FROM p_desde) = extract(month FROM hasta)
                  THEN (CASE WHEN es_mes THEN 'Periodo del ' ELSE 'Semana del ' END) || extract(day FROM p_desde)::int || ' al ' || extract(day FROM hasta)::int
                       || ' de ' || meses[extract(month FROM hasta)::int] || ' de ' || extract(year FROM hasta)::int
                  ELSE (CASE WHEN es_mes THEN 'Periodo del ' ELSE 'Semana del ' END) || extract(day FROM p_desde)::int || ' de ' || meses[extract(month FROM p_desde)::int]
                       || ' al ' || extract(day FROM hasta)::int || ' de ' || meses[extract(month FROM hasta)::int]
                       || ' de ' || extract(year FROM hasta)::int END;

  SELECT count(*), COALESCE(sum(precio),0) INTO n, total FROM _rv;
  SELECT count(*), count(*) FILTER (WHERE compro) INTO cap, cap_ok FROM _rc;

  txt := '📊 *REPORTE DE VENTAS' || CASE WHEN es_mes THEN ' DEL MES' ELSE '' END || '*' || E'\n' || periodo || E'\n\n';

  IF n = 0 THEN
    txt := txt || '✅ *Ventas totales: 0*' || E'\n(No hay ventas con fecha de compra en el periodo.)' || E'\n\n';
  ELSE
    txt := txt || '✅ *Ventas totales: ' || n || '*' || E'\n'
        || 'Valor vendido: $' || replace(to_char(total, 'FM999,999,999,999'), ',', '.') || E'\n'
        || CASE WHEN es_mes THEN 'Ticket promedio: $' || replace(to_char(total / n, 'FM999,999,999,999'), ',', '.') || E'\n' ELSE '' END || E'\n'
        || '🌎 *Por destino*' || E'\n' || reporte._bloque('destino', '_rv') || E'\n\n'
        || '📣 *Por campaña*' || E'\n' || reporte._bloque('campana', '_rv') || E'\n\n'
        || '📍 *Por ciudad*' || E'\n' || reporte._bloque('upper(translate(ciudad_cliente, ''ÁÉÍÓÚáéíóú'', ''AEIOUaeiou''))', '_rv') || E'\n\n'
        || '🏢 *Por pipeline*' || E'\n' || reporte._bloque('pipeline', '_rv') || E'\n\n'
        || CASE WHEN es_mes THEN '📅 *Por semana*' ELSE '📅 *Por día*' END || E'\n'
        || (SELECT string_agg(
              CASE WHEN es_mes THEN '• Del ' || extract(day FROM ini)::int || ' al ' || extract(day FROM fin)::int || ': ' || c
                   ELSE '• ' || reporte._fmt_fecha(ini) || ': ' || c END, E'\n' ORDER BY ini)
            FROM (SELECT CASE WHEN es_mes THEN GREATEST(date_trunc('week', fecha_compra)::date, p_desde) ELSE fecha_compra END AS ini,
                         CASE WHEN es_mes THEN LEAST((date_trunc('week', fecha_compra)::date + 6), hasta) ELSE fecha_compra END AS fin,
                         count(*) AS c
                  FROM _rv GROUP BY 1, 2) x) || E'\n\n';

    SELECT round(avg(fecha_compra - fecha_creacion), 1),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY (fecha_compra - fecha_creacion))
      INTO prom, med FROM _rv;
    txt := txt || '⏱️ *Tiempo de cierre*' || E'\n'
        || 'Mediana: ' || replace(round(med::numeric, 1)::text, '.', ',') || ' días | Promedio: '
        || replace(prom::text, '.', ',') || ' días' || E'\n';
    IF es_mes THEN
      SELECT round(avg(fecha_compra - fecha_creacion), 1),
             percentile_cont(0.5) WITHIN GROUP (ORDER BY (fecha_compra - fecha_creacion)),
             count(*)
        INTO prom, med, n_nuevos FROM _rv WHERE fecha_creacion >= p_desde;
      txt := txt || CASE WHEN n_nuevos > 0
                         THEN 'Solo leads captados en el mes (' || n_nuevos || ' ventas): mediana ' || replace(round(med::numeric, 1)::text, '.', ',')
                              || ' días | promedio ' || replace(prom::text, '.', ',') || ' días' || E'\n'
                         ELSE '' END
                 || '(' || (SELECT count(*) FROM _rv WHERE fecha_creacion < p_desde) || ' ventas vienen de leads de meses anteriores)' || E'\n';
    END IF;
    txt := txt || E'\n';

    SELECT string_agg(rango || ': ' || c, E'\n' ORDER BY ord) INTO edades
    FROM (SELECT CASE WHEN edad < 26 THEN 1 WHEN edad < 36 THEN 2 WHEN edad < 46 THEN 3 WHEN edad < 56 THEN 4 ELSE 5 END AS ord,
                 '• ' || CASE WHEN edad < 26 THEN '18-25' WHEN edad < 36 THEN '26-35' WHEN edad < 46 THEN '36-45'
                              WHEN edad < 56 THEN '46-55' ELSE '56+' END AS rango,
                 count(*) AS c
          FROM _rv WHERE edad IS NOT NULL GROUP BY 1, 2) e;
    txt := txt || '🎂 *Edad de los clientes*' || E'\n'
        || COALESCE(edades || E'\n' || 'Promedio: ' || replace((SELECT round(avg(edad),1)::text FROM _rv), '.', ',') || ' años'
                    || CASE WHEN (SELECT count(*) FROM _rv WHERE edad IS NULL) > 0
                            THEN ' (sin dato en ' || (SELECT count(*) FROM _rv WHERE edad IS NULL) || ' de ' || n || ')' ELSE '' END,
                    'Sin dato en las ' || n || ' ventas (fecha de nacimiento no registrada)') || E'\n\n';
  END IF;

  txt := txt || '🎯 *Captación de leads: ' || cap || '*' || E'\n'
      || COALESCE(reporte._bloque('campana', '_rc'), '(sin leads creados en el periodo)') || E'\n\n'
      || '🔄 *Conversión*' || E'\n'
      || '• Simple (ventas / leads ' || CASE WHEN es_mes THEN 'del mes' ELSE 'de la semana' END || '): ' || COALESCE(replace(round(100.0 * n / NULLIF(cap,0), 1)::text, '.', ','), '0') || ' %' || E'\n'
      || '• De cohorte (leads ' || CASE WHEN es_mes THEN 'del mes' ELSE 'de la semana' END || ' que ya compraron): ' || COALESCE(replace(round(100.0 * cap_ok / NULLIF(cap,0), 1)::text, '.', ','), '0') || ' %';

  RETURN txt;
END;
$f$;

CREATE OR REPLACE FUNCTION reporte.ventas_alertas(p_desde date, p_hasta_excl date)
RETURNS text LANGUAGE sql STABLE AS $f$
  SELECT COALESCE(string_agg('• ' || nombre_lead || ' (lead ' || lead_id || '): falta ' || faltan, E'\n' ORDER BY fecha_compra, lead_id),
                  'Sin alertas: todas las ventas tienen los datos clave.')
  FROM (
    SELECT lead_id, nombre_lead, fecha_compra,
           concat_ws(', ',
             CASE WHEN fecha_nacimiento IS NULL THEN 'fecha de nacimiento' END,
             CASE WHEN destino IS NULL THEN 'destino' END,
             CASE WHEN campana IS NULL THEN 'campaña' END,
             CASE WHEN personas IS NULL THEN 'personas que viajan' END,
             CASE WHEN contact_id IS NULL THEN 'contacto asociado' END) AS faltan
    FROM reporte.ventas_detalle(p_desde, p_hasta_excl)
  ) t WHERE faltan <> '';
$f$;

-- Todo junto para n8n. Sin parámetros = semana anterior (viernes a jueves). Con fechas = rango manual.
CREATE OR REPLACE FUNCTION reporte.semanal(p_desde date DEFAULT NULL, p_hasta_excl date DEFAULT NULL)
RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, whatsapp text, alertas text)
LANGUAGE plpgsql AS $f$
DECLARE d date; h date;
BEGIN
  IF p_desde IS NULL OR p_hasta_excl IS NULL THEN
    SELECT s.desde, s.hasta_excl INTO d, h FROM reporte.semana_anterior() s;
  ELSE d := p_desde; h := p_hasta_excl; END IF;
  desde := d; hasta_excl := h;
  whatsapp := reporte.ventas_whatsapp(d, h);
  n_ventas := (SELECT count(*) FROM reporte.ventas_detalle(d, h));
  alertas  := reporte.ventas_alertas(d, h);
  asunto   := 'Reporte de ventas Viajero Calificado: ' || to_char(d, 'DD/MM/YYYY') || ' al ' || to_char(h - 1, 'DD/MM/YYYY');
  RETURN NEXT;
END;
$f$;

-- REPORTE MENSUAL: sin parámetro = mes anterior completo (ej. el 1 de noviembre -> octubre). Con una fecha cualquiera del mes = ese mes.
CREATE OR REPLACE FUNCTION reporte.mensual(p_mes date DEFAULT NULL)
RETURNS TABLE (desde date, hasta_excl date, n_ventas int, asunto text, whatsapp text, alertas text)
LANGUAGE plpgsql AS $f$
DECLARE d date; h date;
BEGIN
  IF p_mes IS NULL THEN
    d := (date_trunc('month', (now() AT TIME ZONE 'America/Bogota')::date) - interval '1 month')::date;
  ELSE
    d := date_trunc('month', p_mes)::date;
  END IF;
  h := (d + interval '1 month')::date;
  desde := d; hasta_excl := h;
  whatsapp := reporte.ventas_whatsapp(d, h);
  n_ventas := (SELECT count(*) FROM reporte.ventas_detalle(d, h));
  alertas  := reporte.ventas_alertas(d, h);
  asunto   := 'Reporte MENSUAL de ventas Viajero Calificado: ' ||
              (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'])[extract(month FROM d)::int] || ' ' || extract(year FROM d)::int;
  RETURN NEXT;
END;
$f$;
SELECT whatsapp FROM reporte.mensual('2026-10-15');

/*SELECT f->>'field_id' AS field_id, f->>'field_name' AS nombre, f->>'field_type' AS tipo,
       count(DISTINCT (r.payload->>'id')::bigint) AS leads_con_dato
FROM staging.leads_raw r,
     jsonb_array_elements(CASE WHEN jsonb_typeof(r.payload->'custom_fields_values') = 'array'
                               THEN r.payload->'custom_fields_values' ELSE '[]'::jsonb END) f
WHERE r.extracted_at >= now() - interval '30 days'
  AND f->>'field_name' ~* 'plan|incremento|proveedor|pagado|pago|saldo'
GROUP BY 1, 2, 3
ORDER BY 2;*/

SELECT CASE WHEN f->>'field_id' IN ('1039825','1039823','1039827') THEN 'SAC 10398xx'
            WHEN f->>'field_id' IN ('1044180','1044182','1044184') THEN 'SAC 10441xx' END AS set_sac,
       (r.payload->>'pipeline_id') AS pipeline, count(DISTINCT (r.payload->>'id')::bigint) AS leads,
       min(to_timestamp((r.payload->>'updated_at')::bigint))::date AS desde,
       max(to_timestamp((r.payload->>'updated_at')::bigint))::date AS hasta
FROM staging.leads_raw r,
     jsonb_array_elements(CASE WHEN jsonb_typeof(r.payload->'custom_fields_values')='array' THEN r.payload->'custom_fields_values' ELSE '[]'::jsonb END) f
WHERE r.extracted_at >= now() - interval '60 days'
  AND f->>'field_id' IN ('1039825','1039823','1039827','1044180','1044182','1044184')
GROUP BY 1, 2 ORDER BY 1, 2;