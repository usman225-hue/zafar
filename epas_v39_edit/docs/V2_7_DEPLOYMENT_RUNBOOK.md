# EPAS v2.7 Deployment Runbook

1. Apply all cumulative migrations through `database/production_v2_7_final_gap_closure.sql` in order.
2. Configure Supabase Auth users and project memberships for GM, DM, Engineer, Surveyor, Designer, Shipyard, Owner and Ship Management.
3. Configure Storage policies for drawings, survey reports, certificates and observation evidence.
4. Configure a managed scheduler/Cron job to call `public.epas_scheduler_tick_v27()` with service-role execution.
5. Verify the Streamlit secrets file using `.streamlit/secrets.toml.example` or deployment environment variables.
6. Start the UI with `./run_streamlit.sh` or the included Dockerfile.
7. Run the live acceptance matrix with separate accounts for all roles, including the In-Service Cycle 1 → Cycle 2 path.

## Recommended scheduler

```sql
select cron.schedule(
  'epas-survey-lifecycle-v27',
  '5 * * * *',
  'select public.epas_scheduler_tick_v27();'
);
```

Do not grant the service-role scheduler function to ordinary authenticated users.
