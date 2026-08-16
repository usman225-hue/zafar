from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SQL=(ROOT/'database/production_v1_9_role_complete_gaps_11_20.sql').read_text()
RW=(ROOT/'components/role_workspaces.py').read_text()
PQ=(ROOT/'database/production_queries.py').read_text()
RG=(ROOT/'components/resource_governance.py').read_text()


def test_shipyard_nsc_only_is_server_enforced():
    assert "v_role='shipyard' and p_phase<>'nsc_survey'" in SQL
    assert "Shipyard may initiate NSC Survey RFIs only" in SQL


def test_owner_and_ship_management_inservice_only():
    assert "v_role in ('owner','ship_management') and p_phase<>'in_service'" in SQL
    assert "Owner and Ship Management may initiate In-Service Survey RFIs only" in SQL


def test_survey_prechecklist_exists():
    assert 'create table if not exists survey_checklist_items' in SQL
    assert 'epas_complete_survey_checklist_item' in SQL
    assert 'epas_survey_submission_gate' in SQL
    assert 'Pre-Survey Checklist' in RW


def test_observation_model_is_professional():
    for col in ['rule_reference','location','equipment_system','deficiency_category','responsible_party','target_date','corrective_action','evidence_required','verification_method']:
        assert f'add column if not exists {col}' in SQL


def test_follow_up_types_are_explicit():
    for value in ['NSC_REWORK_VERIFICATION','IN_SERVICE_OBSERVATION_CLEARANCE','CHANGE_OF_CLASS_FOLLOW_UP','GENERAL_FOLLOW_UP']:
        assert value in SQL
    assert 'epas_dm_create_follow_up_rfi' in SQL


def test_owner_shipyard_vessel_dashboard():
    assert 'epas_stakeholder_fleet_summary' in SQL
    assert 'epas_stakeholder_vessel_dashboard' in SQL
    assert 'epas_stakeholder_upcoming_surveys' in SQL
    assert 'Vessel Status Overview' in RW


def test_designer_submission_lineage():
    assert 'parent_revision_id' in SQL
    assert 'submission_reason' in SQL
    assert 'epas_designer_submission_queue' in SQL
    assert 'Submission tracker' in RW


def test_ship_management_action_queue():
    assert 'epas_ship_management_action_queue' in SQL
    assert 'My corrective-action queue' in RW


def test_resource_allocation_matrix():
    assert 'resource_assignment_snapshots' in SQL
    assert 'epas_resource_allocation_matrix' in SQL
    assert 'Assignment Matrix' in RG
    assert 'resource_allocation_matrix' in PQ


def test_sla_fields_present():
    assert 'sla_due_at' in SQL
    assert 'sla_state' in SQL
    assert 'epas_refresh_task_sla' in SQL
