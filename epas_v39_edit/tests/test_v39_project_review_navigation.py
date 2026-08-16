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


def test_project_summary_appears_before_project_overview():
    src = Path('components/project_workspace_v40.py').read_text()
    assert '### Project Summary' in src
    assert src.index('### Project Summary') < src.index('### Project Overview')
    assert src.count('### Project Summary') == 1


def test_app_uses_v39_project_workspace_and_cockpit():
    src = Path('app.py').read_text()
    assert 'project_workspace_v40' in src
    assert 'role_cockpits_v40' in src


def test_dashboard_removed_global_search_and_guidance():
    app = Path('app.py').read_text()
    cockpit = Path('components/role_cockpits_v40.py').read_text()
    assert '### Next-action guidance' not in app
    assert 'Authorized global search' not in cockpit
    assert 'Project Health Overview' not in cockpit
    assert 'Priority Queue' not in cockpit
    assert 'Next Actions' not in cockpit


def test_project_tab_contains_direct_project_search_and_navigation():
    src = Path('components/project_workspace_v40.py').read_text()
    assert 'Search project' in src
    assert 'Open Project →' in src
    assert 'project_nav_key' in src
