# EPAS v3.1 Deployment Runbook

## Database

Apply migrations in order through v3.0, then apply:

`database/production_v3_1_performance_security_final.sql`

## Cron

Run:

`deployment/supabase_cron_v31.sql`

The v3.1 scheduler runs every 15 minutes and calls the service-role-only
`epas_scheduler_tick_v31()` function.

## Streamlit

Required environment/secrets:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- optional `EPAS_REQUIRE_MFA=1`
- `EPAS_SESSION_TIMEOUT_MINUTES` if overriding the default application policy

Production is fail-closed when Supabase configuration is absent.

## Acceptance

Run the live acceptance matrix using eight distinct role accounts:

GM, DM, Engineer, Surveyor, Designer, Shipyard, Owner and Ship Management.

Explicitly verify:

- no cross-user session leakage;
- RLS isolation;
- Storage isolation;
- Shipyard NSC-only schedule/RFI visibility;
- Owner/Ship Management In-Service-only visibility;
- Cycle 1 → Cycle 2 recurrence;
- Cron execution;
- controlled file upload + failed-registration cleanup;
- certificate and audit workflows;
- browser usability at desktop/tablet widths.
