# EPAS v3.5 Deployment Runbook

## 1. Database
Apply cumulative migrations through:
`database/production_v3_5_final_role_ux_scheduler.sql`

Use a real Supabase production project. Do not enable demo mode.

## 2. Scheduler
Install `deployment/supabase_cron_v35.sql` after pg_cron is enabled.
Verify the `epas_v35_scheduler` job runs every 15 minutes.

## 3. Security
Set:
- `EPAS_REQUIRE_ANTIVIRUS=1`
- `EPAS_CLAMSCAN_BIN=clamscan`

Keep the Supabase service-role key only in server-side deployment secrets. Never expose it to Streamlit users.

## 4. Streamlit
`streamlit run app.py`

For Docker use the supplied Dockerfile; it installs ClamAV and fails controlled document uploads closed if the scanner is unavailable.

## 5. Acceptance
Run:
- `python deployment/validate_production_v35.py`
- `python deployment/live_acceptance_v35.py`
- `python deployment/load_test_v35.py --url <authorized-health-url> --users 10 --rounds 3`
- repeat with `--users 30` for the pre-scale deployment gate.

## 6. Eight-role acceptance
Verify separate GM, DM, Engineer, Surveyor, Designer, Shipyard, Owner and Ship Management accounts against a live project. Test cross-project RLS, Storage isolation, stakeholder phase boundaries and recurring In-Service Cycle 1 → Cycle 2.
