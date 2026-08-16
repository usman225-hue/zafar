-- EPAS v3.1 production scheduler. Execute once on the deployed Supabase project.
-- Requires pg_cron and the v3.1 migration to be applied first.
select cron.unschedule('epas-v29-lifecycle-tick') where exists (select 1 from cron.job where jobname='epas-v29-lifecycle-tick');
select cron.unschedule('epas-v30-lifecycle-tick') where exists (select 1 from cron.job where jobname='epas-v30-lifecycle-tick');
select cron.unschedule('epas-v31-lifecycle-tick') where exists (select 1 from cron.job where jobname='epas-v31-lifecycle-tick');
select cron.schedule(
  'epas-v31-lifecycle-tick',
  '*/15 * * * *',
  $$select public.epas_scheduler_tick_v31();$$
);
