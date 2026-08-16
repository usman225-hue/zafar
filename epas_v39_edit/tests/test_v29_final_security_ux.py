from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database/production_v2_9_security_ux_release_hardening.sql').read_text()
APP = (ROOT / 'app.py').read_text()
THEME = (ROOT / 'styles/theme.py').read_text()
SUPABASE = (ROOT / 'config/supabase_client.py').read_text()


def test_v29_migration_exists_and_enables_rls_on_new_operational_tables():
    assert 'alter table survey_cycle_instances enable row level security' in SQL
    assert 'alter table survey_checklist_instances enable row level security' in SQL
    assert 'alter table survey_assignment_acknowledgements enable row level security' in SQL


def test_v29_stakeholder_phase_policy_is_explicit():
    assert "v_role='shipyard' then return p_phase='nsc_survey'" in SQL
    assert "v_role in ('owner','ship_management') then return p_phase='in_service'" in SQL


def test_v29_secure_read_wrappers_exist():
    for fn in [
        'epas_scope_version_sha256_v29',
        'epas_assignment_fingerprint_v29',
        'epas_survey_checklist_ready_v29',
        'epas_survey_start_gate_v29',
        'epas_survey_submission_gate_v29',
        'epas_certificate_issuance_gate_v29',
        'epas_survey_schedule_queue_v29',
        'epas_project_timeline_v29',
    ]:
        assert fn in SQL


def test_v29_report_hash_is_not_synthetic():
    assert 'Actual survey report SHA-256 is required' in SQL
    assert 'p_evidence_sha256' in SQL and 'p_size_bytes' in SQL


def test_v29_fail_closed_production_runtime():
    assert 'EPAS_ENABLE_DEMO_MODE' in SUPABASE
    assert 'SUPABASE_URL and SUPABASE_ANON_KEY are required' in SUPABASE
    assert 'Demo data · not connected' not in SUPABASE


def test_v29_streamlit_cockpit_and_alias_are_present():
    assert 'render_role_cockpit' in APP
    assert 'render_survey_lifecycle_v36' in APP
    assert (ROOT / 'components/role_cockpits.py').exists()


def test_v29_theme_is_self_contained_and_responsive():
    assert 'fonts.googleapis.com' not in THEME
    assert '@media (max-width: 800px)' in THEME
    assert 'prefers-reduced-motion' in THEME
    assert 'focus-visible' in THEME


def test_v29_scheduler_is_service_role_only():
    assert "if current_user<>'service_role'" in SQL
    assert 'epas_scheduler_tick_v29' in SQL
    assert (ROOT / 'deployment/supabase_cron_v29.sql').exists()


def test_v29_cycle_completion_is_idempotent():
    assert 'if exists(select 1 from survey_cycle_instances c where c.rfi_id=r.id and c.status=\'COMPLETED\')' in SQL
    assert 'unique(schedule_id,cycle_number)' in SQL or 'unique(schedule_id,cycle_number)' in (ROOT/'database/production_v2_8_final_hardening.sql').read_text()
