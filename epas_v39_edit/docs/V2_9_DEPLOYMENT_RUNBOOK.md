# EPAS v2.9 Deployment Runbook

1. Apply migrations cumulatively through `database/production_v2_8_final_hardening.sql` and then `database/production_v2_9_security_ux_release_hardening.sql`.
2. Install `deployment/supabase_cron_v29.sql` in the Supabase project with pg_cron enabled.
3. Deploy the Streamlit application with `requirements.txt`.
4. Provide `SUPABASE_URL` and `SUPABASE_ANON_KEY` via Streamlit secrets or environment variables.
5. Do **not** set `EPAS_ENABLE_DEMO_MODE=1` in production.
6. Run `deployment/validate_production_v29.py` before exposing the application.
7. Create/verify eight live test accounts: GM, DM, Engineer, Surveyor, Designer, Shipyard, Owner, Ship Management.
8. Execute negative tests for cross-project access and stakeholder phase isolation.
9. Execute In-Service Cycle 1 → completion → due schedule → Cycle 2 RFI → Cycle 2 survey.
10. Verify Cron creates scheduler runs and that scheduler failures create `scheduler_failures_v29` rows and alerts.

11. For high-assurance deployments, set `EPAS_REQUIRE_MFA=1` and require Supabase Auth MFA/AAL2 for all production accounts. Supabase rate limiting/brute-force protection should also be enabled in the project authentication settings.
12. Rotate service/database credentials using the deployment platform secret store; never place secrets in the repository.
