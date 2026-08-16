from pathlib import Path

def test_project_nav_contains_survey_status_risk_and_ship_register_in_order():
    src = Path('components/project_workspace_v40.py').read_text()
    for label in ['Survey Status', 'Risk Register', 'Ship Register', 'Certification', 'Documents', 'Notifications', 'Audit Trail']:
        assert label in src
    assert src.index('Risk Register') < src.index('Ship Register')

def test_project_overview_removes_workflow_snapshot_and_recent_activity():
    src = Path('components/project_workspace_v40.py').read_text()
    overview = src[src.index('def _overview'):src.index('def _info')]
    assert 'Workflow Snapshot' not in overview
    assert 'Recent Activities' not in overview

def test_role_cockpit_removes_workflow_snapshot_and_recent_activity():
    src = Path('components/role_cockpits_v40.py').read_text()
    assert "_panel('Workflow Snapshot'" not in src
    assert "_panel('Recent Activities'" not in src

def test_app_uses_v39_project_workspace_and_cockpit():
    src = Path('app.py').read_text()
    assert 'project_workspace_v40' in src
    assert 'role_cockpits_v40' in src
