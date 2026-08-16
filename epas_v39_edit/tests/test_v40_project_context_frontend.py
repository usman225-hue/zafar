from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "app.py").read_text(encoding="utf-8")
PW = (ROOT / "components" / "project_workspace_v40.py").read_text(encoding="utf-8")
GM = (ROOT / "components" / "gm_production.py").read_text(encoding="utf-8")

def test_active_app_uses_project_v40_workspace():
    assert "project_workspace_v40" in APP
    assert "role_cockpits_v40" in APP

def test_project_navigation_contains_required_items():
    for item in ["Project Overview", "Plan Appraisal", "NSC Survey", "In-Service Survey", "Survey Status", "Risk Register", "Ship Register", "Certification", "Documents", "Notifications", "Audit Trail"]:
        assert item in PW

def test_overview_has_no_workflow_snapshot_or_recent_activity():
    overview = PW[PW.index("def _overview"):PW.index("def _project_panel_open")]
    assert "WORKFLOW SNAPSHOT" not in overview
    assert "RECENT ACTIVITY" not in overview

def test_create_project_only_exposed_in_projects_register():
    assert 'role == "gm"' in PW
    assert 'from components.gm_production import render_create_project' in PW
    gm_render = GM[GM.index('def render()'):GM.index('def render_create_project') if 'def render_create_project' in GM else GM.index('def _create_project')]
    assert '"Create Project"' not in gm_render

def test_ship_register_before_certification():
    ship_idx = PW.index('("Ship Register", "ship_register"')
    cert_idx = PW.index('("Certification", "certification"')
    assert ship_idx < cert_idx


def test_create_project_form_exposes_unique_widget_keys():
    GM = (ROOT / "components" / "gm_production.py").read_text(encoding="utf-8")
    for key in [
        "gm_owner_company",
        "gm_designer_company",
        "gm_shipyard_company",
        "gm_shipmgmt_company",
    ]:
        assert key in GM


def test_workspace_navigation_is_rendered_in_sidebar():
    APP = (ROOT / "app.py").read_text(encoding="utf-8")
    assert "with st.sidebar:" in APP
    assert "selected_label = st.radio(" in APP
