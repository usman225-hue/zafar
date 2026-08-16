from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v2_4_state_of_art_lifecycle.sql').read_text()
APP = (ROOT / 'components' / 'professional_center.py').read_text()
QUERIES = (ROOT / 'database' / 'production_queries.py').read_text()


def test_recurring_in_service_schedule_engine():
    assert 'create table if not exists survey_schedules' in SQL
    assert 'epas_sync_survey_schedule' in SQL
    assert 'epas_refresh_all_survey_schedules' in SQL
    assert "phase in ('nsc_survey','in_service')" in SQL


def test_in_service_is_continuing_phase():
    assert 'In-Service is operationally continuous' in SQL
    assert "s:='IN_PROGRESS'" in SQL
    assert 'individual survey cycles are tracked separately' in SQL


def test_exact_drawing_snapshot():
    for token in ('shared_revision','shared_sha256','shared_storage_path','shared_document_id','package_version'):
        assert token in SQL
    assert 'immutable_snapshot' in SQL


def test_drawing_revision_impact_control():
    assert 'epas_survey_drawing_revision_impact' in SQL
    assert 'REVISION_CHANGED' in SQL
    assert 'DM must review impact' in SQL


def test_certificate_decision_package_is_frozen():
    assert 'certificate_decision_packages' in SQL
    assert 'epas_freeze_certificate_decision_package' in SQL
    assert 'observation_snapshot' in SQL
    assert 'drawing_package_snapshot' in SQL


def test_observation_level_evidence():
    assert 'observation_evidence' in SQL
    assert 'epas_register_observation_evidence' in SQL
    assert 'exact corrective-action observation pair' in SQL


def test_central_rfi_policy():
    assert 'rfi_creation_policy' in SQL
    assert "('shipyard','nsc_survey',true" in SQL
    assert "('shipyard','in_service',false" in SQL
    assert "('owner','in_service',true" in SQL
    assert "('ship_management','in_service',true" in SQL
    assert 'phase is not currently eligible' in SQL


def test_rfi_scope_amendment_lifecycle():
    assert 'survey_scope_amendments' in SQL
    assert 'epas_request_rfi_scope_amendment' in SQL
    assert 'epas_dm_decide_rfi_scope_amendment' in SQL
    assert 'Scope is locked after survey execution begins' in SQL


def test_authoritative_ship_register_and_status():
    assert 'create or replace view ship_register' in SQL
    assert 'schedule_status' in SQL
    assert 'survey_status' in SQL
    assert 'vessel_next_survey_due' in SQL


def test_lifecycle_timeline_and_notifications():
    assert 'lifecycle_events' in SQL
    assert 'epas_project_timeline' in SQL
    assert 'epas_generate_survey_due_notifications' in SQL
    assert 'Survey schedule updated' in SQL


def test_professional_center_surfaces_lifecycle():
    assert 'Survey lifecycle & Ship Register control tower' in APP
    assert 'Project lifecycle timeline' in APP
    assert 'survey_schedule_queue' in QUERIES
    assert 'project_timeline' in QUERIES
