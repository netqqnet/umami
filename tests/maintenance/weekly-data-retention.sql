\set ON_ERROR_STOP on
DO $$
BEGIN
  IF current_database() NOT LIKE '%_test' OR EXISTS (SELECT 1 FROM public.website_event) THEN
    RAISE EXCEPTION 'Run only in an empty disposable *_test database';
  END IF;
END;
$$;

INSERT INTO public.website (website_id, name)
VALUES ('00000000-0000-4000-8000-000000000001', 'weekly retention test');
INSERT INTO public.session (session_id, website_id, created_at)
VALUES ('00000000-0000-4000-8000-000000000002',
  '00000000-0000-4000-8000-000000000001', now() - interval '181 days');
INSERT INTO public.website_event (event_id, website_id, session_id, visit_id, url_path, created_at)
SELECT gen_random_uuid(), '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000002', gen_random_uuid(), '/',
  CASE WHEN n = 20006 THEN now() ELSE now() - interval '181 days' END
FROM generate_series(1, 20006) n;

-- Top-level CALL proves transaction control works across more than two batches.
CALL umami_maintenance.prune_analytics_weekly();
CALL umami_maintenance.prune_analytics_weekly();
DO $$
BEGIN
  IF (SELECT count(*) FROM public.website_event) <> 1
    OR (SELECT count(*) FROM public.session) <> 1
    OR EXISTS (SELECT 1 FROM umami_maintenance.expired_events) THEN
    RAISE EXCEPTION 'Weekly cleanup failed to drain backlog or preserve active session';
  END IF;
  IF has_function_privilege('public',
      'umami_maintenance.prune_analytics_weekly()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Weekly procedure is publicly executable';
  END IF;
END;
$$;
