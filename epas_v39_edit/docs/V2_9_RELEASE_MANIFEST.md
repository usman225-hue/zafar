# EPAS v2.9 Release Manifest

Release: EPAS v2.9 Final Production Hardening
Baseline: EPAS v2.8 complete package

## Core additions
- `database/production_v2_9_security_ux_release_hardening.sql`
- `deployment/supabase_cron_v29.sql`
- `deployment/validate_production_v29.py`
- `components/role_cockpits.py`
- `utils/file_validation.py`
- `tests/test_v29_final_security_ux.py`
- `docs/V2_9_FINAL_GAP_CLOSURE.md`
- `docs/V2_9_PROFESSIONAL_AUDIT_MATRIX.md`
- `docs/V2_9_DEPLOYMENT_RUNBOOK.md`

## Workflow rules
- Shipyard: NSC RFI only.
- Owner: In-Service RFI only.
- Ship Management: In-Service RFI only + assigned corrective action evidence.
- Plan Appraisal gates later phases where selected.
- NSC gates In-Service where selected.
- In-Service is persistent; cycles recur.

## Validation performed in build environment
- `pytest -q`: 154 passed, 1 skipped.
- `python -m compileall -q .`: PASS.
- `python deployment/validate_production_v29.py`: PASS.

## Live evidence still required after deployment
- RLS/Storage negative tests with eight real roles.
- Supabase Cron execution and failure/recovery test.
- Streamlit browser acceptance on configured deployment.
- In-Service Cycle 1 → Cycle 2 end-to-end proof.
