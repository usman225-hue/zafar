# EPAS v3.0 — Final Complete Streamlit Release

EPAS is a production-oriented, role-controlled Streamlit application backed by Supabase Auth, PostgreSQL/RLS and controlled workflow RPCs.

## Roles
GM, Department Manager, Authorised Engineer, Authorised Surveyor, Designer, Owner, Ship Management, Shipyard.

## Authoritative RFI rules
- Shipyard → NSC Survey RFI only.
- Owner → In-Service Survey RFI only.
- Ship Management → In-Service Survey RFI only.

## Workflow
Project scope → Plan Appraisal → approved drawings → NSC (if selected) → persistent In-Service phase (if selected) → recurring survey cycles → observations → corrective actions → evidence → verification → GM decision → certificate package → DM acknowledgement → certificate → Ship Register → next survey cycle.

## Final hardening
- RLS and role/phase scoping on new operational records.
- Role-scoped SECURITY DEFINER read gates.
- Idempotent In-Service cycle transitions.
- Dependency invalidation on scope and assignment changes.
- Actual uploaded-file SHA-256 for controlled survey reports.
- Stakeholder-safe schedule/timeline/certificate status.
- Final privilege registry and high-risk legacy RPC revocation.
- Role-native Streamlit cockpits and responsive/accessibility polish.
- Production Cron deployment and live acceptance material.

## Deployment
1. Apply all cumulative migrations through `database/production_v2_9_security_ux_release_hardening.sql`.
2. Apply `database/production_v3_0_final_release_hardening.sql`.
3. Configure Supabase Cron with `deployment/supabase_cron_v30.sql`.
4. Configure `SUPABASE_URL`, `SUPABASE_ANON_KEY` and optionally `EPAS_REQUIRE_MFA=1`.
5. Install `requirements.txt` and run `run_streamlit.sh`.
6. Execute the live eight-role acceptance in `docs/V3_0_FINAL_PRODUCTION_ACCEPTANCE.md`.
