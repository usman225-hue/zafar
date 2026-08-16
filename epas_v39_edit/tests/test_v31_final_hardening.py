from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SQL=(ROOT/'database'/'production_v3_1_performance_security_final.sql').read_text()
APP=(ROOT/'app.py').read_text()
CLIENT=(ROOT/'config'/'supabase_client.py').read_text()
PQ=(ROOT/'database'/'production_queries.py').read_text()
COCKPIT=(ROOT/'components'/'role_cockpits.py').read_text()
VAL=(ROOT/'utils'/'file_validation.py').read_text()


def test_session_scoped_supabase_client():
    assert '@st.cache_resource' not in CLIENT
    assert 'epas_supabase_client_v35' in CLIENT or 'epas_supabase_client_v31' in CLIENT
    assert 'st.session_state' in CLIENT


def test_compact_dashboard_bundle_and_performance_indexes():
    assert 'epas_role_dashboard_bundle_v31' in SQL
    for token in ('idx_workflow_tasks_user_status_due_v31','idx_notifications_user_read_created_v31','idx_rfis_project_status_updated_v31','idx_survey_schedules_phase_due_v31'):
        assert token in SQL


def test_final_storage_policy_is_scoped():
    assert 'epas_project_documents_select_v31' in SQL
    assert 'epas_project_documents_insert_v31' in SQL
    assert 'epas_project_documents_update_v31' in SQL
    assert 'epas_project_documents_delete_v31' in SQL
    assert 'survey_rfi_drawings' in SQL


def test_no_silent_interval_fallback():
    assert 'epas_mark_in_service_cycle_complete_v31' in SQL
    assert "schedule interval/basis is not configured" in SQL
    assert 'coalesce(s.survey_interval_months,12)' not in SQL


def test_scheduler_v31_service_only():
    assert 'epas_scheduler_tick_v31' in SQL
    assert "current_user<>'service_role'" in SQL
    assert 'epas-v31-lifecycle-tick' in (ROOT/'deployment'/'supabase_cron_v31.sql').read_text()


def test_row_versioning_and_retry_health():
    assert 'row_version' in SQL
    assert 'epas_touch_row_version_v31' in SQL
    assert 'retry_count' in SQL
    assert 'critical_failures' in SQL


def test_upload_rollback_and_validation():
    assert '_upload_with_cleanup' in PQ
    assert 'validate_uploaded_file' in PQ
    assert 'MAX_PDF_BYTES' in PQ
    assert 'file_sha256' in VAL


def test_navigation_reduces_full_page_reruns():
    assert 'WORKSPACE' in APP
    assert 'Only the selected page is loaded' in APP


def test_role_cockpit_uses_compact_bundle():
    assert 'role_dashboard_summary' in COCKPIT
    assert 'schedule_due' in COCKPIT


def test_privilege_audit_present():
    assert 'epas_security_privilege_audit_v31' in SQL
    assert 'has_function_privilege' in SQL
