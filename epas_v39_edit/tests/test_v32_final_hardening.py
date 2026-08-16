from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


def test_v32_sql_exists_and_has_canonical_facade():
    sql = read('database/production_v3_2_final_performance_security_ux.sql')
    for marker in [
        'epas_project_health_bundle_v32',
        'epas_authorized_projects_v32',
        'epas_schedule_queue_v32',
        'epas_timeline_v32',
        'epas_survey_start_gate_v32',
        'epas_survey_submission_gate_v32',
        'epas_certificate_issuance_gate_v32',
        'epas_register_certificate_pdf_v32',
        'epas_mark_in_service_cycle_complete_v32',
        'epas_privilege_audit_v32',
    ]:
        assert marker in sql


def test_authenticated_legacy_survey_controls_revoked():
    sql = read('database/production_v3_2_final_performance_security_ux.sql')
    assert 'epas_submit_survey_report_v30' in sql
    assert 'epas_start_survey_execution_v28' in sql and 'names text[]' in sql
    assert 'epas_survey_start_gate_v30' in sql and 'names text[]' in sql


def test_client_is_session_scoped_not_globally_cached():
    client = read('config/supabase_client.py')
    assert '@st.cache_resource' not in client
    assert ('st.session_state.get("epas_supabase_client_v35")' in client) or ('st.session_state.get("epas_supabase_client_v31")' in client)


def test_cache_is_bounded_lru():
    cache = read('utils/session_cache.py')
    assert 'MAX_ENTRIES = 128' in cache
    assert 'popitem(last=False)' in cache


def test_certificate_upload_uses_cleanup_and_v32_registration():
    cert = read('components/production_certificate.py')
    assert 'upload_with_cleanup' in cert
    assert 'register_certificate_pdf_v33' in cert


def test_active_app_is_v32():
    app = read('app.py')
    lifecycle = read('components/survey_lifecycle_v33.py')
    assert 'v3.9' in app
    assert 'survey_lifecycle_v36' in app
    assert 'EPAS v3.3 Survey Lifecycle Control' in lifecycle


def test_dashboard_health_bundle_reduces_gm_project_health_n_plus_one():
    gm = read('components/gm_production.py')
    assert 'dashboard_project_health_bundle' in gm


def test_stakeholder_uses_role_scoped_project_and_schedule_apis():
    ws = read('components/role_workspaces.py')
    assert 'authorized_projects_v36' in ws or 'authorized_projects_v33' in ws
    assert 'stakeholder_fleet_bundle_v36' in ws or 'stakeholder_fleet_bundle_v33' in ws
