-- EPAS v3.0 production scheduler.
-- Requires pg_cron to be enabled in Supabase.
-- Run once in the target database after production_v3_0_final_release_hardening.sql.

create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname='epas-v30-lifecycle-15min';
exception when undefined_table then
  null;
end$$;

select cron.schedule(
  'epas-v30-lifecycle-15min',
  '*/15 * * * *',
  $$select public.epas_scheduler_tick_v29();$$
);
