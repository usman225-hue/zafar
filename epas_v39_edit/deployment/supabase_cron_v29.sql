-- EPAS v2.9 production scheduler.
-- Run after production_v2_9_security_ux_release_hardening.sql.
-- Requires pg_cron enabled in the Supabase project.
select cron.unschedule(jobid) from cron.job where jobname='epas-v28-lifecycle-tick';
select cron.unschedule(jobid) from cron.job where jobname='epas-v29-lifecycle-tick';
select cron.schedule('epas-v29-lifecycle-tick','*/15 * * * *', $$select epas_scheduler_tick_v29();$$);
