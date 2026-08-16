from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_v34_version():
    assert (ROOT / "VERSION").read_text().strip().startswith(('3.','4.'))

def test_cache_key_factory_present():
    text = (ROOT / "utils" / "session_cache.py").read_text()
    assert "def make_key" in text
    assert 'CACHE_VERSION = "v34"' in text

def test_upload_materialized_once():
    text = (ROOT / "database" / "production_queries.py").read_text()
    assert "materialize_upload" in text
    assert "submit_survey_report_v34" in text

def test_certificate_upload_helper_present():
    text = (ROOT / "database" / "production_queries.py").read_text()
    assert "upload_certificate_pdf_v34" in text

def test_role_ux_sections_present():
    for name, markers in {
        "gm_production.py": ["Needs My Decision"],
        "dm_production.py": ["Assignments", "Survey due"],
        "role_workspaces.py": ["Survey Start Readiness", "Revision history", "In-Service Fleet Snapshot", "NSC Fleet / Project Snapshot", "Technical Review Package"],
        "survey_lifecycle_v34.py": ["v3.4"],
    }.items():
        text = (ROOT / "components" / name).read_text()
        for marker in markers:
            assert marker in text
