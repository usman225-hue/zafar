-- EPAS v3.2 managed scheduler. Run after production_v3_2_final_performance_security_ux.sql.
-- Configure this in Supabase SQL editor / Cron extension with service_role execution.
select cron.unschedule(jobid)
from cron.job
where jobname = 'epas-survey-lifecycle-v32';

select cron.schedule(
  'epas-survey-lifecycle-v32',
  '*/15 * * * *',
  $$select public.epas_scheduler_tick_v32();$$
);
