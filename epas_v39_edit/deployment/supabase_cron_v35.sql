-- Install in Supabase SQL editor after production_v3_5_final_role_ux_scheduler.sql.
-- Requires pg_cron available in the deployed project.
create extension if not exists pg_cron;
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname='epas_v35_scheduler';
exception when others then null; end $$;
select cron.schedule('epas_v35_scheduler','*/15 * * * *','select public.epas_scheduler_tick_v35();');
