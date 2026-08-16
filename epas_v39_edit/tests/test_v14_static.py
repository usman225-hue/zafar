from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v1_4.sql').read_text()


def test_v14_rpc_only_lockdown():
    for table in ['workflow_tasks','plan_drawings','plan_appraisal_observations','document_revisions','notifications']:
        assert f'revoke insert, update, delete on {table}' in SQL


def test_v14_real_execution_portals():
    app = (ROOT / 'app.py').read_text()
    for marker in ['render_engineer','render_surveyor','render_designer','render_ship_management']:
        assert marker in app


def test_v14_management_controls():
    for marker in ['epas_gm_amended_design_decision','epas_project_health','epas_resource_workload','epas_gm_escalation_decide','epas_audit_row_change']:
        assert marker in SQL


def test_v14_initial_plan_intake_and_observation_register():
    assert 'epas_designer_submit_initial_drawing' in SQL
    assert 'epas_respond_plan_observation' in SQL
    assert 'epas_close_plan_observation' in SQL
    assert 'epas_clear_survey_observation' in SQL
