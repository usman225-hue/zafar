-- EPAS v3.3 production scheduler deployment.
-- Run once in Supabase SQL Editor by an administrator after applying v3.3 migration.
create extension if not exists pg_cron;
do $$ begin
  if exists(select 1 from cron.job where jobname='epas-v33-lifecycle') then
    perform cron.unschedule('epas-v33-lifecycle');
  end if;
exception when undefined_table then null;
end $$;
select cron.schedule('epas-v33-lifecycle','*/15 * * * *', $$select public.epas_scheduler_tick_v33();$$);
