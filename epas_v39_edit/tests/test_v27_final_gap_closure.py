"""Static acceptance checks for EPAS v2.7 final gap closure."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "database" / "production_v2_7_final_gap_closure.sql").read_text()
QUERIES = (ROOT / "database" / "production_queries.py").read_text()
APP = (ROOT / "app.py").read_text()
ROLE_UI = (ROOT / "components" / "role_workspaces.py").read_text()
SURVEY_UI = (ROOT / "components" / "survey_lifecycle_v32.py").read_text()
PRO_UI = (ROOT / "components" / "professional_center.py").read_text()


def test_in_service_is_persistent_phase():
    for token in [
        "In-Service phase remains ACTIVE",
        "lifecycle_status",
        "IN_SERVICE_ACTIVE",
        "if s='COMPLETED' then s:='IN_PROGRESS'",
    ]:
        assert token in SQL


def test_cycle_two_can_be_created():
    for token in [
        "cycle_number=cycle_number+1",
        "current_rfi_id=null",
        "intent_action='CREATE_IN_SERVICE_RFI'",
        "persistent In-Service phase remains active",
    ]:
        assert token in SQL


def test_service_role_scheduler_and_legacy_function_restrictions():
    for token in [
        "epas_scheduler_tick_v27",
        "current_user<>'service_role'",
        "grant execute on function epas_scheduler_tick_v27() to service_role",
        "revoke all on function epas_sync_survey_schedule_v26(uuid) from authenticated",
        "revoke all on function epas_refresh_vessel_survey_status_v26(uuid) from authenticated",
    ]:
        assert token in SQL


def test_vessel_status_is_project_scoped():
    assert "Not authorized for vessel status" in SQL
    assert "epas_is_project_member(v.project_id)" in SQL


def test_cycle_completion_is_role_scoped():
    assert "epas_mark_in_service_cycle_complete_v27" in SQL
    assert "Only project GM/DM or service role may complete an In-Service cycle" in SQL


def test_schedule_basis_is_explicit_and_traceable():
    for token in [
        "schedule_basis_document_id",
        "schedule_basis_approved_by",
        "schedule_basis_approved_at",
        "schedule_basis_sha256",
        "configured_by",
        "configured_at",
        "Schedule interval must be explicitly configured and positive",
    ]:
        assert token in SQL


def test_drawing_package_ack_has_fingerprint():
    for token in [
        "survey_drawing_package_acknowledgements",
        "package_fingerprint",
        "epas_survey_drawing_package_fingerprint",
        "epas_acknowledge_survey_drawing_package_v27",
    ]:
        assert token in SQL


def test_scope_changes_invalidate_dependencies():
    for token in [
        "survey_scope_change_events",
        "epas_invalidate_scope_dependencies",
        "invalidated_scope_ack",
        "invalidated_drawing_package",
        "invalidated_checklist",
        "invalidated_execution_basis",
    ]:
        assert token in SQL


def test_execution_basis_freezes_exact_versions():
    for token in [
        "scope_version_sha256",
        "drawing_package_fingerprint",
        "checklist_definition_sha256",
        "epas_freeze_survey_execution_basis_v27",
        "basis_sha256",
    ]:
        assert token in SQL


def test_v27_survey_start_and_submission_gates_exist():
    for token in [
        "epas_survey_start_gate_v27",
        "epas_start_survey_execution_v27",
        "epas_survey_submission_gate_v27",
        "ready_to_submit",
    ]:
        assert token in SQL


def test_role_ui_uses_v27_survey_gate_and_package_ack():
    assert "survey_start_gate_v27" in QUERIES
    assert "acknowledge_survey_drawing_package_v27" in QUERIES
    assert "start_survey_execution_v27" in ROLE_UI


def test_streamlit_application_surface_exists():
    assert "import streamlit as st" in APP
    assert "render_survey_lifecycle_v36" in APP
    assert "survey_lifecycle_v36" in APP
    assert "render_v36_acceptance" in APP
    assert "Initiate this In-Service survey cycle" in SURVEY_UI
    assert "Schedule basis" in SURVEY_UI
    assert "Survey Control" in PRO_UI


def test_acceptance_matrix_contains_p0_cases():
    for token in [
        "V27_IN_SERVICE_CYCLE_2",
        "V27_SERVICE_SYNC_LOCK",
        "V27_STATUS_SCOPE_GUARD",
        "V27_CYCLE_COMPLETE_AUTH",
        "V27_SCOPE_CASCADE",
        "V27_SCHEDULER",
    ]:
        assert token in SQL
