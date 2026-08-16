from pathlib import Path
import py_compile

ROOT = Path(__file__).resolve().parents[1]

def test_project_workspace_module_compiles():
    py_compile.compile(str(ROOT / "components" / "project_workspace_v38.py"), doraise=True)

def test_project_workspace_role_navigation_exists():
    s = (ROOT / "components" / "project_workspace_v38.py").read_text(encoding="utf-8")
    for role in ["gm", "dm", "engineer", "surveyor", "designer", "ship_management", "owner", "shipyard"]:
        assert f'"{role}"' in s
    assert "PROJECT_NAV" in s
    assert "selected_project_id" in s

def test_app_routes_to_project_workspace():
    s = (ROOT / "app.py").read_text(encoding="utf-8")
    assert "selected_project_id" in s
    assert "render_project_workspace" in s
    assert "render_project_launcher" in s

def test_project_workspace_css_is_loaded():
    s = (ROOT / "styles" / "theme.py").read_text(encoding="utf-8")
    assert "PSB_V362_PROJECT_CSS" in s
    assert ".psb-project-header" in s
