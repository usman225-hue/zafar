-- EPAS v3.6 scheduler deployment.
-- Run in the Supabase SQL editor after production_v3_6_final_query_consolidation.sql.
select cron.schedule(
  'epas-v3-6-scheduler',
  '*/15 * * * *',
  $$select epas_scheduler_tick_v36();$$
);
