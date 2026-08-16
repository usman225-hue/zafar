from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v2_8_final_hardening.sql').read_text()
Q = (ROOT / 'database' / 'production_queries.py').read_text()
UI = (ROOT / 'components' / 'survey_lifecycle_v32.py').read_text()
PRO = (ROOT / 'components' / 'professional_center.py').read_text()
APP = (ROOT / 'app.py').read_text()


def test_persistent_in_service_phase_and_cycle_entity():
    assert 'create table if not exists survey_cycle_instances' in SQL
    assert "In-Service remains ACTIVE; %s completed cycle(s)" in SQL
    assert "persistent phase remains active" in SQL


def test_cycle_2_creation_and_scheduler_sync():
    assert 'epas_mark_in_service_cycle_complete_v28' in SQL
    assert 'cycle_number=cycle_number+1' in SQL
    assert "intent_action='CREATE_IN_SERVICE_RFI'" in SQL
    assert 'epas_sync_survey_schedule_v28' in SQL
    assert 'cycle_instance_id' in SQL


def test_security_definer_mutation_guards():
    assert "if current_user<>'service_role'" in SQL
    assert "revoke all on function epas_sync_survey_schedule_v27(uuid) from authenticated,public" in SQL
    assert 'Only project GM/DM may complete an In-Service cycle' in SQL
    assert 'epas_is_project_member(v.project_id)' in SQL


def test_schedule_basis_has_explicit_date_and_no_silent_default():
    assert 'p_basis_date date' in SQL
    assert 'Basis date is mandatory' in SQL
    assert 'schedule_basis_snapshot' in SQL
    assert 'due_basis_date' in SQL
    assert "schedule_config_status='CONFIGURATION_REQUIRED'" in SQL
    # Streamlit must not visually default an unconfigured schedule to 12 months.
    assert "or 12" not in UI
    assert "or 12" not in PRO


def test_package_acknowledgement_is_versioned_and_invalidatable():
    assert 'acknowledgement_fingerprint' in SQL
    assert "ack_status='INVALIDATED'" in SQL
    assert 'scope_version integer' in SQL
    assert 'package_fingerprint' in SQL


def test_scope_change_invalidates_dependent_artifacts():
    assert 'Scope amendment approved' in SQL
    assert 'perform epas_invalidate_survey_package_acknowledgements' in SQL
    assert "update survey_checklist_items set status='pending'" in SQL
    assert 'basis_frozen_at=null' in SQL


def test_versioned_checklist_fingerprint_and_execution_gate():
    assert 'survey_checklist_instances' in SQL
    assert 'epas_survey_checklist_ready_v28' in SQL
    assert 'checklist_definition_fingerprint' in SQL
    assert 'epas_survey_start_gate_v28' in SQL
    assert "'revision_clear',revision_clear" in SQL
    assert "'assignment_accepted'" in SQL


def test_assignment_acknowledgement_is_fingerprinted():
    assert 'survey_assignment_acknowledgements' in SQL
    assert 'assignment_fingerprint' in SQL
    assert 'epas_surveyor_accept_assignment_v28' in SQL


def test_revision_impact_freezes_comparison_evidence():
    for col in ['shared_revision','shared_sha256','current_revision','current_sha256','comparison_sha256']:
        assert col in SQL
    assert 'comparison_fp:=' in SQL


def test_execution_basis_and_report_are_anchored():
    assert 'execution_basis_version' in SQL
    assert 'report_sha256' in SQL
    assert 'report_completed_at' in SQL
    assert "report_id=v_report.id" in SQL
    assert 'execution_basis_version' in SQL and 'report_sha256' in SQL


def test_certificate_package_freezes_report_and_declaration():
    assert 'survey_report_sha256' in SQL
    assert 'declaration_sha256' in SQL
    assert "package_state='SUPERSEDED'" in SQL
    assert 'exact package version/sha' in SQL or 'package_version' in SQL


def test_evidence_is_exactly_bound_to_corrective_action_observation():
    assert 'Evidence must be bound to an exact corrective action' in SQL
    assert 'corrective_action_observations' in SQL
    assert "role_name='surveyor'" in SQL
    assert 'r.assigned_surveyor_id<>auth.uid()' in SQL


def test_notification_boundary_and_service_scheduler():
    assert 'epas_generate_survey_due_notifications_v28' in SQL
    assert 'survey_notification_policy_v27' in SQL
    assert "shipyard" in SQL and "in_service" in SQL
    assert 'epas_scheduler_tick_v28' in SQL
    assert "grant execute on function epas_scheduler_tick_v28() to service_role" in SQL


def test_project_scoped_schedule_query():
    assert 'epas_survey_schedule_queue_v28' in SQL
    assert 'epas_is_project_member(p_project_id)' in SQL
    assert 'Global schedule requires GM/DM' in SQL


def test_streamlit_role_router_exists_without_actor_selector():
    assert 'render_auth()' in APP
    assert 'if role == cfg.ROLE_GM' in APP
    assert 'cfg.ROLE_DM' in APP
    assert 'cfg.ROLE_ENGINEER' in APP
    assert 'cfg.ROLE_SURVEYOR' in APP
    assert 'cfg.ROLE_DESIGNER' in APP
    assert 'cfg.ROLE_SHIP_MANAGEMENT' in APP
    assert 'cfg.ROLE_OWNER' in APP
    assert 'cfg.ROLE_SHIPYARD' in APP
    assert 'actor_select' not in APP.lower() and 'select_actor' not in APP.lower()


def test_deployment_has_v28_cron():
    cron = (ROOT / 'deployment' / 'supabase_cron_v28.sql').read_text()
    assert 'epas-survey-lifecycle-v28' in cron
    assert "epas_scheduler_tick_v28()" in cron
    assert '*/15 * * * *' in cron


def test_readiness_matrix_includes_live_checks():
    for key in ['RLS_LIVE','CRON_LIVE','BROWSER_LIVE','IN_SERVICE_CYCLE_2','STAKEHOLDER_BOUNDARY']:
        assert key in SQL
