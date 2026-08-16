from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIG = (ROOT / "database" / "production_v1_5_1_security_and_release.sql").read_text()

def test_legacy_direct_write_policies_are_removed():
    for name in (
        "tasks_insert_actor",
        "tasks_update_recipient",
        "notifications_insert_authenticated",
        "documents_insert_gm",
    ):
        assert f"drop policy if exists {name}" in MIG

def test_rpc_only_mutation_is_enforced():
    for table in (
        "workflow_tasks", "plan_drawings", "plan_appraisal_observations",
        "document_revisions", "documents", "rfis", "observations",
        "certificates", "corrective_actions", "workflow_escalations",
    ):
        assert table in MIG
    assert "revoke insert,update,delete on projects,project_milestones,rfis,observations,certificates" in MIG

def test_stakeholder_release_controls_exist():
    assert "stakeholder_visible" in MIG
    assert "epas_release_milestone" in MIG
    assert "epas_release_milestone" in MIG
    assert "epas_certificate_pdf_path" in MIG

def test_role_guarded_internal_endpoints_exist():
    assert "Only GM/DM may evaluate resource eligibility" in MIG
    assert "Only GM/DM may view internal project health" in MIG
    assert "Only GM may view closure checklist" in MIG

def test_legacy_rpc_overloads_are_revoked():
    assert "revoke execute on function epas_submit_survey_report(uuid,text,jsonb)" in MIG
    assert "revoke execute on function epas_assignee_submit_corrective(uuid,text)" in MIG
    assert "revoke execute on function epas_designer_submit_revision(uuid,text,text,text)" in MIG
