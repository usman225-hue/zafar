# EPAS v3.3 Deployment Runbook

1. Apply `database/production_v3_3_final_hardening.sql` after the existing v3.2 migration chain.
2. Install/verify `pg_cron` and apply `deployment/supabase_cron_v33.sql`.
3. Set production environment variables: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `EPAS_REQUIRE_MFA=1` where policy requires MFA, and `EPAS_REQUIRE_ANTIVIRUS=1` when ClamAV is available and required by security policy.
4. Start Streamlit with `run_streamlit.sh` or the supplied Dockerfile.
5. Run `python deployment/validate_production_v33.py`.
6. Run `python deployment/live_acceptance_v33.py` in the live environment and record results in `epas_live_acceptance_runs_v33`.
7. Execute negative tests for cross-project RLS, phase isolation, Storage, session isolation, certificate rollback, and scheduler service-role restrictions.
8. Execute the In-Service Cycle 1 → Cycle 2 test and verify Ship Register / schedule updates.
9. Run concurrent upload and dashboard load tests before high-volume rollout.
