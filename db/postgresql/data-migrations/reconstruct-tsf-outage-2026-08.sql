-- =====================================================================
-- Reconstruccion de metricas TSF durante la caida de agosto 2026
-- Tecnica: promedio estacional por bloques (dia de semana x hora) +
--          bootstrap de visitas reales del mismo bloque estacional.
--
-- QUE HACE Y QUE NO
--   Rellena  session + website_event  del sitio TSF entre el ultimo evento
--   real (20 ago 12:24 hora local) y el primero tras el retorno (31 ago
--   11:12). Son ~11 dias, no una semana.
--
--   El volumen sale del promedio estacional por bloque (dia de semana x
--   hora, en hora de Bogota), reescalado por la tendencia entre el tramo
--   previo y el posterior. El CONTENIDO no se inventa: se copian recorridos
--   de visitas reales del mismo bloque estacional (mismas paginas, mismos
--   referrers, mismos tiempos entre pageviews), reasignados a visitantes.
--
--   NO reconstruye session_replay ni heatmap_event: son grabaciones
--   literales de sesiones, no agregados, y no tiene sentido sintetizarlas.
--   Esas dos ventanas quedan vacias.
--
-- LIMITACIONES CONOCIDAS (medidas contra los datos reales)
--   * pageviews y visitantes unicos: clavados por construccion.
--   * paginas por visita 7.72 vs 7.77 real; visitas ~1% por debajo.
--   * tasa de rebote 17.7% vs 15.3% real (+2.4 pp): al recortar la ultima
--     visita de cada hora para clavar el total aparecen visitas de 1 pagina.
--   * duracion media de visita 889s vs 986s real (-10%).
--   * sabado y domingo se estiman con UN solo fin de semana observado
--     (15-16 ago). Es la parte mas fragil del modelo; en volumen son <1%.
--   * los lunes de 00h a 09h no tienen ninguna observacion y se extrapolan
--     como nivel_diario x perfil horario laboral.
--   * paises con muy pocos visitantes reales (CL, EC) pueden quedar sobre o
--     sub representados a nivel de pageviews; a nivel de visitante la
--     distribucion de pais/navegador/dispositivo si reproduce la real.
--   * EL USO POR PERSONA QUEDA DEMASIADO PAREJO. El visitante mas activo real
--     hizo 2489 pageviews en 10 dias; el reconstruido llega a 318. Los 10 mas
--     activos explican 49.5% del trafico real y solo 21.4% del reconstruido.
--     Y de los 11 visitantes reales con 7+ dias activos no queda ninguno.
--     Causa: la regla de "un slot por visitante por hora" (seccion 8b) le pone
--     techo a lo que puede acumular una persona en un dia, y los visitantes
--     nuevos que van naciendo diluyen al nucleo recurrente en el sorteo diario.
--     => Los agregados (pageviews, visitantes, visitas, paginas, horarios) son
--        confiables. Los analisis POR PERSONA dentro del hueco no lo son:
--        usuarios mas intensivos, retencion y cohortes quedan distorsionados.
--
-- Ejecutar:  psql "$DATABASE_URL" -f reconstruct-tsf-outage-2026-08.sql
-- Deshacer:  ver seccion 9 al final.
--
-- Todo lo insertado queda marcado con website_event.tag = <cfg.tag>,
-- y las sesiones nuevas quedan con created_at dentro del hueco.
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- ---------------------------------------------------------------------
-- 0. PARAMETROS
-- ---------------------------------------------------------------------
CREATE TEMP TABLE cfg AS
SELECT '946007d8-2564-4ef1-b3df-53540a887eef'::uuid AS website_id,
       'America/Bogota'::text                       AS tz,
       -- fecha cualquiera DENTRO de la caida: sirve para detectar los bordes
       '2026-08-25'::date                           AS probe,
       -- ventana de entrenamiento del modelo estacional (fechas locales)
       '2026-08-10 10:00'::timestamp                AS cov_from_local,
       -- fechas locales a excluir del entrenamiento (festivos / anomalias)
       ARRAY['2026-08-17']::date[]                  AS excl_dates,
       'recon-2026-08'::text                        AS tag,
       true                                         AS trend_interp,
       -- Correccion del sesgo de tamano del muestreador (seccion 6). Tomar
       -- visitas hasta agotar un presupuesto de pageviews favorece a las
       -- visitas cortas (paradoja de la inspeccion). Calibrado sobre los
       -- datos: 0.05 clava paginas-por-visita y el numero de visitas;
       -- subirlo a 0.20 mejora el rebote pero alarga las visitas.
       0.05::numeric                                AS size_bias_alpha;

COMMENT ON COLUMN cfg.cov_from_local IS
  'El 10-ago no hay eventos antes de 09:43 local y no se puede distinguir '
  '"sin trafico" de "sin tracker", asi que ese tramo no cuenta como observado.';

-- generador pseudoaleatorio determinista: mismo resultado en local y en prod
CREATE FUNCTION pg_temp.rnd(key text) RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT (('x' || substr(md5('recon-tsf-2026-08-v1|' || key), 1, 8))::bit(32)::bigint
          & 2147483647) / 2147483647.0
$$;

-- Guard: el script no es idempotente por diseno (los ids son deterministas,
-- asi que un segundo intento choca contra la PK). Se aborta explicitamente.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM website_event
              WHERE website_id = (SELECT website_id FROM cfg)
                AND tag = (SELECT tag FROM cfg)) THEN
    RAISE EXCEPTION 'Ya existen eventos con tag=%. Corre primero el rollback de la seccion final.',
                    (SELECT tag FROM cfg);
  END IF;
END $$;

-- fechas excluidas del entrenamiento, como tabla (comodo para NOT EXISTS)
CREATE TEMP TABLE excl AS SELECT unnest(excl_dates) AS d FROM cfg;

-- uuid determinista a partir de una clave
CREATE FUNCTION pg_temp.duuid(key text) RETURNS uuid
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT md5('recon-tsf-2026-08-v1|' || key)::uuid
$$;

-- ---------------------------------------------------------------------
-- 1. BORDES DE LA CAIDA Y CALENDARIO DE COBERTURA
-- ---------------------------------------------------------------------
CREATE TEMP TABLE win AS
SELECT (SELECT max(created_at) FROM website_event
         WHERE website_id = c.website_id AND tag IS NULL
           AND created_at < c.probe)                       AS gap_start,
       (SELECT min(created_at) FROM website_event
         WHERE website_id = c.website_id AND tag IS NULL
           AND created_at > c.probe)                       AS gap_end,
       (SELECT max(created_at) FROM website_event
         WHERE website_id = c.website_id AND tag IS NULL)   AS last_event,
       (c.cov_from_local AT TIME ZONE c.tz)                AS cov_from
FROM cfg c;

\echo '>>> Bordes detectados de la caida:'
SELECT gap_start, gap_end, justify_interval(gap_end - gap_start) AS duracion FROM win;

-- Un bloque (fecha local, hora) esta "observado" si cae completo dentro de
-- una ventana de uptime: [cov_from, gap_start)  o  [gap_end, last_event).
CREATE TEMP TABLE cov AS
WITH g AS (
  SELECT (d + make_interval(hours => h))::timestamp AS blk_local, h,
         d::date AS d, extract(isodow FROM d)::int AS isodow
  FROM generate_series((SELECT cov_from_local::date FROM cfg),
                       (SELECT (last_event AT TIME ZONE (SELECT tz FROM cfg))::date FROM win),
                       '1 day') d
  CROSS JOIN generate_series(0, 23) h
)
SELECT g.d, g.h, g.isodow,
       CASE WHEN g.isodow <= 5 THEN 1 ELSE 2 END AS daytype,
       (g.blk_local AT TIME ZONE c.tz)                          AS blk_start,
       (g.blk_local AT TIME ZONE c.tz) + interval '1 hour'      AS blk_end
FROM g CROSS JOIN cfg c CROSS JOIN win w
WHERE NOT (g.d = ANY (c.excl_dates))
  AND (
        ((g.blk_local AT TIME ZONE c.tz) >= w.cov_from
          AND (g.blk_local AT TIME ZONE c.tz) + interval '1 hour' <= w.gap_start)
     OR ((g.blk_local AT TIME ZONE c.tz) >= w.gap_end
          AND (g.blk_local AT TIME ZONE c.tz) + interval '1 hour' <= w.last_event)
      );

-- conteos observados por bloque
CREATE TEMP TABLE obs AS
SELECT c.d, c.h, c.isodow, c.daytype,
       count(e.event_id)              AS views,
       count(DISTINCT e.visit_id)     AS visits
FROM cov c
LEFT JOIN website_event e
       ON e.website_id = (SELECT website_id FROM cfg)
      AND e.tag IS NULL
      AND e.created_at >= c.blk_start
      AND e.created_at <  c.blk_end
GROUP BY 1, 2, 3, 4;

-- ---------------------------------------------------------------------
-- 2. MODELO ESTACIONAL
--    2a. perfil horario por tipo de dia (solo dias con las 24h observadas)
--    2b. nivel diario por dia de semana, corregido por cobertura parcial
--    2c. media del bloque (isodow, hora); si el bloque no tiene ninguna
--        observacion se extrapola como nivel_diario * share_horario
-- ---------------------------------------------------------------------
CREATE TEMP TABLE shr AS
WITH full_days AS (SELECT d FROM cov GROUP BY d HAVING count(*) = 24)
SELECT o.daytype, o.h,
       sum(o.views)::numeric
         / NULLIF(sum(sum(o.views)) OVER (PARTITION BY o.daytype), 0) AS share
FROM obs o JOIN full_days f USING (d)
GROUP BY o.daytype, o.h;

CREATE TEMP TABLE day_lvl AS
SELECT o.d, o.isodow, o.daytype,
       sum(o.views)  AS views_obs,
       sum(s.share)  AS cvg
FROM obs o JOIN shr s ON s.daytype = o.daytype AND s.h = o.h
GROUP BY 1, 2, 3;

CREATE TEMP TABLE lvl AS
SELECT isodow, daytype, count(*) AS n_days,
       sum(views_obs) / sum(cvg) AS nivel        -- media ponderada por cobertura
FROM day_lvl GROUP BY 1, 2;

CREATE TEMP TABLE blk AS
WITH grid AS (
  SELECT i AS isodow, h, CASE WHEN i <= 5 THEN 1 ELSE 2 END AS daytype
  FROM generate_series(1, 7) i CROSS JOIN generate_series(0, 23) h
),
o AS (SELECT isodow, h, avg(views) AS mv, count(*) AS n FROM obs GROUP BY 1, 2)
SELECT g.isodow, g.h, g.daytype,
       coalesce(o.n, 0)                                AS n_obs,
       (o.mv IS NULL)                                  AS extrapolado,
       coalesce(o.mv, l.nivel * s.share, 0)::numeric   AS views_model
FROM grid g
LEFT JOIN o   USING (isodow, h)
LEFT JOIN lvl l ON l.isodow  = g.isodow
LEFT JOIN shr s ON s.daytype = g.daytype AND s.h = g.h;

\echo '>>> Nivel diario estimado por dia de semana (1=Lun .. 7=Dom):'
SELECT isodow, n_days, round(nivel) AS views_dia FROM lvl ORDER BY isodow;

-- ---------------------------------------------------------------------
-- 3. TENDENCIA: el nivel desestacionalizado crece entre el tramo previo y
--    el posterior a la caida. Se interpola linealmente sobre el hueco.
--    (con cfg.trend_interp = false el factor queda en 1.0)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE trend AS
WITH wk AS (   -- dias laborales con cobertura suficiente
  SELECT dl.d, dl.views_obs / dl.cvg AS total_est
  FROM day_lvl dl WHERE dl.isodow <= 5 AND dl.cvg > 0.4
),
dowf AS (
  SELECT dl.isodow,
         avg(dl.views_obs / dl.cvg)
           / (SELECT avg(total_est) FROM wk) AS f
  FROM day_lvl dl WHERE dl.isodow <= 5 AND dl.cvg > 0.4
  GROUP BY 1
),
deseas AS (
  SELECT dl.d, (dl.views_obs / dl.cvg) / f.f AS nivel
  FROM day_lvl dl JOIN dowf f USING (isodow)
  WHERE dl.isodow <= 5 AND dl.cvg > 0.4
),
sides AS (
  SELECT avg(nivel) FILTER (WHERE d <  (SELECT (gap_start AT TIME ZONE (SELECT tz FROM cfg))::date FROM win)) AS l_pre,
         avg(nivel) FILTER (WHERE d >  (SELECT (gap_end   AT TIME ZONE (SELECT tz FROM cfg))::date FROM win)) AS l_post,
         avg(nivel)                                                                                          AS l_pool,
         avg(d - date '2026-01-01') FILTER (WHERE d <  (SELECT (gap_start AT TIME ZONE (SELECT tz FROM cfg))::date FROM win)) AS c_pre,
         avg(d - date '2026-01-01') FILTER (WHERE d >  (SELECT (gap_end   AT TIME ZONE (SELECT tz FROM cfg))::date FROM win)) AS c_post
  FROM deseas
)
SELECT * FROM sides;

\echo '>>> Nivel desestacionalizado antes / despues de la caida:'
SELECT round(l_pre) AS nivel_pre, round(l_post) AS nivel_post, round(l_pool) AS nivel_pool,
       round((l_post/l_pre - 1) * 100, 1) AS crecimiento_pct
FROM trend;

-- ---------------------------------------------------------------------
-- 4. OBJETIVO POR (FECHA LOCAL, HORA) DENTRO DEL HUECO
--    Las horas de borde se prorratean por la fraccion realmente perdida.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE gap_hour AS
WITH grid AS (
  SELECT d::date AS d, h,
         extract(isodow FROM d)::int AS isodow,
         ((d::date + make_interval(hours => h))::timestamp AT TIME ZONE (SELECT tz FROM cfg)) AS blk_start
  FROM generate_series(
         (SELECT (gap_start AT TIME ZONE (SELECT tz FROM cfg))::date FROM win),
         (SELECT (gap_end   AT TIME ZONE (SELECT tz FROM cfg))::date FROM win),
         '1 day') d
  CROSS JOIN generate_series(0, 23) h
),
eff AS (
  SELECT g.d, g.h, g.isodow,
         CASE WHEN g.isodow <= 5 AND NOT EXISTS (SELECT 1 FROM excl x WHERE x.d = g.d) THEN 1 ELSE 2 END AS daytype,
         GREATEST(g.blk_start, w.gap_start)                        AS eff_start,
         LEAST(g.blk_start + interval '1 hour', w.gap_end)         AS eff_end
  FROM grid g CROSS JOIN win w
),
f AS (
  SELECT e.*,
         extract(epoch FROM (e.eff_end - e.eff_start)) / 3600.0 AS frac,
         CASE WHEN (SELECT trend_interp FROM cfg)
              THEN (t.l_pre + (t.l_post - t.l_pre)
                     * LEAST(1, GREATEST(0, ((e.d - date '2026-01-01') - t.c_pre) / NULLIF(t.c_post - t.c_pre, 0)))) / t.l_pool
              ELSE 1.0 END AS lvl_factor
  FROM eff e CROSS JOIN trend t
  WHERE e.eff_end > e.eff_start
)
SELECT f.d, f.h, f.isodow, f.daytype, f.eff_start, f.eff_end, f.frac,
       round(f.lvl_factor, 4) AS lvl_factor,
       (f.h / 3) * 3          AS band,
       GREATEST(0, round(b.views_model * f.frac * f.lvl_factor))::int AS target_views
FROM f JOIN blk b ON b.isodow = f.isodow AND b.h = f.h;

\echo '>>> Objetivo de pageviews por dia del hueco:'
SELECT d, to_char(d, 'Dy') AS dow, round(min(lvl_factor), 3) AS factor_nivel,
       sum(target_views) AS pageviews_objetivo
FROM gap_hour GROUP BY 1, 2 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 5. POOL DE CONTENIDO: visitas reales agrupadas por bloque estacional
--    (tipo de dia x banda de 3h). De aqui se copian recorridos completos.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE pool AS
WITH v AS (
  SELECT e.visit_id, min(e.created_at) AS v_start, count(*) AS ev
  FROM website_event e
  WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
  GROUP BY 1
)
SELECT v.visit_id, v.v_start, v.ev,
       CASE WHEN extract(isodow FROM v.v_start AT TIME ZONE (SELECT tz FROM cfg)) <= 5
                 AND NOT EXISTS (SELECT 1 FROM excl x WHERE x.d = (v.v_start AT TIME ZONE (SELECT tz FROM cfg))::date)
            THEN 1 ELSE 2 END AS daytype,
       (extract(hour FROM v.v_start AT TIME ZONE (SELECT tz FROM cfg))::int / 3) * 3 AS band
FROM v;

-- si una banda no tiene visitas, se usa la banda mas cercana del mismo tipo de dia
CREATE TEMP TABLE band_map AS
WITH have AS (SELECT daytype, band, count(*) n FROM pool GROUP BY 1, 2),
     need AS (SELECT DISTINCT daytype, band FROM gap_hour)
SELECT n.daytype, n.band,
       coalesce(h.band,
                (SELECT h2.band FROM have h2 WHERE h2.daytype = n.daytype
                  ORDER BY abs(h2.band - n.band), h2.band LIMIT 1)) AS src_band
FROM need n LEFT JOIN have h ON h.daytype = n.daytype AND h.band = n.band;

-- ---------------------------------------------------------------------
-- 6. SLOTS DE VISITA: se van tomando visitas del bloque hasta cubrir el
--    objetivo de la hora; la ultima se recorta para clavar el total.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE gap_slot AS
WITH cand AS (
  SELECT g.d, g.h, g.daytype, g.target_views, g.eff_start, g.eff_end,
         p.visit_id AS src_visit, p.ev,
         pow(pg_temp.rnd('slot|' || g.d || '|' || g.h || '|' || p.visit_id),
             1.0 / pow(p.ev, (SELECT size_bias_alpha FROM cfg))) AS k
  FROM gap_hour g
  JOIN band_map m ON m.daytype = g.daytype AND m.band = g.band
  JOIN pool     p ON p.daytype = g.daytype AND p.band = m.src_band
  WHERE g.target_views > 0
),
ord AS (
  SELECT c.*,
         sum(c.ev) OVER (PARTITION BY c.d, c.h ORDER BY c.k DESC, c.src_visit) - c.ev AS ev_before,
         row_number() OVER (PARTITION BY c.d, c.h ORDER BY c.k DESC, c.src_visit)     AS slot_no
  FROM cand c
)
SELECT d, h, daytype, slot_no, src_visit,
       LEAST(ev, target_views - ev_before)::int AS keep_events,
       -- arranque dentro de la ventana efectiva, dejando margen para la visita
       eff_start + make_interval(secs =>
         pg_temp.rnd('start|' || d || '|' || h || '|' || slot_no)
         * GREATEST(60, extract(epoch FROM (eff_end - eff_start)) - 300)) AS slot_start,
       pg_temp.duuid('visit|' || d || '|' || h || '|' || slot_no) AS visit_id
FROM ord
WHERE ev_before < target_views;

-- ---------------------------------------------------------------------
-- 7. ROSTER DE VISITANTES POR DIA
--    n_activos      = pageviews objetivo / (pageviews por visitante)
--    n_nuevos       = n_activos * (share de visitantes nuevos)
--    Los dias de borde (con datos reales) no generan visitantes nuevos y
--    reutilizan las sesiones que ese mismo dia ya estaban activas.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE ratio AS
WITH full_days AS (SELECT d FROM cov GROUP BY d HAVING count(*) = 24),
per_day AS (
  SELECT f.d,
         CASE WHEN extract(isodow FROM f.d) <= 5 THEN 1 ELSE 2 END AS daytype,
         count(e.event_id)                                    AS views,
         count(DISTINCT e.session_id)                          AS act,
         count(DISTINCT s.session_id) FILTER (
           WHERE (s.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = f.d) AS nuevos
  FROM full_days f
  JOIN website_event e
    ON e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
   AND (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = f.d
  LEFT JOIN session s ON s.session_id = e.session_id
  GROUP BY 1, 2
)
SELECT daytype,
       avg(views::numeric / act)    AS views_por_visitante,
       avg(nuevos::numeric / act)   AS share_nuevos,
       avg(act::numeric)            AS visitantes_medios
FROM per_day GROUP BY 1;

\echo '>>> Ratios observados por tipo de dia (1=laboral, 2=fin de semana):'
SELECT daytype, round(views_por_visitante, 2) AS views_x_visitante,
       round(share_nuevos, 3) AS share_nuevos FROM ratio ORDER BY daytype;

CREATE TEMP TABLE gap_day AS
WITH t AS (
  SELECT g.d, min(g.daytype) AS daytype, sum(g.target_views) AS views_target
  FROM gap_hour g GROUP BY g.d
),
real_act AS (   -- sesiones reales activas en los dias de borde
  SELECT (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date AS d,
         count(DISTINCT e.session_id) AS n
  FROM website_event e
  WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
  GROUP BY 1
)
SELECT t.d, t.daytype, t.views_target,
       (ra.n IS NOT NULL) AS dia_borde,
       GREATEST(1, round(t.views_target / r.views_por_visitante))::int AS n_activos,
       CASE WHEN ra.n IS NOT NULL THEN 0
            ELSE round(GREATEST(1, round(t.views_target / r.views_por_visitante))
                       * r.share_nuevos)::int END AS n_nuevos
FROM t
JOIN ratio r ON r.daytype = t.daytype
LEFT JOIN real_act ra ON ra.d = t.d
WHERE t.views_target > 0;

\echo '>>> Visitantes a reconstruir por dia:'
SELECT d, to_char(d,'Dy') dow, views_target, n_activos, n_nuevos,
       n_activos - n_nuevos AS n_recurrentes, dia_borde
FROM gap_day ORDER BY d;

-- 7a. sesiones nuevas: se clona el perfil (navegador/SO/pantalla/geo) de
--     sesiones reales, con id determinista y fecha dentro del hueco.
CREATE TEMP TABLE new_sess AS
WITH slots AS (
  SELECT d, generate_series(1, n_nuevos) AS i FROM gap_day WHERE n_nuevos > 0
),
prof AS (
  SELECT s.*, row_number() OVER (ORDER BY pg_temp.rnd('prof|' || s.session_id)) AS rn,
         count(*) OVER () AS tot
  FROM session s WHERE s.website_id = (SELECT website_id FROM cfg)
    AND s.created_at < (SELECT gap_start FROM win)
),
pick AS (
  SELECT sl.d, sl.i,
         (floor(pg_temp.rnd('newprof|' || sl.d || '|' || sl.i) * (SELECT max(tot) FROM prof)) + 1)::int AS rn
  FROM slots sl
)
SELECT pg_temp.duuid('newsess|' || pk.d || '|' || pk.i) AS session_id,
       pk.d, p.browser, p.os, p.device, p.screen, p.language, p.country, p.region, p.city
FROM pick pk JOIN prof p USING (rn);

-- Cada visitante lleva DOS pesos, que responden a preguntas distintas:
--   peso_sel = probabilidad de volver un dia cualquiera  -> a quien se elige
--   peso_int = visitas que hace en un dia activo         -> cuanto navega
-- Mezclarlos infla los visitantes unicos: el 65% de las sesiones reales
-- aparecio un solo dia y no debe reaparecer a lo largo del hueco.
CREATE TEMP TABLE recur AS
WITH act AS (
  SELECT e.session_id,
         count(DISTINCT (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date) AS dias,
         count(DISTINCT e.visit_id)                                             AS visitas,
         min((e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date)            AS nace
  FROM website_event e
  WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
    AND e.created_at < (SELECT gap_start FROM win)
  GROUP BY 1
)
SELECT a.session_id, a.dias, a.visitas, a.nace,
       -- tasa de repeticion tras el primer dia, con suavizado de Laplace
       ((a.dias - 1) + 0.5)
         / (GREATEST(0, (SELECT (gap_start AT TIME ZONE (SELECT tz FROM cfg))::date FROM win) - a.nace) + 2.0)
                                                   AS peso_sel,
       GREATEST(0.25, a.visitas::numeric / a.dias) AS peso_int
FROM act a;

-- Perfil de comportamiento para las sesiones nuevas: se muestrea una sesion
-- real completa (recurrencia + intensidad de su primer dia), no un promedio.
CREATE TEMP TABLE behav AS
WITH fd AS (
  SELECT r.session_id, r.peso_sel,
         GREATEST(0.25, count(DISTINCT e.visit_id)::numeric) AS peso_int
  FROM recur r
  JOIN website_event e ON e.session_id = r.session_id AND e.tag IS NULL
   AND (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = r.nace
  GROUP BY 1, 2
)
SELECT row_number() OVER (ORDER BY session_id) AS rn, peso_sel, peso_int,
       count(*) OVER () AS tot
FROM fd;

ALTER TABLE new_sess ADD COLUMN peso_sel numeric;
ALTER TABLE new_sess ADD COLUMN peso_int numeric;
UPDATE new_sess ns SET peso_sel = b.peso_sel, peso_int = b.peso_int
FROM behav b
WHERE b.rn = (floor(pg_temp.rnd('behav|' || ns.session_id)
                    * (SELECT max(tot) FROM behav)) + 1)::int;

-- Nucleo de recurrentes. En los datos reales solo un grupo pequeno y muy
-- fiel reaparece (en los 10 dias previos a la caida reaparecieron 40
-- sesiones preexistentes, cada una ~6 veces). Sin acotar el pool, el
-- muestreo ponderado va filtrando visitantes de una sola vez y los
-- visitantes unicos del hueco se inflan. Se dimensiona el nucleo con la
-- misma medida observada sobre una ventana de la longitud del hueco.
CREATE TEMP TABLE core AS
WITH nd AS (
  SELECT GREATEST(1, (gap_end AT TIME ZONE (SELECT tz FROM cfg))::date
                   - (gap_start AT TIME ZONE (SELECT tz FROM cfg))::date) AS n FROM win
),
k AS (
  SELECT GREATEST(
           (SELECT count(DISTINCT e.session_id)
              FROM website_event e JOIN session s USING (session_id)
             WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
               AND e.created_at >= (SELECT gap_start FROM win) - make_interval(days => (SELECT n FROM nd))
               AND e.created_at <  (SELECT gap_start FROM win)
               AND s.created_at <  (SELECT gap_start FROM win) - make_interval(days => (SELECT n FROM nd))),
           (SELECT max(n_activos - n_nuevos) FROM gap_day)
         ) AS k
)
SELECT r.*
FROM recur r
JOIN session s ON s.session_id = r.session_id
ORDER BY r.peso_sel DESC, r.session_id
LIMIT (SELECT k FROM k);

\echo '>>> Nucleo de visitantes recurrentes:'
SELECT count(*) AS nucleo, round(min(peso_sel),3) AS retorno_min,
       round(max(peso_sel),3) AS retorno_max FROM core;

-- 7b. roster del dia = nuevas de ese dia + recurrentes muestreadas por
--     peso_sel sin reemplazo (Efraimidis-Spirakis)
CREATE TEMP TABLE roster AS
WITH cand AS (
  -- nucleo real anterior al hueco
  SELECT g.d, r.session_id, r.peso_sel, r.peso_int
  FROM gap_day g JOIN core r ON true
  WHERE NOT g.dia_borde
  UNION ALL
  -- sinteticas nacidas en dias anteriores del hueco
  SELECT g.d, ns.session_id, ns.peso_sel, ns.peso_int
  FROM gap_day g JOIN new_sess ns ON ns.d < g.d
  WHERE NOT g.dia_borde
  UNION ALL
  -- dias de borde: solo sesiones que ese mismo dia real ya estaban activas
  SELECT g.d, x.session_id, 1.0, x.peso_int
  FROM gap_day g
  JOIN LATERAL (
    SELECT e.session_id, GREATEST(0.25, count(DISTINCT e.visit_id)::numeric) AS peso_int
    FROM website_event e
    WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
      AND (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = g.d
      AND EXISTS (SELECT 1 FROM session s WHERE s.session_id = e.session_id)
    GROUP BY 1
  ) x ON true
  WHERE g.dia_borde
),
ranked AS (
  SELECT c.d, c.session_id, c.peso_int,
         row_number() OVER (
           PARTITION BY c.d
           ORDER BY pow(pg_temp.rnd('ret|' || c.d || '|' || c.session_id), 1.0 / c.peso_sel) DESC,
                    c.session_id) AS rn
  FROM cand c
)
SELECT r.d, r.session_id, r.peso_int AS peso, false AS es_nueva
FROM ranked r JOIN gap_day g USING (d)
WHERE r.rn <= g.n_activos - g.n_nuevos
UNION ALL
SELECT ns.d, ns.session_id, ns.peso_int, true
FROM new_sess ns;

\echo '>>> Roster armado (visitantes por dia):'
SELECT d, count(*) AS roster, count(*) FILTER (WHERE es_nueva) AS nuevas FROM roster GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 8. ASIGNACION DE SLOTS A VISITANTES Y GENERACION DE EVENTOS
--    Se garantiza >= 1 visita por visitante y el resto se reparte con
--    peso, para conservar la cola larga de usuarios intensivos.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE slot_num AS
SELECT s.*, row_number() OVER (PARTITION BY s.d ORDER BY pg_temp.rnd('spread|' || s.d || '|' || s.h || '|' || s.slot_no)) AS spread_rn
FROM gap_slot s;

CREATE TEMP TABLE assign AS
-- 8a. una visita garantizada por visitante, repartida a lo largo del dia
WITH r AS (
  SELECT d, session_id, peso,
         row_number() OVER (PARTITION BY d ORDER BY pg_temp.rnd('shuf|' || d || '|' || session_id)) AS rn
  FROM roster
),
seed_assign AS (
  SELECT s.d, s.h, s.slot_no, r.session_id
  FROM slot_num s JOIN r ON r.d = s.d AND r.rn = s.spread_rn
),
-- 8b. resto de slots: dentro de una misma hora se reparten entre visitantes
--     DISTINTOS. Si dos slots de la misma sesion cayeran en la misma hora,
--     el reagrupado de 30 min (8c-bis) los fusionaria y las visitas por
--     visitante quedarian por debajo de lo observado.
rest_slots AS (
  SELECT s.d, s.h, s.slot_no,
         row_number() OVER (PARTITION BY s.d, s.h ORDER BY s.slot_no) AS k
  FROM gap_slot s
  LEFT JOIN seed_assign a ON a.d = s.d AND a.h = s.h AND a.slot_no = s.slot_no
  WHERE a.session_id IS NULL
),
avail AS (   -- roster del dia menos quien ya tiene un slot en esa hora
  SELECT hh.d, hh.h, ro.session_id, ro.peso
  FROM (SELECT DISTINCT d, h FROM gap_slot) hh
  JOIN roster ro ON ro.d = hh.d
  LEFT JOIN seed_assign sa ON sa.d = hh.d AND sa.h = hh.h AND sa.session_id = ro.session_id
  WHERE sa.session_id IS NULL
),
ranked AS (
  SELECT a.d, a.h, a.session_id,
         row_number() OVER (PARTITION BY a.d, a.h
           ORDER BY pow(pg_temp.rnd('hs|' || a.d || '|' || a.h || '|' || a.session_id), 1.0 / a.peso) DESC,
                    a.session_id) AS rn,
         count(*) OVER (PARTITION BY a.d, a.h) AS navail
  FROM avail a
),
rest_assign AS (
  SELECT rs.d, rs.h, rs.slot_no, rk.session_id
  FROM rest_slots rs
  JOIN ranked rk ON rk.d = rs.d AND rk.h = rs.h
                AND rk.rn = ((rs.k - 1) % rk.navail) + 1
)
SELECT * FROM seed_assign UNION ALL SELECT * FROM rest_assign;

-- 8c. eventos: se copia el recorrido real de la visita fuente, desplazado
CREATE TEMP TABLE gen_event AS
WITH src AS (
  SELECT e.visit_id, e.event_id, e.created_at,
         min(e.created_at) OVER (PARTITION BY e.visit_id) AS v_start,
         row_number() OVER (PARTITION BY e.visit_id ORDER BY e.created_at, e.event_id) AS seq,
         e.url_path, e.url_query, e.referrer_path, e.referrer_query, e.referrer_domain,
         e.page_title, e.event_type, e.event_name, e.hostname,
         e.utm_source, e.utm_medium, e.utm_campaign, e.utm_content, e.utm_term,
         e.gclid, e.fbclid, e.msclkid, e.ttclid, e.li_fat_id, e.twclid,
         e.lcp, e.inp, e.cls, e.fcp, e.ttfb
  FROM website_event e
  WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag IS NULL
    AND e.visit_id IN (SELECT src_visit FROM gap_slot)
)
SELECT pg_temp.duuid('ev|' || g.d || '|' || g.h || '|' || g.slot_no || '|' || s.seq) AS event_id,
       (SELECT website_id FROM cfg)                       AS website_id,
       a.session_id,
       g.visit_id,
       g.slot_start + (s.created_at - s.v_start)          AS created_at,
       s.url_path, s.url_query, s.referrer_path, s.referrer_query, s.referrer_domain,
       s.page_title, s.event_type, s.event_name, s.hostname,
       s.utm_source, s.utm_medium, s.utm_campaign, s.utm_content, s.utm_term,
       s.gclid, s.fbclid, s.msclkid, s.ttclid, s.li_fat_id, s.twclid,
       s.lcp, s.inp, s.cls, s.fcp, s.ttfb,
       (SELECT tag FROM cfg)                              AS tag
FROM gap_slot g
JOIN assign a ON a.d = g.d AND a.h = g.h AND a.slot_no = g.slot_no
JOIN src    s ON s.visit_id = g.src_visit AND s.seq <= g.keep_events
CROSS JOIN win w
WHERE g.slot_start + (s.created_at - s.v_start) >  w.gap_start
  AND g.slot_start + (s.created_at - s.v_start) <  w.gap_end;

-- 8c-bis. Umami considera "una visita" los eventos de una sesion separados
-- por menos de 30 min. Se recalcula visit_id con esa misma regla: fusiona
-- recorridos contiguos y garantiza que un visitante no tenga dos visitas
-- simultaneas (lo que ocurre cuando dos slots de la misma sesion se cruzan).
ALTER TABLE gen_event ADD COLUMN vno int;

UPDATE gen_event ge SET vno = g.vno
FROM (
  SELECT event_id,
         sum(nv) OVER (PARTITION BY session_id ORDER BY created_at, event_id) AS vno
  FROM (
    SELECT event_id, session_id, created_at,
           CASE WHEN lag(created_at) OVER (PARTITION BY session_id ORDER BY created_at, event_id) IS NULL
                  OR created_at - lag(created_at) OVER (PARTITION BY session_id ORDER BY created_at, event_id)
                     > interval '30 minutes'
                THEN 1 ELSE 0 END AS nv
    FROM gen_event
  ) f
) g
WHERE g.event_id = ge.event_id;

UPDATE gen_event
   SET visit_id = pg_temp.duuid('visit2|' || session_id || '|' || vno);

-- 8d. insertar sesiones nuevas (created_at = su primer evento generado)
INSERT INTO session (session_id, website_id, browser, os, device, screen,
                     language, country, region, city, created_at, distinct_id)
SELECT ns.session_id, (SELECT website_id FROM cfg), ns.browser, ns.os, ns.device,
       ns.screen, ns.language, ns.country, ns.region, ns.city,
       min(ge.created_at), NULL
FROM new_sess ns
JOIN gen_event ge ON ge.session_id = ns.session_id
GROUP BY 1, 3, 4, 5, 6, 7, 8, 9, 10;

-- 8e. insertar eventos
INSERT INTO website_event (
  event_id, website_id, session_id, visit_id, created_at,
  url_path, url_query, referrer_path, referrer_query, referrer_domain,
  page_title, event_type, event_name, hostname,
  utm_source, utm_medium, utm_campaign, utm_content, utm_term,
  gclid, fbclid, msclkid, ttclid, li_fat_id, twclid,
  lcp, inp, cls, fcp, ttfb, tag)
SELECT event_id, website_id, session_id, visit_id, created_at,
       url_path, url_query, referrer_path, referrer_query, referrer_domain,
       page_title, event_type, event_name, hostname,
       utm_source, utm_medium, utm_campaign, utm_content, utm_term,
       gclid, fbclid, msclkid, ttclid, li_fat_id, twclid,
       lcp, inp, cls, fcp, ttfb, tag
FROM gen_event;

-- ---------------------------------------------------------------------
-- 9. VERIFICACION
-- ---------------------------------------------------------------------
\echo '>>> Insertado: objetivo vs real, por dia'
SELECT g.d, to_char(g.d, 'Dy') AS dow,
       sum(g.target_views) AS objetivo,
       (SELECT count(*) FROM website_event e
         WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag = (SELECT tag FROM cfg)
           AND (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = g.d) AS insertado,
       (SELECT count(DISTINCT e.session_id) FROM website_event e
         WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag = (SELECT tag FROM cfg)
           AND (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = g.d) AS visitantes,
       (SELECT count(DISTINCT e.visit_id) FROM website_event e
         WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag = (SELECT tag FROM cfg)
           AND (e.created_at AT TIME ZONE (SELECT tz FROM cfg))::date = g.d) AS visitas
FROM gap_hour g GROUP BY 1, 2 ORDER BY 1;

\echo '>>> Serie diaria completa (real + reconstruido)'
SELECT (created_at AT TIME ZONE (SELECT tz FROM cfg))::date AS d,
       to_char((created_at AT TIME ZONE (SELECT tz FROM cfg))::date, 'Dy') AS dow,
       count(*) FILTER (WHERE tag IS NULL) AS real,
       count(*) FILTER (WHERE tag IS NOT NULL) AS reconstruido,
       count(DISTINCT session_id) AS visitantes
FROM website_event WHERE website_id = (SELECT website_id FROM cfg)
GROUP BY 1, 2 ORDER BY 1;

\echo '>>> Top paginas: real vs reconstruido (share %)'
WITH r AS (
  SELECT url_path, count(*) FILTER (WHERE tag IS NULL) nreal,
         count(*) FILTER (WHERE tag IS NOT NULL) nrec
  FROM website_event WHERE website_id = (SELECT website_id FROM cfg) GROUP BY 1)
SELECT url_path,
       round(nreal * 100.0 / NULLIF(sum(nreal) OVER (), 0), 2) AS real_pct,
       round(nrec  * 100.0 / NULLIF(sum(nrec)  OVER (), 0), 2) AS recon_pct
FROM r ORDER BY nreal DESC LIMIT 12;

\echo '>>> Fidelidad de metricas derivadas (real vs reconstruido)'
WITH vv AS (
  SELECT visit_id, count(*) AS ev, max(created_at) - min(created_at) AS dur,
         bool_or(tag IS NOT NULL) AS rec
  FROM website_event WHERE website_id = (SELECT website_id FROM cfg) GROUP BY 1)
SELECT CASE WHEN rec THEN 'reconstruido' ELSE 'real' END AS fuente,
       count(*) AS visitas,
       round(avg(ev), 2) AS paginas_x_visita,
       round(avg(extract(epoch FROM dur))) AS duracion_media_s,
       round(count(*) FILTER (WHERE ev = 1) * 100.0 / count(*), 1) AS rebote_pct
FROM vv GROUP BY 1;

\echo '>>> Visitas simultaneas de un mismo visitante (debe ser 0)'
WITH vv AS (
  SELECT session_id, visit_id, min(created_at) AS st, max(created_at) AS en
  FROM website_event
  WHERE website_id = (SELECT website_id FROM cfg) AND tag = (SELECT tag FROM cfg)
  GROUP BY 1, 2)
SELECT count(*) AS solapes FROM vv a JOIN vv b
  ON a.session_id = b.session_id AND a.visit_id < b.visit_id
 AND a.st < b.en AND b.st < a.en;

\echo '>>> Integridad: eventos sin sesion / sesiones sin eventos'
SELECT (SELECT count(*) FROM website_event e
         WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag = (SELECT tag FROM cfg)
           AND NOT EXISTS (SELECT 1 FROM session s WHERE s.session_id = e.session_id)) AS eventos_huerfanos,
       (SELECT count(*) FROM session s
         WHERE s.website_id = (SELECT website_id FROM cfg)
           AND s.created_at > (SELECT gap_start FROM win) AND s.created_at < (SELECT gap_end FROM win)
           AND NOT EXISTS (SELECT 1 FROM website_event e WHERE e.session_id = s.session_id)) AS sesiones_vacias,
       (SELECT count(*) FROM website_event e
         WHERE e.website_id = (SELECT website_id FROM cfg) AND e.tag = (SELECT tag FROM cfg)
           AND (e.created_at <= (SELECT gap_start FROM win) OR e.created_at >= (SELECT gap_end FROM win))) AS fuera_de_rango;

COMMIT;

-- =====================================================================
-- DESHACER (rollback de datos)
-- =====================================================================
--   BEGIN;
--   DELETE FROM website_event
--    WHERE website_id = '946007d8-2564-4ef1-b3df-53540a887eef'
--      AND tag = 'recon-2026-08';
--   DELETE FROM session s
--    WHERE s.website_id = '946007d8-2564-4ef1-b3df-53540a887eef'
--      AND s.created_at > '2026-08-20 17:24:50+00'
--      AND s.created_at < '2026-08-31 16:12:47+00';
--   COMMIT;
-- =====================================================================
