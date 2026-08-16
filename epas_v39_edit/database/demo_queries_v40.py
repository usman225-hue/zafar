"""Read/write adapter for EPAS demo mode.

It exposes the same callable names used by the active production query layer,
but serves a realistic in-memory dataset so the Streamlit UI works publicly
on port 8501 without Supabase.
"""
from __future__ import annotations
from datetime import date, datetime, timedelta
from typing import Any
from config import demo_runtime


def _db():
    return demo_runtime._db()

def _uid():
    u = demo_runtime.current_user()
    return u.get("id") if u else None

def _profile_by_id(uid):
    return next((x for x in _db()["profiles"] if x.get("id") == uid), None)

def _project(project_id):
    return next((x for x in _db()["projects"] if x.get("id") == project_id), None)

def _vessel(project_id):
    return next((x for x in _db()["vessels"] if x.get("project_id") == project_id), None)

def _rfis(project_id=None):
    rows = _db()["rfis"]
    return [r for r in rows if project_id is None or r.get("project_id") == project_id]

def _obs(rfi_id=None, project_id=None):
    rows = _db()["observations"]
    if rfi_id:
        return [o for o in rows if o.get("rfi_id") == rfi_id]
    if project_id:
        ids = {r["id"] for r in _rfis(project_id)}
        return [o for o in rows if o.get("rfi_id") in ids]
    return rows

def _certs(project_id=None):
    rows = _db()["certificates"]
    return [c for c in rows if project_id is None or c.get("project_id") == project_id]

def _projects_for_user():
    user = demo_runtime.current_user() or {}
    role = user.get("role")
    uid = user.get("id")
    if role == "gm":
        return _db()["projects"]
    members = {x["project_id"] for x in _db()["team_assignments"] if x.get("user_id") == uid and x.get("role") == role}
    stakeholder = {x["project_id"] for x in _db()["stakeholders"] if x.get("contact_email") == user.get("email")}
    allowed = members | stakeholder
    # Preserve useful demo coverage for stakeholder roles.
    if not allowed and role in {"owner", "ship_management", "shipyard", "designer"}:
        st = next((x for x in _db()["stakeholders"] if x.get("stakeholder_type") == role), None)
        if st: allowed.add(st["project_id"])
    return [p for p in _db()["projects"] if p.get("id") in allowed]

def _tasks():
    role = (demo_runtime.current_user() or {}).get("role")
    projects = {p["id"] for p in _projects_for_user()}
    out=[]
    for r in _rfis():
        if r.get("project_id") not in projects: continue
        out.append({"id": r["id"], "project_id": r["project_id"], "task_type": "survey_rfi", "status": r.get("status"), "to_user_id": _uid(), "entity_id": r["id"], "note": r.get("survey_type"), "due_at": str(r.get("scheduled_date") or r.get("requested_date") or ""), "priority": r.get("priority","medium"), "created_at": str(r.get("created_at","")), "updated_at": str(r.get("created_at",""))})
    return out

def _project_health(pid):
    r = _rfis(pid); o = _obs(project_id=pid); c = _certs(pid)
    completed = sum(1 for x in r if x.get("status") in {"certificate_issued","closed"})
    pct = int(round((completed / max(len(r),1))*100))
    overdue = sum(1 for x in r if x.get("scheduled_date") and x.get("status") not in {"certificate_issued","closed"} and str(x.get("scheduled_date")) < str(date.today()))
    open_obs = sum(1 for x in o if x.get("status") == "open")
    phase = "In-Service Active" if any(str(p).endswith("in_service") for p in (_project(pid) or {}).get("phases", [])) else "Plan / NSC"
    cycle = 1 + sum(1 for x in r if x.get("phase") == "in_service" and x.get("status") in {"certificate_issued","closed"})
    future_dates = []
    for x in r:
        d = x.get("scheduled_date")
        if d:
            try:
                d_obj = d if isinstance(d, date) else date.fromisoformat(str(d))
                if d_obj >= date.today():
                    future_dates.append(d_obj)
            except Exception:
                continue
    next_due = min(future_dates).isoformat() if future_dates else ""
    return {"completion_pct": pct, "overdue_tasks": overdue, "open_observations": open_obs, "open_escalations": 0, "health_status": "Healthy" if pct >= 60 else "Watch", "current_phase": phase, "current_cycle": f"Cycle {cycle}", "next_survey_due": next_due, "certificate_count": len(c)}

def _demo_read(name, *args, **kwargs):
    project_id = kwargs.get("project_id") or (args[0] if args and isinstance(args[0], str) and args[0] in {p["id"] for p in _db()["projects"]} else None)
    if name == "profile": return demo_runtime.current_user()
    if name == "users": return _db()["profiles"] if kwargs.get("role") is None else [x for x in _db()["profiles"] if x.get("role") == kwargs.get("role")]
    if name in {"projects", "authorized_projects_v36"}: return _projects_for_user()
    if name == "project": return _project(args[0])
    if name in {"vessel", "get_vessel_for_project"}: return _vessel(args[0])
    if name in {"members"}: return [x for x in _db()["team_assignments"] if x.get("project_id") == args[0]]
    if name in {"stakeholders"}: return [x for x in _db()["stakeholders"] if x.get("project_id") == args[0]]
    if name in {"rfis", "list_rfis"}: return _rfis(project_id)
    if name == "rfi": return next((x for x in _rfis() if x.get("id") == args[0]), None)
    if name in {"observations", "observations_for_project", "open_observations"}: return _obs(rfi_id=args[0] if name=="observations" and args else None, project_id=project_id if name!="observations" else None)
    if name in {"certificates", "list_certificates"}: return _certs(project_id)
    if name in {"ship_register_project", "ship_register_rows"}: return [_vessel(project_id)] if _vessel(project_id) else []
    if name in {"tasks", "all_project_tasks", "my_work_queue"}: return _tasks()
    if name in {"notifications"}: return []
    if name in {"metrics", "role_dashboard_summary", "role_dashboard_summary_v36"}:
        ps = _projects_for_user(); return {"active_projects": len(ps), "open_observations": sum(_project_health(p["id"])["open_observations"] for p in ps), "survey_due": sum(1 for p in ps if _project_health(p["id"])["next_survey_due"]), "overdue_tasks": sum(_project_health(p["id"])["overdue_tasks"] for p in ps), "certificates": sum(_project_health(p["id"])["certificate_count"] for p in ps)}
    if name in {"role_dashboard_detail", "project_health", "project_health_v15", "project_health_v36"}: return _project_health(args[0]) if args else {}
    if name in {"dashboard_project_health_bundle"}:
        pids = args[0] if args else []
        return {pid:_project_health(pid) for pid in pids}
    if name in {"project_phase_status", "project_phase_workflow_v36"}: return [{"phase": ph, "status": "completed" if ph=="plan_appraisal" else ("in_progress" if ph=="in_service" else "completed")} for ph in (_project(project_id) or {}).get("phases", [])]
    if name in {"stakeholder_fleet_bundle_v36", "stakeholder_fleet_summary"}:
        return [{"project_id":p["id"],"project_code":p.get("project_code"),"vessel":(_vessel(p["id"]) or {}).get("name"),"health":_project_health(p["id"])} for p in _projects_for_user()]
    if name in {"owner_fleet_bundle_v36", "ship_management_bundle_v36", "shipyard_nsc_bundle_v36"}: return {"projects": _projects_for_user(), "vessels": [_vessel(p["id"]) for p in _projects_for_user() if _vessel(p["id"])], "metrics": _demo_read("metrics")}
    if name in {"schedule_bundle_v36", "survey_control_tower", "survey_schedule_queue", "v36_lifecycle_cases", "project_timeline", "project_timeline_v35", "project_timeline_v36", "coordination_timeline_v36"}: return []
    if name in {"plan_drawings", "plan_drawings_by_ids", "plan_observations", "plan_observations_by_drawing_ids", "plan_revisions", "surveyor_plan_verification_queue", "survey_checklist", "survey_reports", "corrective_actions", "escalations", "milestones", "project_milestones", "risks", "decisions", "governance_register", "audit_events", "document_releases", "released_documents", "document_access_log", "list_documents", "designer_submission_queue", "ship_management_action_queue"}: return []
    if name in {"resource_workload", "resource_allocation_matrix", "sla_dashboard", "task_sla_snapshot", "security_preflight"}: return [] if name not in {"sla_dashboard"} else {"on_track":12,"due_soon":4,"overdue":2}
    if name == "global_search_v36": return []
    if name in {"vessel", "get_vessel_for_project"}: return _vessel(args[0])
    return []

def _demo_write(name, *args, **kwargs):
    if name == "create_project":
        payload = kwargs.get("payload") or (args[0] if args else {})
        new = {"id": f"demo-{len(_db()['projects'])+1}", "project_code": payload.get("project_code", f"DEMO-{len(_db()['projects'])+1:03d}"), "name": payload.get("name","Demo Project"), "vessel_type": payload.get("vessel_type","Vessel"), "flag_state": payload.get("flag_state","Pakistan"), "phases": payload.get("phases", ["plan_appraisal","nsc_survey","in_service"]), "status":"active", "created_at":datetime.now().isoformat()}
        _db()["projects"].append(new)
        for entry in payload.get("team", []) or []:
            _db()["team_assignments"].append({
                "id": f"demo-team-{len(_db()['team_assignments'])+1}",
                "project_id": new["id"],
                "user_id": entry.get("user_id"),
                "role": entry.get("role"),
                "discipline": entry.get("discipline") or "",
                "department": entry.get("department"),
                "phase": entry.get("phase"),
                "assigned_at": datetime.now().isoformat(),
            })
        for entry in payload.get("stakeholders", []) or []:
            _db()["stakeholders"].append({
                "id": f"demo-stakeholder-{len(_db()['stakeholders'])+1}",
                "project_id": new["id"],
                "company_name": entry.get("company_name") or "New Stakeholder",
                "contact_name": entry.get("contact_name") or "",
                "contact_email": entry.get("contact_email") or "",
                "stakeholder_type": entry.get("stakeholder_type") or "owner",
                "user_id": entry.get("user_id"),
                "status": "active",
                "added_at": datetime.now().isoformat(),
            })
        return {"project": new, "ok": True, "demo": True, "message": "Demo project created in memory."}
    return {"ok": True, "demo": True, "message": f"Demo action '{name}' completed in memory."}

def dispatch(name, *args, **kwargs):
    if name in {"create_project","stakeholder_create_rfi","dm_assign_engineer_v36","dm_assign_surveyor_v36","gm_decide_rfi","gm_handover_rfi","gm_plan_decision","gm_amended_design_decision","dm_review_plan","dm_forward_survey","dm_verify_corrective","dm_issue_corrective","assignee_submit_corrective_v36","designer_submit_initial_drawing","designer_submit_revision","engineer_submit_review_v36","engineer_register_appraisal_artifact","surveyor_verify_plan_appraisal","start_survey_execution_v36","submit_survey_report_v36","set_in_service_schedule_basis_v36","secure_accept_task","secure_start_task","secure_complete_task","complete_milestone","release_milestone","release_document","withdraw_document_release","close_project","issue_certificate","finalize_interim_certificate","create_scheduled_in_service_rfi","mark_all_notifications_read","mark_notification_read","refresh_task_sla","upload_certificate_pdf_v36","register_project_document","project_document_signed_url","certificate_pdf_signed_url","gm_add_risk","gm_record_decision","gm_escalation_decide_v36","dm_escalate","complete_survey_checklist_item","acknowledge_survey_scope","acknowledge_survey_drawing_package_v36","confirm_survey_execution_declaration","surveyor_accept_assignment_v36"}:
        return _demo_write(name,*args,**kwargs)
    return _demo_read(name,*args,**kwargs)
