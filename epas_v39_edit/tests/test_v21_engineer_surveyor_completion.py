from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v2_1_engineer_surveyor_completion.sql').read_text()
UI = (ROOT / 'components' / 'role_workspaces.py').read_text()
PQ = (ROOT / 'database' / 'production_queries.py').read_text()


def test_v21_migration_exists_and_has_controlled_artifacts():
    assert 'create table if not exists plan_appraisal_artifacts' in SQL
    assert "MARKED_UP_DRAWING" in SQL
    assert "APPRAISAL_REPORT" in SQL
    assert "p_mime_type <> 'application/pdf'" in SQL
    assert 'p_sha256' in SQL


def test_engineer_decision_taxonomy_is_explicit():
    for value in ('APPROVED','APPROVED_AS_AMENDED','INFORMATION','REJECTED'):
        assert value in SQL
    assert 'epas_engineer_submit_review_v21' in SQL
    assert 'engineer_decision' in SQL


def test_engineer_surveyor_branch_is_server_controlled():
    assert 'p_needs_surveyor_verification' in SQL
    assert "PLAN_APPRAISAL_SURVEYOR_VERIFICATION" in SQL
    assert 'surveyor_verification_status' in SQL
    assert 'epas_surveyor_verify_plan_appraisal' in SQL
    assert "NOT_VERIFIED" in SQL


def test_surveyor_branch_is_first_class_in_ui():
    assert 'Survey branch: NSC (Newbuilding / New Ship in Class)' in UI
    assert 'Survey branch: In-Service' in UI
    assert "phase=='nsc_survey'" in UI
    assert "phase=='in_service'" in UI


def test_engineer_ui_has_both_artifacts_and_four_decisions():
    assert 'Marked-up drawing (PDF)' in UI
    assert 'Technical appraisal report (PDF)' in UI
    for value in ('APPROVED','APPROVED_AS_AMENDED','INFORMATION','REJECTED'):
        assert value in UI
    assert 'Require Surveyor verification before Manager review' in UI


def test_service_layer_exposes_v21_operations():
    assert 'engineer_submit_review_v21' in PQ
    assert 'engineer_register_appraisal_artifact' in PQ
    assert 'surveyor_plan_verification_queue' in PQ
    assert 'surveyor_verify_plan_appraisal' in PQ
