from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v2_2_project_phase_orchestration.sql').read_text()
WORKSPACE = (ROOT / 'components' / 'project_workspace.py').read_text()
QUERIES = (ROOT / 'database' / 'queries.py').read_text()
SHIP = (ROOT / 'components' / 'ship_register.py').read_text()


def test_phase_control_exists():
    assert 'create table if not exists project_phase_control' in SQL
    assert "'NOT_APPLICABLE','LOCKED','READY','IN_PROGRESS','COMPLETED','BLOCKED'" in SQL


def test_sequential_dependencies_are_server_enforced():
    assert "Waiting for Plan Appraisal completion" in SQL
    assert "Waiting for '||replace(prev_phase,'_',' ')||' completion" in SQL
    assert "if p_phase='nsc_survey' and v_gate<>'READY'" in SQL
    assert "if p_phase='in_service' and v_gate not in ('READY','COMPLETED')" in SQL


def test_scope_can_end_after_plan_or_continue_to_survey():
    assert "'plan_appraisal'" in SQL and "'nsc_survey'" in SQL and "'in_service'" in SQL
    assert 'All selected project phases are complete' in WORKSPACE
    assert 'Project Execution Roadmap' in WORKSPACE


def test_vessel_survey_status_is_persistent_and_historized():
    for token in ['survey_status', 'next_survey_due', 'last_survey_date', 'last_survey_phase', 'class_status']:
        assert token in SQL
    assert 'create table if not exists vessel_survey_status_history' in SQL
    assert 'epas_refresh_vessel_survey_status' in SQL


def test_ship_register_reads_live_status():
    assert 'epas_ship_register' in QUERIES or 'production_queries' in QUERIES
    assert 'Survey Status' in SHIP
    assert 'q.vessel_survey_status' in SHIP


def test_rfi_authority_rules_remain_intact():
    assert "v_role='shipyard' and p_phase<>'nsc_survey'" in SQL
    assert "v_role in ('owner','ship_management') and p_phase<>'in_service'" in SQL
