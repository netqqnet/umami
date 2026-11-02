-- Enable only after reviewing the dry run, backing up, and approving the first cleanup.
-- Run as the database maintenance owner; pg_cron must already be enabled.
SELECT cron.schedule(
  'umami-data-retention',
  '17 19 * * *', -- 03:17 Asia/Shanghai; pg_cron uses GMT on Supabase.
  $$SET statement_timeout = '30s'; SELECT umami_maintenance.prune_analytics(false);$$
);

-- Job history also needs a bound; scope it to this job only.
SELECT cron.schedule(
  'umami-retention-log-cleanup',
  '47 19 * * *',
  $$DELETE FROM cron.job_run_details
    WHERE end_time < now() - interval '30 days'
      AND jobid IN (
        SELECT jobid FROM cron.job
        WHERE jobname IN ('umami-data-retention', 'umami-retention-log-cleanup')
      );$$
);
