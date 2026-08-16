from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "database" / "production_v1_5.sql").read_text()
PQ = (ROOT / "database" / "production_queries.py").read_text()
APP = (ROOT / "app.py").read_text()

def test_v15_critical_workflow_functions():
    required = [
        "epas_release_document",
        "epas_withdraw_document_release",
        "epas_finalize_interim_certificate",
        "epas_project_closure_check",
        "epas_close_project",
        "epas_gm_escalation_decide",
        "epas_project_health_v15",
        "epas_project_eligible_resources_v15",
        "epas_dm_assign_engineer_v15",
        "epas_dm_assign_surveyor_v15",
        "epas_submit_survey_report",
        "epas_clear_survey_observation",
        "epas_designer_submit_revision",
        "epas_designer_submit_initial_drawing_v15",
        "epas_assignee_submit_corrective",
        "epas_register_certificate_pdf_v15",
        "epas_run_sla_monitor_v15",
    ]
    for name in required:
        assert re.search(rf"create (?:or replace )?function\s+{name}\b", SQL, re.I), name

def test_v15_browser_write_lockdown():
    v14 = (ROOT / "database" / "production_v1_4.sql").read_text()
    combined = v14 + "\n" + SQL
    statements = re.findall(r"revoke\s+insert\s*,\s*update\s*,\s*delete\s+on\s+([^;]+)\s+from", combined, re.I)
    revoked = set()
    for stmt in statements:
        revoked.update(x.strip() for x in stmt.split(","))
    for table in [
        "workflow_tasks", "plan_drawings", "plan_appraisal_observations",
        "document_revisions", "notifications", "documents", "rfis",
        "observations", "corrective_actions", "workflow_escalations",
        "project_milestones", "certificates", "project_risks", "project_decisions",
        "document_releases", "document_access_audit", "notification_outbox",
        "certificate_lifecycle_events", "project_closure_checks", "project_archives",
    ]:
        assert table in revoked, table

def test_v15_real_role_portals_and_governance_ui():
    for marker in [
        "render_engineer", "render_surveyor", "render_designer",
        "render_ship_management", "render_readonly_stakeholder"
    ]:
        assert marker in APP
    gov = (ROOT / "components" / "governance_v15.py").read_text()
    assert "render_gm" in gov and "render_dm" in gov
    assert "Controlled stakeholder release" in gov
    assert "Project closure checklist" in gov

def test_v15_query_layer_has_all_role_workspace_calls():
    sources = []
    for rel in [
        "components/gm_production.py","components/dm_production.py",
        "components/role_workspaces.py","components/governance_v15.py"
    ]:
        sources.append((ROOT / rel).read_text())
    uses = sorted(set(re.findall(r"pq\.([A-Za-z0-9_]+)", "\n".join(sources))))
    defs = set(re.findall(r"^def\s+([A-Za-z0-9_]+)\(", PQ, re.M))
    missing = [u for u in uses if u not in defs]
    assert not missing, missing

def test_v15_flow_documentation_exists():
    for rel in [
        "docs/GM_DM_PRODUCTION_V1_5_WORKFLOW.mmd",
        "docs/CRITICAL_GAP_CLOSURE_V1_5.md",
        "docs/V1_5_DEPLOYMENT_RUNBOOK.md",
    ]:
        assert (ROOT / rel).exists(), rel
