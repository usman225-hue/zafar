# EPAS v3.5 Final — Role UX + Scheduler + Security + Performance Hardening

This cumulative release builds on v3.4 and closes the audited owner/ship-management/shipyard UX, coordination, recurring In-Service, scheduler maintainability, security minimization, audit verification, and performance gaps.

## Core rules
- Shipyard → NSC Survey RFI only.
- Owner → In-Service Survey RFI only.
- Ship Management → In-Service Survey RFI only.
- Plan Appraisal approved drawings are selectively handed to the assigned Surveyor.
- In-Service is a persistent phase; survey cycles recur.

## Run
`streamlit run app.py`

## Deployment
Apply the cumulative migrations through v3.5, then install `deployment/supabase_cron_v35.sql` in the live Supabase project.

For enterprise document controls set:
- `EPAS_REQUIRE_ANTIVIRUS=1`
- `EPAS_CLAMSCAN_BIN=clamscan`

Run:
- `python deployment/validate_production_v35.py`
- `python deployment/live_acceptance_v35.py`
- `python deployment/load_test_v35.py --url <authorized-health-url> --users 10 --rounds 3`

## Important
Live RLS/Storage/Cron/concurrency acceptance is deployment evidence and is not represented as pre-executed by the development environment.
