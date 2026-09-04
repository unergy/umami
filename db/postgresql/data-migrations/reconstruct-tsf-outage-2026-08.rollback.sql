-- =====================================================================
-- Deshacer reconstruct-tsf-outage-2026-08.sql
-- Borra SOLO lo generado: los eventos marcados con el tag y las sesiones
-- creadas dentro de la ventana de la caida (ninguna sesion real nacio ahi).
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE cfg AS
SELECT '946007d8-2564-4ef1-b3df-53540a887eef'::uuid AS website_id,
       'recon-2026-08'::text                        AS tag,
       '2026-08-25'::date                           AS probe;

-- bordes de la caida: se recalculan ignorando lo reconstruido
CREATE TEMP TABLE win AS
SELECT (SELECT max(created_at) FROM website_event
         WHERE website_id = c.website_id AND tag IS NULL AND created_at < c.probe) AS gap_start,
       (SELECT min(created_at) FROM website_event
         WHERE website_id = c.website_id AND tag IS NULL AND created_at > c.probe) AS gap_end
FROM cfg c;

DELETE FROM website_event
 WHERE website_id = (SELECT website_id FROM cfg)
   AND tag = (SELECT tag FROM cfg);

DELETE FROM session
 WHERE website_id = (SELECT website_id FROM cfg)
   AND created_at > (SELECT gap_start FROM win)
   AND created_at < (SELECT gap_end FROM win);

\echo '>>> Estado tras el rollback (debe quedar el hueco vacio):'
SELECT (created_at AT TIME ZONE 'America/Bogota')::date AS d, count(*) AS eventos
FROM website_event
WHERE website_id = (SELECT website_id FROM cfg)
  AND created_at BETWEEN (SELECT gap_start FROM win) - interval '2 days'
                     AND (SELECT gap_end FROM win)   + interval '2 days'
GROUP BY 1 ORDER BY 1;

SELECT count(*) AS eventos_con_tag FROM website_event
 WHERE website_id = (SELECT website_id FROM cfg) AND tag = (SELECT tag FROM cfg);

COMMIT;
