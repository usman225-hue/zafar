from pathlib import Path


def test_project_navigation_contains_required_sections():
    src = Path("components/project_workspace_v40.py").read_text()
    for label in ["Plan Appraisal", "NSC Survey", "In-Service Survey", "Survey Status", "Risk Register", "Ship Register", "Certification", "Documents", "Notifications", "Audit Trail"]:
        assert label in src


def test_project_navigation_is_phase_aware():
    src = Path("components/project_workspace_v40.py").read_text()
    assert '"plan_appraisal" not in phases' in src
    assert '"nsc_survey" not in phases' in src
    assert '"in_service" not in phases' in src


def test_app_uses_v38_project_workspace():
    src = Path("app.py").read_text()
    assert "project_workspace_v40" in src
