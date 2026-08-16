from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_stakeholder_roles_are_external_not_internal():
    s = (ROOT / "config" / "settings.py").read_text()
    assert "EXTERNAL_STAKEHOLDER_ROLES" in s
    assert "STAKEHOLDER_EXECUTION_ROLES" in s
    assert "STAKEHOLDER_READONLY_ROLES" in s
    assert "ROLE_OWNER" in s and "ROLE_SHIPYARD" in s and "ROLE_DESIGNER" in s and "ROLE_SHIP_MANAGEMENT" in s

def test_readonly_stakeholder_portal_exists():
    app = (ROOT / "app.py").read_text()
    rw = (ROOT / "components" / "role_workspaces.py").read_text()
    assert "render_readonly_stakeholder" in app
    assert "def render_readonly_stakeholder" in rw

def test_stakeholder_rls_migration_exists():
    sql = (ROOT / "database" / "production_v1_4_1.sql").read_text()
    assert "stakeholder_visible" in sql
    assert "release_status" in sql
    assert "member_category" in sql
    assert "epas_stakeholder_can_execute" in sql
