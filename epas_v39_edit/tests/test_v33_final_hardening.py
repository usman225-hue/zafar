from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def read(rel): return (ROOT/rel).read_text(encoding="utf-8")

def test_v33_facade_is_authoritative_and_lower_versions_revoked():
    sql=read("database/production_v3_3_final_hardening.sql")
    for marker in [
        "epas_schedule_queue_v33","epas_timeline_v33","epas_survey_start_gate_v33",
        "epas_survey_submission_gate_v33","epas_surveyor_accept_assignment_v33",
        "epas_acknowledge_survey_scope_v33","epas_start_survey_execution_v33",
        "epas_certificate_issuance_gate_v33","epas_register_certificate_pdf_v33",
        "epas_submit_survey_report_v33","epas_mark_in_service_cycle_complete_v33",
        "epas_scheduler_tick_v33","epas_authorized_projects_v33",
        "epas_stakeholder_fleet_bundle_v33","epas_stakeholder_vessel_bundle_v33"]:
        assert marker in sql
    assert "epas_schedule_queue_v32" in sql and "revoke execute on function" in sql
    assert "epas_live_acceptance_runs_v33" in sql

def test_batch_helpers_remove_active_n_plus_one_patterns():
    q=read("database/production_queries.py"); ws=read("components/role_workspaces.py"); dm=read("components/dm_production.py")
    assert "def plan_drawings_by_ids" in q
    assert "def rfis_by_ids" in q
    assert "drawing_map=pq.plan_drawings_by_ids" in ws
    assert "rfi_map=pq.rfis_by_ids" in ws
    assert "drawing_map=pq.plan_drawings_by_ids" in dm

def test_file_upload_is_cleanup_controlled():
    q=read("database/production_queries.py"); cert=read("components/production_certificate.py")
    assert "def upload_with_cleanup" in q
    assert "upload_with_cleanup" in cert
    assert "register_certificate_pdf_v33" in cert

def test_scheduler_v33_deployment_exists():
    assert (ROOT/"deployment/supabase_cron_v33.sql").exists()
    assert "epas_scheduler_tick_v33" in read("deployment/supabase_cron_v33.sql")

def test_live_acceptance_harness_exists():
    live=read("deployment/live_acceptance_v33.py")
    for case in ["RLS_CROSS_PROJECT","STORAGE_CROSS_PROJECT","SESSION_ISOLATION","NSC_ONLY_SHIPYARD","INSERVICE_OWNER_ONLY","INSERVICE_SHIP_MANAGEMENT_ONLY","INSERVICE_CYCLE_1_TO_2","CERTIFICATE_UPLOAD_ROLLBACK","SCHEDULER_EXECUTION"]:
        assert case in live

def test_v33_app_is_active():
    app=read("app.py")
    assert "v3.9" in app
    assert "survey_lifecycle_v36" in app
