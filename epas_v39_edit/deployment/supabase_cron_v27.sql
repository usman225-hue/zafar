-- Run once in the target Supabase project after pg_cron is enabled.
-- The job runs as the database scheduler/service context; do not grant this
-- function to normal authenticated users.

select cron.unschedule(jobid)
from cron.job
where jobname = 'epas-survey-lifecycle-v27';

select cron.schedule(
  'epas-survey-lifecycle-v27',
  '5 * * * *',
  'select public.epas_scheduler_tick_v27();'
);
