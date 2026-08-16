-- EPAS v2.8 production scheduler deployment.
-- Run against the Supabase SQL editor with pg_cron available.
-- This does NOT expose the service-role secret to Streamlit.

create extension if not exists pg_cron;

select cron.unschedule(jobid)
from cron.job
where jobname='epas-survey-lifecycle-v27';

select cron.unschedule(jobid)
from cron.job
where jobname='epas-survey-lifecycle-v28';

select cron.schedule(
  'epas-survey-lifecycle-v28',
  '*/15 * * * *',
  $$select public.epas_scheduler_tick_v28();$$
);

-- Recommended operational checks:
-- select jobid,jobname,schedule,active from cron.job where jobname='epas-survey-lifecycle-v28';
-- select * from public.scheduler_runs order by started_at desc limit 20;
