\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF current_database() NOT LIKE '%_test' OR EXISTS (SELECT 1 FROM public.website_event) THEN
    RAISE EXCEPTION 'Run only in an empty disposable *_test database';
  END IF;
END;
$$;

INSERT INTO public.website (website_id, name)
VALUES ('00000000-0000-4000-8000-000000000001', 'retention test');
INSERT INTO public.session (session_id, website_id, created_at)
SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  '00000000-0000-4000-8000-000000000001', now() - interval '181 days'
FROM generate_series(10, 16) n;

-- Expired, recent, exact cutoff, unknown timestamp, saved replay, revenue, old-but-active session.
INSERT INTO public.website_event (event_id, website_id, session_id, visit_id, url_path, created_at)
SELECT ('00000000-0000-4000-8000-' || lpad((n+100)::text, 12, '0'))::uuid,
  '00000000-0000-4000-8000-000000000001',
  ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  ('00000000-0000-4000-8000-' || lpad((n+200)::text, 12, '0'))::uuid, '/',
  CASE WHEN n IN (11,16) THEN now() - interval '1 day'
       WHEN n=12 THEN now() - interval '180 days'
       WHEN n=13 THEN NULL ELSE now() - interval '181 days' END
FROM generate_series(10,16) n;
INSERT INTO public.event_data (event_data_id, website_id, website_event_id, data_key, data_type)
VALUES ('00000000-0000-4000-8000-000000000300', '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000110', 'test', 1);
INSERT INTO public.session_data (session_data_id, website_id, session_id, data_key, data_type, created_at)
VALUES ('00000000-0000-4000-8000-000000000301', '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000010', 'test', 1, now() - interval '181 days');
INSERT INTO public.session_link (website_id, session_id, distinct_id, created_at)
VALUES ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000010',
  'test', now() - interval '181 days');
INSERT INTO public.session_replay_saved (saved_replay_id, website_id, visit_id, name)
VALUES ('00000000-0000-4000-8000-000000000302', '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000214', 'saved');
INSERT INTO public.session_replay (replay_id, website_id, session_id, visit_id, chunk_index, events,
  event_count, started_at, ended_at)
SELECT ('00000000-0000-4000-8000-' || lpad((n+400)::text,12,'0'))::uuid,
  '00000000-0000-4000-8000-000000000001',
  ('00000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
  ('00000000-0000-4000-8000-' || lpad((n+200)::text,12,'0'))::uuid,
  0, '\x00'::bytea, 1, now()-interval '182 days', now()-interval '181 days'
FROM unnest(ARRAY[10,14]) n;
INSERT INTO public.heatmap_event (heatmap_event_id, website_id, session_id, visit_id, url_path,
  event_type, created_at)
SELECT ('00000000-0000-4000-8000-' || lpad((n+500)::text,12,'0'))::uuid,
  '00000000-0000-4000-8000-000000000001',
  ('00000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
  ('00000000-0000-4000-8000-' || lpad((n+200)::text,12,'0'))::uuid,
  '/', 1, now()-interval '181 days'
FROM unnest(ARRAY[10,14]) n;
INSERT INTO public.revenue (revenue_id, website_id, session_id, event_id, event_name, currency, revenue)
VALUES ('00000000-0000-4000-8000-000000000303', '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000015', '00000000-0000-4000-8000-000000000115', 'sale','CNY',1);

DO $$
DECLARE report jsonb;
BEGIN
  report := umami_maintenance.prune_analytics();
  ASSERT (report->>'website_event')::int = 1, 'Preview must exclude protected and cutoff events';
  ASSERT (SELECT count(*) FROM public.website_event)=7, 'Preview changed data';
  report := umami_maintenance.prune_analytics(false);
  ASSERT (report->>'website_event')::int=1 AND (report->>'session')::int=1;
  ASSERT (report->>'event_data')::int=1 AND (report->>'session_data')::int=1;
  ASSERT (report->>'session_link')::int=1;
  ASSERT (SELECT count(*) FROM public.website_event)=6, 'Recent or protected event was deleted';
  ASSERT (SELECT count(*) FROM public.session_replay)=1, 'Saved replay was deleted';
  ASSERT (SELECT count(*) FROM public.heatmap_event)=1;
  ASSERT (SELECT count(*) FROM public.session_replay_saved)=1;
  ASSERT (SELECT count(*) FROM public.revenue)=1;
  ASSERT (SELECT count(*) FROM public.website)=1;
  ASSERT (SELECT count(*) FROM public.session)=6, 'Active or protected session was deleted';
  report := umami_maintenance.prune_analytics(false);
  ASSERT (report->>'website_event')::int=0 AND (report->>'session')::int=0, 'Cleanup is not idempotent';
  ASSERT NOT EXISTS (
    SELECT 1 FROM pg_proc p, LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    WHERE p.oid='umami_maintenance.prune_analytics(boolean)'::regprocedure
      AND a.grantee=0 AND a.privilege_type='EXECUTE'
  ), 'PUBLIC can execute cleanup';
END;
$$;

INSERT INTO public.website_event (event_id, website_id, session_id, visit_id, url_path, created_at)
SELECT gen_random_uuid(), '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000016', gen_random_uuid(), '/', now()-interval '181 days'
FROM generate_series(1,10001);
DO $$
DECLARE report jsonb;
BEGIN
  report := umami_maintenance.prune_analytics(false);
  ASSERT (report->>'website_event')::int=10000, 'Batch exceeded or missed its bound';
  report := umami_maintenance.prune_analytics(false);
  ASSERT (report->>'website_event')::int=1, 'Next batch did not resume';
  ASSERT (SELECT count(*) FROM public.website_event)=6, 'Protected events were lost';
END;
$$;
ROLLBACK;
