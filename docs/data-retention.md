# Analytics data retention

The maintenance SQL implements a rolling 180-day retention policy for a self-hosted
Umami v3.4.1 database in the `public` schema. It does not change Vercel build commands
or run during application installation, builds, or upstream database migrations.

## What is removed

- Website events older than 180 days, with their event properties.
- Replay chunks whose end time is older than 180 days, and old heatmap events.
- Old sessions with no remaining events, replays, heatmaps, revenue, or recent
  identity properties/links; their session properties and identity links are removed together.

Saved replay visits and their associated events/heatmaps are protected. Revenue records
and the events they reference are retained. Accounts, websites, teams, shares, annotations,
segments, reports, links and pixels are untouched. Records with unknown event timestamps
are retained for review. Repeat page visits are not treated as duplicates.

## Install and preview

Verify the target database connection and finish the official v3.4.1 migrations first.
Keep a verified backup outside Git before the first cleanup. Load
`scripts/maintenance/data-retention.sql` as the database maintenance owner. Installation
creates only private views and a function; it does not delete analytics.

```sql
SELECT umami_maintenance.prune_analytics();
```

The default is a read-only preview. It returns the cutoff and eligible row counts.
The session count includes only sessions that are already unreferenced; more can become
eligible as event/replay batches complete. Preview again after the initial backlog clears.

The function is `SECURITY INVOKER`, has no `PUBLIC` access, and is not exposed through
an application endpoint. Run it with the dedicated database maintenance owner.

## First cleanup

After reviewing the preview and approving removal of old history:

```sql
SET statement_timeout = '30s';
SELECT umami_maintenance.prune_analytics(false);
```

Each call handles at most 10,000 rows per parent table. It returns actual deletion counts
including dependent properties. Calls are atomic; an error rolls the call back. Concurrent
cleanup calls are skipped using a transaction advisory lock, and busy rows are skipped.
Repeat individual calls in autocommit mode until all counts are zero. Do not wrap the backlog
in a single `DO` block or long transaction. Keep the backup until live statistics and shares
have been checked. This removes old detail; it does not create historical aggregate reports.

Deleting rows does not immediately shrink PostgreSQL files. Normal autovacuum makes the
space reusable. If the existing database must return below a storage quota, separately plan
a one-time file compaction or restore into a new database. `VACUUM FULL` requires additional
free disk and an exclusive lock; it is deliberately not part of the daily job.

## Daily schedule

Enable the Supabase Cron (`pg_cron`) extension in the verified target, then load
`scripts/maintenance/schedule-data-retention.sql` after the first cleanup is approved.
It schedules cleanup at 19:17 GMT (03:17 Asia/Shanghai). A second daily job keeps only
30 days of history for these two maintenance jobs, leaving other jobs' history alone.
Reapplying the schedule updates the same job names rather than adding duplicate jobs.

```sql
SELECT jobname, schedule, active FROM cron.job
WHERE jobname IN ('umami-data-retention', 'umami-retention-log-cleanup');

SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname = 'umami-data-retention')
ORDER BY start_time DESC LIMIT 10;
```

Use the Cron dashboard to pause the two jobs without removing the maintenance function.
For PostgreSQL hosts without `pg_cron`, schedule the same function through the host's scheduler.

## Verification

`tests/maintenance/data-retention.sql` runs only in an empty disposable `*_test` database
with all official migrations and the maintenance SQL installed. It rolls fixtures back and
checks dry runs, exact cutoff/null timestamps, active sessions, protected data, dependent
row deletion, repeat runs, the 10,000-row batch limit, and function permissions.

On the verified backup copy, 24 batches removed 236,435 old events and 13,382 unreferenced
sessions. Accounts, websites, shares and configuration counts stayed unchanged. File
compaction of that isolated copy produced a database of approximately 338 MiB. These are
snapshot measurements; refresh the preview before any production cleanup.

References: [Supabase Cron](https://supabase.com/docs/guides/cron/quickstart),
[PostgreSQL vacuuming](https://www.postgresql.org/docs/current/routine-vacuuming.html).
