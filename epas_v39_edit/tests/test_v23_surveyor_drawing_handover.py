from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v2_3_surveyor_drawing_handover.sql').read_text()
DM = (ROOT / 'components' / 'dm_dashboard.py').read_text()
SV = (ROOT / 'components' / 'surveyor_dashboard.py').read_text()
UQ = (ROOT / 'database' / 'upgrade_queries.py').read_text()


def test_controlled_package_table_exists():
    assert 'create table if not exists survey_rfi_drawings' in SQL
    assert 'unique(rfi_id,drawing_id)' in SQL


def test_assignment_requires_approved_drawings_when_available():
    assert "d.status='approved'" in SQL
    assert 'Select at least one approved Plan Appraisal drawing' in SQL
    assert 'epas_assign_surveyor_with_drawings' in SQL


def test_surveyor_gets_only_explicit_package():
    assert 'epas_surveyor_drawing_package' in SQL
    assert 's.surveyor_id=auth.uid()' in SQL
    assert 's.revoked_at is null' in SQL


def test_surveys_cannot_submit_without_package():
    assert 'epas_require_survey_drawing_package' in SQL
    assert 'before insert on survey_reports' in SQL


def test_surveyor_plan_drawings_policy_is_restricted():
    assert 'drop policy if exists plan_drawings_select_v15' in SQL
    assert "epas_has_role('surveyor')" in SQL
    assert "status='approved'" in SQL
    assert 'exists(' in SQL and 'survey_rfi_drawings' in SQL


def test_dm_selects_relevant_drawings():
    assert 'Approved Plan Appraisal drawings to share with Surveyor' in DM
    assert 'Relevant approved drawings' in DM
    assert 'default=[]' in DM
    assert 'Assign Surveyor + Share Approved Drawing Package' in DM


def test_surveyor_dashboard_displays_controlled_package():
    assert 'Controlled Plan Appraisal Drawing Package' in SV
    assert 'approved Plan Appraisal' in SV
    assert 'surveyor_drawing_package' in SV


def test_live_assignment_uses_server_transaction():
    assert 'epas_assign_surveyor_with_drawings' in UQ
    assert 'p_drawing_ids' in UQ
