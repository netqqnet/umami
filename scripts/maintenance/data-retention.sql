-- Install after the official v3.4.1 migrations. Installation does not delete data.
BEGIN;
CREATE SCHEMA IF NOT EXISTS umami_maintenance;
REVOKE ALL ON SCHEMA umami_maintenance FROM PUBLIC;

CREATE OR REPLACE VIEW umami_maintenance.expired_events
WITH (security_invoker = true) AS
SELECT e.event_id AS id, e.created_at AS expired_at
FROM public.website_event e
WHERE e.created_at < now() - interval '180 days'
  AND NOT EXISTS (
    SELECT 1 FROM public.session_replay_saved s
    WHERE s.website_id = e.website_id AND s.visit_id = e.visit_id
  )
  AND NOT EXISTS (SELECT 1 FROM public.revenue r WHERE r.event_id = e.event_id);

CREATE OR REPLACE VIEW umami_maintenance.expired_replays
WITH (security_invoker = true) AS
SELECT r.replay_id AS id, r.ended_at AS expired_at
FROM public.session_replay r
WHERE r.ended_at < now() - interval '180 days'
  AND NOT EXISTS (
    SELECT 1 FROM public.session_replay_saved s
    WHERE s.website_id = r.website_id AND s.visit_id = r.visit_id
  );

CREATE OR REPLACE VIEW umami_maintenance.expired_heatmaps
WITH (security_invoker = true) AS
SELECT h.heatmap_event_id AS id, h.created_at AS expired_at
FROM public.heatmap_event h
WHERE h.created_at < now() - interval '180 days'
  AND NOT EXISTS (
    SELECT 1 FROM public.session_replay_saved s
    WHERE s.website_id = h.website_id AND s.visit_id = h.visit_id
  );

CREATE OR REPLACE VIEW umami_maintenance.expired_sessions
WITH (security_invoker = true) AS
SELECT s.session_id AS id, s.created_at AS expired_at
FROM public.session s
WHERE s.created_at < now() - interval '180 days'
  AND NOT EXISTS (SELECT 1 FROM public.website_event e WHERE e.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM public.session_replay r WHERE r.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM public.heatmap_event h WHERE h.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM public.revenue r WHERE r.session_id = s.session_id)
  AND NOT EXISTS (
    SELECT 1 FROM public.session_data d
    WHERE d.session_id = s.session_id AND d.created_at >= now() - interval '180 days'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.session_link l
    WHERE l.session_id = s.session_id AND l.created_at >= now() - interval '180 days'
  );

CREATE OR REPLACE FUNCTION umami_maintenance.prune_analytics(dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
SET lock_timeout = '2s'
AS $$
DECLARE
  target record;
  ids uuid[];
  affected bigint;
  result jsonb := jsonb_build_object(
    'dry_run', dry_run, 'cutoff', now() - interval '180 days',
    'event_data', 0, 'session_data', 0, 'session_link', 0
  );
BEGIN
  IF dry_run IS NULL THEN
    RAISE EXCEPTION 'dry_run must be true or false';
  END IF;
  IF NOT dry_run AND NOT pg_try_advisory_xact_lock(hashtextextended('umami-data-retention', 0)) THEN
    RETURN result || jsonb_build_object('skipped', true);
  END IF;

  FOR target IN SELECT * FROM (VALUES
    ('session_replay', 'replay_id', 'expired_replays'),
    ('heatmap_event', 'heatmap_event_id', 'expired_heatmaps'),
    ('website_event', 'event_id', 'expired_events'),
    ('session', 'session_id', 'expired_sessions')
  ) AS targets(table_name, id_column, view_name)
  LOOP
    IF dry_run THEN
      IF target.table_name = 'website_event' THEN
        SELECT count(*) INTO affected FROM public.event_data d
        JOIN umami_maintenance.expired_events e ON e.id = d.website_event_id;
        result := result || jsonb_build_object('event_data', affected);
      ELSIF target.table_name = 'session' THEN
        SELECT count(*) INTO affected FROM public.session_data d
        JOIN umami_maintenance.expired_sessions s ON s.id = d.session_id;
        result := result || jsonb_build_object('session_data', affected);
        SELECT count(*) INTO affected FROM public.session_link l
        JOIN umami_maintenance.expired_sessions s ON s.id = l.session_id;
        result := result || jsonb_build_object('session_link', affected);
      END IF;
      EXECUTE format('SELECT count(*) FROM umami_maintenance.%I', target.view_name) INTO affected;
    ELSE
      EXECUTE format(
        'SELECT coalesce(array_agg(batch.id), ARRAY[]::uuid[]) FROM (
          SELECT t.%I AS id FROM public.%I t
          JOIN umami_maintenance.%I v ON v.id = t.%I
          ORDER BY v.expired_at, t.%I LIMIT 10000 FOR UPDATE OF t SKIP LOCKED
        ) batch',
        target.id_column, target.table_name, target.view_name, target.id_column, target.id_column
      ) INTO ids;
      IF target.table_name = 'website_event' THEN
        DELETE FROM public.event_data WHERE website_event_id = ANY(ids);
        GET DIAGNOSTICS affected = ROW_COUNT;
        result := result || jsonb_build_object('event_data', affected);
      ELSIF target.table_name = 'session' THEN
        DELETE FROM public.session_data WHERE session_id = ANY(ids);
        GET DIAGNOSTICS affected = ROW_COUNT;
        result := result || jsonb_build_object('session_data', affected);
        DELETE FROM public.session_link WHERE session_id = ANY(ids);
        GET DIAGNOSTICS affected = ROW_COUNT;
        result := result || jsonb_build_object('session_link', affected);
      END IF;
      EXECUTE format('DELETE FROM public.%I WHERE %I = ANY($1)', target.table_name, target.id_column)
        USING ids;
      GET DIAGNOSTICS affected = ROW_COUNT;
    END IF;
    result := result || jsonb_build_object(target.table_name, affected);
  END LOOP;
  RETURN result;
END;
$$;
REVOKE ALL ON ALL TABLES IN SCHEMA umami_maintenance FROM PUBLIC;
REVOKE ALL ON FUNCTION umami_maintenance.prune_analytics(boolean) FROM PUBLIC;
COMMIT;
