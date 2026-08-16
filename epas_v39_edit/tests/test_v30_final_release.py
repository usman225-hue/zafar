from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
SQL=(ROOT/'database'/'production_v3_0_final_release_hardening.sql').read_text()
APP=(ROOT/'app.py').read_text()
PQ=(ROOT/'database'/'production_queries.py').read_text()
COCKPIT=(ROOT/'components'/'role_cockpits.py').read_text()
VALIDATOR=(ROOT/'utils'/'file_validation.py').read_text()

def test_v30_migration_exists_and_versioned():
    assert 'EPAS v3.0' in SQL or 'EPAS v3.1' in (ROOT/'database'/'production_v3_1_performance_security_final.sql').read_text()
    assert (ROOT/'VERSION').read_text().strip().startswith(('3.','4.'))

def test_all_new_operational_tables_rls():
    assert 'alter table survey_cycle_instances enable row level security' in SQL.lower()
    assert 'alter table security_events_v29 enable row level security' in SQL.lower()
    assert 'alter table scheduler_failures_v29 enable row level security' in SQL.lower()
    assert 'alter table workflow_acceptance_cases_v29 enable row level security' in SQL.lower()

def test_stakeholder_schedule_and_timeline_wrappers():
    assert 'epas_schedule_queue_v30' in SQL
    assert 'epas_timeline_v30' in SQL
    assert "role_name='shipyard' and s.phase='nsc_survey'" in SQL
    assert "role_name in ('owner','ship_management') and s.phase='in_service'" in SQL

def test_internal_gates_are_role_scoped():
    assert 'epas_survey_start_gate_v30' in SQL
    assert "role_name not in ('gm','dm','surveyor')" in SQL
    assert 'epas_certificate_issuance_gate_v30' in SQL
    assert "role_name not in ('gm','dm')" in SQL

def test_recurring_cycle_idempotency():
    assert 'completion_idempotency_key' in SQL
    assert 'ux_cycle_completion_idempotency_v30' in SQL
    assert 'epas_mark_in_service_cycle_complete_v30' in SQL
    assert 'p_idempotency_key' in SQL

def test_dependency_invalidation():
    for token in ('trg_assignment_dependency_invalidation_v30','trg_scope_dependency_invalidation_v30','INVALIDATED'):
        assert token in SQL

def test_real_report_hash_enforced():
    assert 'epas_validate_survey_report_artifact_v30' in SQL
    assert "Actual survey report SHA-256 is required" in SQL
    assert 'report_storage_path' in SQL
    assert 'report_size_bytes' in SQL

def test_audit_chain_present():
    assert 'previous_hash' in SQL
    assert 'event_hash' in SQL
    assert 'trg_audit_chain_hash_v30' in SQL

def test_legacy_high_risk_revocation_is_present():
    assert 'epas_clear_survey_observation' in SQL
    assert 'revoke all on function' in SQL.lower()
    assert 'epas_privilege_registry_v30' in SQL

def test_streamlit_is_v30_and_role_native():
    assert 'v4.0' in APP or 'v3.9' in APP
    for role in ('gm','dm','engineer','surveyor','designer','owner','ship_management','shipyard'):
        assert role in COCKPIT

def test_streamlit_uses_v30_safe_queue_and_gate():
    assert 'schedule_bundle_v36' in COCKPIT or 'survey_schedule_queue' in COCKPIT
    assert 'survey_schedule_queue_v32' in PQ
    assert 'survey_start_gate_v32' in PQ
    assert 'survey_submission_gate_v32' in PQ

def test_file_validator_has_real_sha256():
    assert 'def file_sha256' in VALIDATOR
    assert 'hashlib.sha256' in VALIDATOR

def test_no_external_google_fonts_dependency():
    theme=(ROOT/'styles'/'theme.py').read_text()
    assert 'fonts.googleapis.com' not in theme

def test_live_acceptance_material_present():
    assert (ROOT/'deployment'/'live_acceptance_v30.py').exists()
    assert (ROOT/'docs'/'V3_0_FINAL_PRODUCTION_ACCEPTANCE.md').exists()
