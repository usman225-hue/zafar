"""Static regression checks for EPAS v2.6 final workflow hardening."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "database" / "production_v2_6_final_workflow_acceptance_hardening.sql").read_text()
QUERIES = (ROOT / "database" / "production_queries.py").read_text()
ROLE_UI = (ROOT / "components" / "role_workspaces.py").read_text()
PRO_UI = (ROOT / "components" / "professional_center.py").read_text()


def test_revision_impact_snapshot_is_auditable():
    for token in [
        "survey_drawing_impact_decision_history",
        "comparison_snapshot",
        "shared_revision",
        "current_revision",
        "shared_sha256",
        "current_sha256",
    ]:
        assert token in SQL


def test_drawing_snapshot_is_immutable():
    assert "epas_guard_survey_drawing_snapshot_update" in SQL
    assert "Immutable survey drawing handover snapshot cannot be modified" in SQL


def test_execution_basis_is_versioned_and_hashed():
    for token in [
        "survey_execution_basis_versions",
        "execution_basis_version",
        "basis_sha256",
        "basis_frozen_at",
        "scope_acknowledged_version",
        "drawing_package_ack_version",
    ]:
        assert token in SQL


def test_scope_ack_and_amendment_cascade_exist():
    assert "survey_scope_acknowledgements" in SQL
    assert "epas_acknowledge_survey_scope" in SQL
    assert "Scope version changed; DM must reassign Surveyor / rebuild controlled survey package." in SQL
    assert "scope_acknowledged_version" in SQL


def test_checklist_definitions_are_versioned():
    assert "survey_checklist_definitions" in SQL
    assert "survey_checklist_definition_items" in SQL
    assert "definition_id" in SQL
    assert "checklist_version" in SQL


def test_structured_surveyor_declaration_is_required():
    assert "survey_execution_declarations" in SQL
    assert "epas_confirm_survey_execution_declaration" in SQL
    assert "declaration_complete" in SQL
    assert "Professional Surveyor Declaration" in ROLE_UI


def test_survey_start_gate_is_composite():
    assert "epas_survey_start_gate_v26" in SQL
    for token in [
        "assignment_accepted",
        "package_acknowledged",
        "checklist_ready",
        "revision_impact_clear",
        "scope_acknowledged",
    ]:
        assert token in SQL
    assert "epas_start_survey_execution_v26" in SQL


def test_certificate_ack_is_version_and_hash_bound():
    assert "certificate_decision_acknowledgement_versions" in SQL
    assert "package_version" in SQL
    assert "package_sha256" in SQL
    assert "dm_acknowledged" in SQL


def test_schedule_has_no_silent_12_month_fallback():
    assert "CONFIGURATION_REQUIRED" in SQL
    assert "survey_interval_months" in SQL
    assert "Schedule interval must be explicitly configured and positive" in SQL
    assert "epas_sync_survey_schedule_v26" in SQL


def test_schedule_basis_and_cycle_linkage_exist():
    for token in [
        "schedule_basis_date",
        "due_basis",
        "due_basis_reference",
        "current_rfi_id",
        "cycle_number",
        "epas_stakeholder_create_scheduled_in_service_rfi",
        "epas_survey_schedule_action_context",
    ]:
        assert token in SQL


def test_vessel_status_projection_has_real_completion_dates():
    assert "last_survey_completed_at" in SQL
    assert "last_survey_report_submitted_at" in SQL
    assert "last_certificate_issued_date" in SQL
    assert "old_status:=v.survey_status" in SQL


def test_recurring_in_service_does_not_close_phase():
    assert "IN_SERVICE_ACTIVE" in SQL or "IN_SERVICE_IN_PROGRESS" in SQL
    assert "epas_mark_in_service_cycle_complete" in SQL
    assert "Current In-Service cycle complete; next cycle scheduled" in SQL or "next cycle scheduled" in SQL


def test_notification_policy_is_phase_specific():
    assert "survey_notification_policy" in SQL
    assert "Shipyard" in SQL or "shipyard" in SQL
    assert "role_gate" not in SQL  # final policy table replaces scattered role branching
    assert "epas_generate_survey_due_notifications_v26" in SQL


def test_scheduler_is_service_role_only():
    assert "epas_scheduler_tick" in SQL
    assert "current_user <> 'service_role'" in SQL
    assert "grant execute on function epas_scheduler_tick() to service_role" in SQL


def test_cross_project_read_guards_exist():
    assert "epas_is_project_member(p_project_id)" in SQL
    assert "Not authorized for survey schedule queue" in SQL
    assert "Not authorized for project timeline" in SQL or "epas_project_timeline" in SQL


def test_stakeholder_rfi_rules_are_authoritative_and_schedule_linked():
    for token in [
        "rfi_creation_policy",
        "Shipyard may initiate NSC Survey RFI",
        "Shipyard may not initiate In-Service RFI",
        "Owner may initiate In-Service RFI",
        "Ship Management may initiate In-Service RFI",
        "current_rfi_id=r.id",
    ]:
        assert token in SQL


def test_queries_and_ui_use_v26_controls():
    for token in [
        "survey_start_gate_v26",
        "survey_submission_gate_v26",
        "acknowledge_survey_scope",
        "create_scheduled_in_service_rfi",
        "schedule_action_context",
        "project_scope_state",
    ]:
        assert token in QUERIES
    for token in [
        "Accept formal survey assignment",
        "Acknowledge current survey scope",
        "Acknowledge controlled drawing package",
        "Start controlled survey execution",
        "Professional Surveyor Declaration",
        "Initiate this In-Service survey cycle",
    ]:
        assert token in ROLE_UI


def test_professional_center_retains_survey_control():
    assert "render_survey_control" in PRO_UI
    assert "Survey Control" in PRO_UI
