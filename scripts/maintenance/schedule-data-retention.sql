-- Enable only after reviewing the dry run, backing up, and approving the first cleanup.
-- Run as the database maintenance owner; pg_cron must already be enabled.
-- CALL must be top-level: each batch commits before the next batch begins.
CREATE OR REPLACE PROCEDURE umami_maintenance.prune_analytics_weekly()
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  result jsonb;
  batch integer;
BEGIN
  FOR batch IN 1..100 LOOP
    result := umami_maintenance.prune_analytics(false);
    COMMIT;
    IF coalesce((result->>'skipped')::boolean, false) OR NOT EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_each_text(result) AS item(key, value)
      WHERE key IN ('website_event', 'session', 'session_replay', 'heatmap_event')
        AND value::bigint > 0
    ) THEN
      RETURN;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'Retention batch limit reached; inspect remaining backlog';
END;
$$;
REVOKE ALL ON PROCEDURE umami_maintenance.prune_analytics_weekly() FROM PUBLIC;

SELECT cron.schedule(
  'umami-data-retention',
  '17 19 * * 6', -- Sunday 03:17 Asia/Shanghai; Saturday GMT on Supabase.
  $$CALL umami_maintenance.prune_analytics_weekly();$$
);

-- Job history also needs a bound; scope it to this job only.
SELECT cron.schedule(
  'umami-retention-log-cleanup',
  '47 19 * * 6',
  $$DELETE FROM cron.job_run_details
    WHERE end_time < now() - interval '30 days'
      AND jobid IN (
        SELECT jobid FROM cron.job
        WHERE jobname IN ('umami-data-retention', 'umami-retention-log-cleanup')
      );$$
);
