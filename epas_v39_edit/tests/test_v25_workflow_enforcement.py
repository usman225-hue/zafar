"""Static regression checks for EPAS v2.5 workflow enforcement/hardening."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "database" / "production_v2_5_workflow_enforcement_hardening.sql").read_text()
QUERIES = (ROOT / "database" / "production_queries.py").read_text()
UI = (ROOT / "components" / "professional_center.py").read_text()


def test_immutable_drawing_metadata_is_frozen():
    for token in ["shared_drawing_no", "shared_title", "shared_discipline", "shared_sha256", "shared_revision"]:
        assert token in SQL


def test_revision_impact_requires_decision_or_reissue():
    assert "epas_dm_decide_drawing_revision_impact" in SQL
    assert "epas_reissue_survey_drawing_package" in SQL
    assert "revision_impact_pending" in SQL


def test_survey_start_requires_acceptance_ack_checklist():
    assert "epas_surveyor_accept_assignment" in SQL
    assert "epas_acknowledge_survey_drawing_package" in SQL
    assert "epas_start_survey_execution" in SQL
    assert "checklist_ready" in SQL
    assert "ready_to_submit" in SQL


def test_report_submit_is_guarded_server_side():
    assert "trg_epas_guard_survey_report_submit" in SQL
    assert "epas_guard_survey_report_submit" in SQL


def test_certificate_requires_frozen_package_and_dm_ack():
    assert "epas_certificate_issuance_gate" in SQL
    assert "certificate_decision_acknowledgements" in SQL
    assert "epas_acknowledge_certificate_decision_package" in SQL
    assert "gate:=epas_certificate_issuance_gate" in SQL


def test_security_definer_read_paths_check_project_membership():
    assert "Not authorized for project timeline" in SQL
    assert "Not authorized for project schedule" in SQL
    assert "epas_is_project_member(p_project_id)" in SQL


def test_system_operations_are_restricted():
    assert "revoke all on function epas_refresh_all_survey_schedules() from authenticated" in SQL
    assert "revoke all on function epas_generate_survey_due_notifications() from authenticated" in SQL
    assert "epas_refresh_all_survey_schedules_as_operator" in SQL


def test_recurring_in_service_schedule_has_independent_due_basis():
    for token in ["due_basis", "due_basis_reference", "survey_interval_months", "current_rfi_id", "cycle_number"]:
        assert token in SQL


def test_vessel_status_history_uses_previous_state():
    assert "old_status:=v.survey_status" in SQL
    assert "if old_status is distinct from new_status then" in SQL


def test_exact_rfi_rules_remain_authoritative():
    assert "rfi_creation_policy" in SQL
    assert "Shipyard may initiate NSC Survey RFI" in SQL
    assert "Shipyard may not initiate In-Service RFI" in SQL
    assert "Owner may not initiate NSC RFI" in SQL
    assert "Owner may initiate In-Service RFI" in SQL
    assert "Ship Management may not initiate NSC RFI" in SQL
    assert "Ship Management may initiate In-Service RFI" in SQL


def test_scope_versions_are_immutable_basis():
    assert "survey_scope_versions" in SQL
    assert "source_amendment_id" in SQL
    assert "scope_version=(basis->>'scope_version')::integer" in SQL


def test_queries_expose_enforced_workflow_actions():
    for token in [
        "surveyor_accept_assignment",
        "surveyor_acknowledge_drawing_package",
        "start_survey_execution",
        "freeze_survey_execution_basis",
        "decide_drawing_revision_impact",
        "acknowledge_certificate_decision_package",
        "survey_control_tower",
    ]:
        assert token in QUERIES


def test_professional_center_exposes_survey_control():
    assert "render_survey_control" in UI
    assert "Survey Control" in UI
