"""Production-only EPAS data/service layer.

All GM/DM state changes go through authenticated Supabase RPCs. Reads are
filtered by RLS. There is deliberately no in-memory fallback and no actor
selector in this layer.
"""
from __future__ import annotations
from datetime import date, datetime, timedelta
from typing import Any

from config.supabase_client import get_client
from utils.session_cache import cached_call, clear as clear_read_cache, clear_prefixes as clear_cache_prefixes, make_key
from utils.file_validation import validate_uploaded_file, validated_upload_metadata, materialize_upload, MAX_PDF_BYTES, MAX_IMAGE_BYTES
from utils.file_security import scan_bytes


def _db():
    client = get_client()
    if client is None:
        raise RuntimeError("Supabase is not configured. Production EPAS requires SUPABASE_URL and SUPABASE_ANON_KEY.")
    return client


def _rpc(name: str, params: dict, invalidate_prefixes: list[str] | None = None) -> Any:
    """Execute a state-changing RPC and invalidate only the affected read-cache domains when known."""
    result = _db().rpc(name, params).execute()
    if invalidate_prefixes:
        clear_cache_prefixes(invalidate_prefixes)
    else:
        clear_read_cache()
    return result.data


def _rpc_read(name: str, params: dict) -> Any:
    """Read-only RPC; safe to cache in the current Streamlit session."""
    return _db().rpc(name, params).execute().data


def _cached(key: str, fn, ttl: float = 8.0):
    return cached_call(key, fn, ttl)


def upload_with_cleanup(bucket: str, path: str, content: bytes, mime: str, register_fn):
    """Upload once; delete the object if authoritative registration fails."""
    storage = _db().storage.from_(bucket)
    storage.upload(path, content, {"content-type": mime, "upsert": "false"})
    try:
        return register_fn()
    except Exception:
        try:
            storage.remove([path])
        except Exception:
            pass
        raise


_upload_with_cleanup = upload_with_cleanup

def _validated_bytes(uploaded_file, allowed: set[str], max_bytes: int):
    validated = materialize_upload(uploaded_file, allowed, max_bytes)
    safe, scan_message = scan_bytes(validated.content)
    if not safe:
        raise ValueError(scan_message)
    meta = {
        'file_name': validated.file_name,
        'mime_type': validated.mime_type,
        'size_bytes': validated.size_bytes,
        'sha256': validated.sha256,
        'malware_scan': scan_message,
    }
    return validated.content, meta


def profile() -> dict:
    user = _db().auth.get_user().user
    if not user:
        raise RuntimeError("Not authenticated")
    key = make_key("profile", user.id)
    def _load():
        rows = _db().table("profiles").select("id,full_name,email,role,active").eq("id", user.id).limit(1).execute().data
        if not rows:
            raise RuntimeError("Authenticated account has no EPAS profile")
        return rows[0]
    return _cached(key, _load, 15.0)


def users(role: str | None = None) -> list[dict]:
    key = make_key("users", role or "all")
    return _cached(key, lambda: _db().table("profiles").select("id,full_name,email,role,active").eq("role", role).order("full_name").execute().data if role else _db().table("profiles").select("id,full_name,email,role,active").order("full_name").execute().data, 20.0)


def projects(status: str | None = None) -> list[dict]:
    key = make_key("projects", status or "all")
    def _load():
        q = _db().table("projects").select("id,project_code,name,status,phases,created_at,updated_at").order("created_at", desc=True)
        if status and status != "all":
            q = q.eq("status", status)
        return q.execute().data
    return _cached(key, _load, 10.0)


def project(project_id: str) -> dict | None:
    return _cached(make_key("project", project_id), lambda: (_db().table("projects").select("id,project_code,name,status,phases,created_at,updated_at").eq("id", project_id).limit(1).execute().data or [None])[0], 10.0)


def vessel(project_id: str) -> dict | None:
    return _cached(make_key("vessel", project_id), lambda: (_db().table("vessels").select("id,project_id,name,imo_number,class_status,survey_status,next_survey_due,last_survey_date,last_survey_phase").eq("project_id", project_id).limit(1).execute().data or [None])[0], 10.0)


def members(project_id: str) -> list[dict]:
    return _cached(make_key("members", project_id), lambda: _db().table("project_members").select("id,project_id,user_id,role,active,profiles:user_id(id,full_name,email,role)").eq("project_id", project_id).eq("active", True).execute().data, 15.0)


def stakeholders(project_id: str) -> list[dict]:
    return _cached(make_key("stakeholders", project_id), lambda: _db().table("stakeholders").select("id,project_id,name,role,email,status").eq("project_id", project_id).execute().data, 20.0)


def create_project(payload: dict) -> dict:
    return _rpc("epas_create_project", {"p_payload": payload})


def eligible(role: str, discipline: str, work_date: date | None = None) -> list[dict]:
    data = _rpc("epas_eligible_resources", {"p_role": role, "p_discipline": discipline, "p_work_date": (work_date or date.today()).isoformat()})
    return data or []


def notifications(unread_only: bool = False, limit: int = 100) -> list[dict]:
    uid = profile()["id"]
    key = make_key("notifications", uid, unread_only, limit)
    def _load():
        q = _db().table("notifications").select("id,event_type,title,message,priority,created_at,read_at,entity_type,entity_id").eq("user_id", uid).order("created_at", desc=True).limit(limit)
        if unread_only:
            q = q.is_("read_at", "null")
        return q.execute().data
    return _cached(key, _load, 5.0)




def tasks(statuses: list[str] | None = None, task_types: list[str] | None = None) -> list[dict]:
    uid = profile()["id"]
    status_key = ','.join(statuses or [])
    type_key = ','.join(task_types or [])
    key = make_key("tasks", uid, status_key, type_key)
    def _load():
        q = _db().table("workflow_tasks").select("id,project_id,task_type,status,to_user_id,entity_id,note,due_at,priority,created_at,updated_at").eq("to_user_id", uid).order("created_at", desc=True)
        if statuses:
            q = q.in_("status", statuses)
        if task_types:
            q = q.in_("task_type", task_types)
        return q.execute().data
    return _cached(key, _load, 5.0)


def all_project_tasks(project_id: str) -> list[dict]:
    return _db().table("workflow_tasks").select("id,project_id,task_type,status,to_user_id,entity_id,note,due_at,priority,created_at,updated_at").eq("project_id", project_id).order("created_at", desc=True).execute().data


def accept_task(task_id: str) -> dict:
    return _rpc("epas_accept_task", {"p_task_id": task_id})


def start_task(task_id: str) -> dict:
    return _rpc("epas_start_task", {"p_task_id": task_id})


def complete_task(task_id: str, note: str = "") -> dict:
    return _rpc("epas_complete_task", {"p_task_id": task_id, "p_note": note})


def gm_handover_rfi(rfi_id: str, dm_id: str) -> dict:
    return _rpc("epas_gm_handover_rfi", {"p_rfi_id": rfi_id, "p_dm_id": dm_id})


def gm_decide_rfi(rfi_id: str, decision: str, note: str) -> dict:
    return _rpc("epas_gm_decide_rfi", {"p_rfi_id": rfi_id, "p_decision": decision, "p_note": note})


def gm_assign_plan_manager(drawing_id: str, manager_id: str) -> dict:
    return _rpc("epas_gm_assign_plan_manager", {"p_drawing_id": drawing_id, "p_manager_id": manager_id})


def gm_plan_decision(drawing_id: str, decision: str, note: str) -> dict:
    return _rpc("epas_gm_plan_decision", {"p_drawing_id": drawing_id, "p_decision": decision, "p_note": note})


def dm_assign_engineer(drawing_id: str, engineer_id: str) -> dict:
    return _rpc("epas_dm_assign_engineer", {"p_drawing_id": drawing_id, "p_engineer_id": engineer_id})


def dm_review_plan(drawing_id: str, decision: str, note: str) -> dict:
    return _rpc("epas_dm_review_plan", {"p_drawing_id": drawing_id, "p_decision": decision, "p_note": note})


def dm_assign_surveyor(rfi_id: str, surveyor_id: str, scheduled_date: date) -> dict:
    return _rpc("epas_dm_assign_surveyor", {"p_rfi_id": rfi_id, "p_surveyor_id": surveyor_id, "p_scheduled_date": scheduled_date.isoformat()})


def dm_forward_survey(rfi_id: str, remarks: str) -> dict:
    return _rpc("epas_dm_forward_survey", {"p_rfi_id": rfi_id, "p_remarks": remarks})


def dm_complete_corrective(action_id: str, instruction: str) -> dict:
    return _rpc("epas_dm_complete_corrective", {"p_action_id": action_id, "p_instruction": instruction})


def dm_escalate(project_id: str, entity_type: str, entity_id: str, reason: str, recommendation: str, severity: str) -> dict:
    return _rpc("epas_dm_escalate", {"p_project_id": project_id, "p_entity_type": entity_type, "p_entity_id": entity_id, "p_reason": reason, "p_recommendation": recommendation, "p_severity": severity})


def plan_drawings(project_id: str | None = None) -> list[dict]:
    key = f"plan_drawings:{project_id or 'all'}"
    def _load():
        q = _db().table("plan_drawings").select("id,project_id,drawing_no,title,discipline,status,current_revision,updated_at,engineer_id,manager_id").order("updated_at", desc=True)
        if project_id:
            q = q.eq("project_id", project_id)
        return q.execute().data
    return _cached(key, _load, 10.0)


def plan_drawing(drawing_id: str) -> dict | None:
    return _cached(f"plan_drawing:{drawing_id}", lambda: (_db().table("plan_drawings").select("id,project_id,drawing_no,title,discipline,status,current_revision,updated_at,engineer_id,manager_id,designer_id,current_file_name").eq("id", drawing_id).limit(1).execute().data or [None])[0], 8.0)


def plan_observations(drawing_id: str, open_only: bool = False) -> list[dict]:
    def _load():
        q = _db().table("plan_appraisal_observations").select("id,drawing_id,obs_code,description,severity,status,raised_at,response,responded_at").eq("drawing_id", drawing_id).order("raised_at", desc=True)
        if open_only:
            q = q.eq("status", "open")
        return q.execute().data
    return _cached(f"plan_observations:{drawing_id}:{open_only}", _load, 8.0)


def plan_revisions(drawing_id: str) -> list[dict]:
    return _cached(f"plan_revisions:{drawing_id}", lambda: _db().table("plan_revisions").select("id,drawing_id,revision_no,status,file_name,storage_path,sha256,created_at,submitted_by").eq("drawing_id", drawing_id).order("revision_no", desc=True).execute().data, 10.0)


def rfis(status: str | None = None, project_id: str | None = None, assigned_to_me: bool = False) -> list[dict]:
    uid = profile()["id"] if assigned_to_me else ''
    key = f"rfis:{status or 'all'}:{project_id or 'all'}:{uid}"
    def _load():
        q = _db().table("rfis").select("id,rfi_code,project_id,vessel_id,phase,survey_type,status,requested_date,requested_by,assigned_dm_id,assigned_surveyor_id,updated_at,scope_note,priority").order("updated_at", desc=True)
        if status:
            q = q.eq("status", status)
        if project_id:
            q = q.eq("project_id", project_id)
        if assigned_to_me:
            q = q.eq("assigned_dm_id", uid)
        return q.execute().data
    return _cached(key, _load, 8.0)


def rfi(rfi_id: str) -> dict | None:
    return _cached(f"rfi:{rfi_id}", lambda: (_db().table("rfis").select("id,rfi_code,project_id,vessel_id,phase,survey_type,status,requested_date,requested_by,assigned_dm_id,assigned_surveyor_id,updated_at,scope_note,priority").eq("id", rfi_id).limit(1).execute().data or [None])[0], 5.0)


def stakeholder_create_rfi(project_id: str, vessel_id: str, phase: str, survey_type: str, requested_date: date, priority: str, scope_note: str) -> dict:
    return _rpc("epas_stakeholder_create_rfi", {
        "p_project_id": project_id, "p_vessel_id": vessel_id, "p_phase": phase,
        "p_survey_type": survey_type, "p_requested_date": requested_date.isoformat(),
        "p_priority": priority, "p_scope_note": scope_note,
    })


def stakeholder_rfi_status(rfi_id: str) -> dict:
    return _rpc("epas_stakeholder_rfi_status", {"p_rfi_id": rfi_id})


def observations(rfi_id: str) -> list[dict]:
    return _cached(f"observations:{rfi_id}", lambda: _db().table("observations").select("id,rfi_id,obs_code,description,status,severity,location,rule_reference,raised_at,corrective_action_id").eq("rfi_id", rfi_id).order("raised_at", desc=True).execute().data, 5.0)


def survey_reports(rfi_id: str) -> list[dict]:
    return _cached(f"survey_reports:{rfi_id}", lambda: _db().table("survey_reports").select("id,rfi_id,status,report_file_name,report_storage_path,report_sha256,report_size_bytes,report_mime_type,submitted_at,survey_date,location,attendance").eq("rfi_id", rfi_id).order("submitted_at", desc=True).execute().data, 6.0)


def corrective_actions(project_id: str | None = None, rfi_id: str | None = None) -> list[dict]:
    def _load():
        q = _db().table("corrective_actions").select("id,project_id,rfi_id,action_code,instruction,status,assignee_id,due_at,created_at,updated_at").order("created_at", desc=True)
        if project_id:
            q = q.eq("project_id", project_id)
        if rfi_id:
            q = q.eq("rfi_id", rfi_id)
        return q.execute().data
    return _cached(f"corrective_actions:{project_id or 'all'}:{rfi_id or 'all'}", _load, 5.0)


def escalations(project_id: str | None = None, open_only: bool = True) -> list[dict]:
    q = _db().table("workflow_escalations").select("id,project_id,entity_type,entity_id,status,severity,reason,recommendation,created_at,updated_at").order("created_at", desc=True)
    if project_id:
        q = q.eq("project_id", project_id)
    if open_only:
        q = q.in_("status", ["open", "acknowledged"])
    return q.execute().data


def milestones(project_id: str) -> list[dict]:
    return _cached(f"milestones:{project_id}", lambda: _db().table("project_milestones").select("id,project_id,code,title,status,due_date,completed_at").eq("project_id", project_id).order("due_date").execute().data, 8.0)


def release_milestone(milestone_id: str, note: str = "") -> dict:
    return _rpc("epas_release_milestone", {"p_milestone_id": milestone_id, "p_note": note})


def mark_milestone_complete(milestone_id: str) -> dict:
    return _rpc("epas_complete_milestone", {"p_milestone_id": milestone_id, "p_note": "Milestone completed."})


def metrics() -> dict:
    s = role_dashboard_summary()
    return {
        "active_projects": int(s.get("active_projects", 0)),
        "pending_gm_rfi": int(s.get("pending_decisions", 0)),
        "rfi_allocation": int(s.get("open_tasks", 0)),
        "plan_pending_gm": int(s.get("plan_pending_gm", 0)),
        "plan_total": int(s.get("plan_total", 0)),
        "open_tasks": int(s.get("open_tasks", 0)),
        "open_escalations": int(s.get("open_escalations", 0)),
        "role": profile()["role"],
    }


def issue_certificate(rfi_id: str, cert_type: str, validity_months: int) -> dict:
    return _rpc("epas_issue_certificate", {"p_rfi_id": rfi_id, "p_cert_type": cert_type, "p_validity_months": int(validity_months)})


def secure_accept_task(task_id: str) -> dict:
    return _rpc("epas_accept_task", {"p_task_id": task_id})


def secure_start_task(task_id: str) -> dict:
    return _rpc("epas_start_task", {"p_task_id": task_id})


def secure_complete_task(task_id: str, note: str = "") -> dict:
    return _rpc("epas_complete_task", {"p_task_id": task_id, "p_note": note})


def dm_issue_corrective(action_id: str, assignee_id: str, instruction: str, due_date: date, observation_ids: list[str]) -> dict:
    if not observation_ids:
        raise ValueError("At least one exact observation must be selected for the corrective action")
    return _rpc("epas_dm_issue_corrective_action", {
        "p_action_id": action_id, "p_assignee_id": assignee_id,
        "p_instruction": instruction, "p_due_date": due_date.isoformat(),
        "p_observation_ids": observation_ids,
    })


def dm_verify_corrective(action_id: str, verification_note: str) -> dict:
    return _rpc("epas_dm_verify_corrective_action", {
        "p_action_id": action_id, "p_verification_note": verification_note
    })


def dm_create_followup_rfi(action_id: str) -> dict:
    return _rpc("epas_dm_create_followup_rfi", {"p_action_id": action_id})


def upload_project_document(project_id: str, category: str, uploaded_file) -> dict:
    return register_project_document(project_id, category, uploaded_file)


def complete_milestone(milestone_id: str, note: str = '') -> dict:
    return _rpc("epas_complete_milestone", {"p_milestone_id": milestone_id, "p_note": note})


def designer_submit_initial_drawing(project_id: str, drawing_no: str, title: str, discipline: str, uploaded_file, note: str) -> dict:
    if uploaded_file is None:
        raise ValueError('Drawing PDF is required')
    content, meta = _validated_bytes(uploaded_file, {'pdf'}, MAX_PDF_BYTES)
    path = f"projects/{project_id}/plan-appraisal/intake/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, 'application/pdf', lambda: _rpc('epas_designer_submit_initial_drawing_v15', {
        'p_project_id': project_id, 'p_drawing_no': drawing_no, 'p_title': title,
        'p_discipline': discipline, 'p_file_name': meta['file_name'], 'p_storage_path': path, 'p_note': note,
        'p_sha256': meta['sha256'], 'p_mime_type': 'application/pdf', 'p_size_bytes': meta['size_bytes']
    }))

def register_certificate_pdf(certificate_id: str, storage_path: str, sha256: str | None = None, size_bytes: int | None = None) -> dict:
    if sha256 and size_bytes:
        return _rpc("epas_register_certificate_pdf_v33", {
            "p_certificate_id": certificate_id, "p_storage_path": storage_path,
            "p_sha256": sha256, "p_size_bytes": size_bytes
        })
    raise ValueError("Certificate PDF SHA-256 and size are required for v3.2-controlled registration")


def project_eligible(project_id: str, role: str, discipline: str, work_date: date | None = None) -> list[dict]:
    return _rpc('epas_project_eligible_resources', {
        'p_project_id': project_id, 'p_role': role, 'p_discipline': discipline,
        'p_work_date': (work_date or date.today()).isoformat()
    }) or []


# ---------------------------------------------------------------------------
# v1.5 critical workflow services
# ---------------------------------------------------------------------------

def project_health_v15(project_id: str) -> dict | None:
    rows = _rpc("epas_project_health_v15", {"p_project_id": project_id}) or []
    return rows[0] if isinstance(rows, list) and rows else (rows if isinstance(rows, dict) else None)


def project_closure_check(project_id: str) -> list[dict]:
    return _rpc("epas_project_closure_check", {"p_project_id": project_id}) or []


def close_project(project_id: str, note: str) -> dict:
    return _rpc("epas_close_project", {"p_project_id": project_id, "p_note": note})


def release_document(document_id: str, audience_roles: list[str], note: str) -> dict:
    return _rpc("epas_release_document", {
        "p_document_id": document_id, "p_audience_roles": audience_roles, "p_note": note
    })


def withdraw_document_release(document_id: str, note: str) -> dict:
    return _rpc("epas_withdraw_document_release", {"p_document_id": document_id, "p_note": note})


def log_document_access(document_id: str, action: str) -> dict:
    return _rpc("epas_log_document_access", {"p_document_id": document_id, "p_action": action})


def released_documents(project_id: str | None = None, stakeholder_only: bool = False) -> list[dict]:
    q = _db().table("documents").select("id,project_id,file_name,category,version,status,storage_path,sha256,size_bytes,mime_type,uploaded_by,uploaded_at").order("uploaded_at", desc=True)
    if project_id:
        q = q.eq("project_id", project_id)
    if stakeholder_only:
        q = q.eq("stakeholder_visible", True).eq("release_status", "released")
    return q.execute().data


def document_releases(document_id: str | None = None, project_id: str | None = None) -> list[dict]:
    q = _db().table("document_releases").select("id,document_id,project_id,release_status,release_note,released_by,released_at").order("released_at", desc=True)
    if document_id:
        q = q.eq("document_id", document_id)
    if project_id:
        q = q.eq("project_id", project_id)
    return q.execute().data


def document_access_log(document_id: str | None = None, project_id: str | None = None, limit: int = 200) -> list[dict]:
    q = _db().table("document_access_audit").select("id,document_id,project_id,user_id,action,created_at,metadata").order("created_at", desc=True).limit(limit)
    if document_id:
        q = q.eq("document_id", document_id)
    if project_id:
        q = q.eq("project_id", project_id)
    return q.execute().data


def certificate_lifecycle(certificate_id: str | None = None, project_id: str | None = None) -> list[dict]:
    q = _db().table("certificate_lifecycle_events").select("id,certificate_id,event_type,note,created_at,actor_id").order("created_at", desc=True)
    if certificate_id:
        q = q.eq("certificate_id", certificate_id)
    if project_id:
        certs = certificates(project_id)
        ids = [c["id"] for c in certs]
        if ids: q = q.in_("certificate_id", ids)
    return q.execute().data


def finalize_interim_certificate(certificate_id: str, validity_months: int, note: str) -> dict:
    return _rpc("epas_finalize_interim_certificate", {
        "p_certificate_id": certificate_id,
        "p_validity_months": int(validity_months),
        "p_note": note,
    })


def clear_survey_observation(observation_id: str, note: str) -> dict:
    return _rpc("epas_clear_survey_observation", {"p_observation_id": observation_id, "p_note": note})


def project_eligible_v15(project_id: str, role: str, discipline: str, start: date | None = None, end: date | None = None) -> list[dict]:
    start = start or date.today()
    end = end or start
    return _rpc("epas_project_eligible_resources_v15", {
        "p_project_id": project_id,
        "p_role": role,
        "p_discipline": discipline,
        "p_window_start": start.isoformat(),
        "p_window_end": end.isoformat(),
    }) or []


def resource_workload(project_id: str) -> list[dict]:
    return _rpc("epas_resource_workload", {"p_project_id": project_id}) or []


def task_sla_snapshot(project_id: str) -> dict:
    rows = all_project_tasks(project_id)
    open_rows = [r for r in rows if r.get("status") not in ("completed", "returned")]
    overdue = []
    due_7d = []
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    for r in open_rows:
        due = r.get("due_at")
        if not due:
            continue
        try:
            dt = datetime.fromisoformat(due.replace("Z", "+00:00"))
            if dt < now:
                overdue.append(r)
            elif dt <= now + timedelta(days=7):
                due_7d.append(r)
        except Exception:
            pass
    return {"open": open_rows, "overdue": overdue, "due_7d": due_7d}


def run_sla_monitor() -> int:
    data = _rpc("epas_run_sla_monitor_v15", {})  # production scheduler/RPC
    return int(data or 0)


def gm_escalation_decide_v15(escalation_id: str, decision: str, note: str, action_owner_id: str | None = None, action_due_at: str | None = None) -> dict:
    return _rpc("epas_gm_escalation_decide", {
        "p_escalation_id": escalation_id,
        "p_decision": decision,
        "p_note": note,
        "p_action_owner_id": action_owner_id,
        "p_action_due_at": action_due_at,
    })


def gm_add_risk(project_id: str, code: str, title: str, description: str, probability: str, impact: str, severity: str, owner_id: str | None, mitigation: str, target_date: date | None) -> dict:
    return _rpc("epas_gm_add_risk_v15", {
        "p_project_id": project_id, "p_code": code, "p_title": title, "p_description": description,
        "p_probability": probability, "p_impact": impact, "p_severity": severity,
        "p_owner_id": owner_id, "p_mitigation": mitigation,
        "p_target_date": target_date.isoformat() if target_date else None,
    })


def risks(project_id: str) -> list[dict]:
    return _db().table("project_risks").select("id,project_id,risk_code,title,status,severity,owner_id,due_date,created_at,updated_at").eq("project_id", project_id).order("created_at", desc=True).execute().data


def gm_record_decision(project_id: str, subject: str, decision: str, reason: str, entity_type: str | None = None, entity_id: str | None = None) -> dict:
    return _rpc("epas_gm_record_decision", {
        "p_project_id": project_id, "p_subject": subject, "p_decision": decision, "p_reason": reason,
        "p_entity_type": entity_type, "p_entity_id": entity_id
    })


def decisions(project_id: str) -> list[dict]:
    return _db().table("project_decisions").select("id,project_id,decision_code,title,status,decision_at,owner_id,note").eq("project_id", project_id).order("decision_at", desc=True).execute().data


def audit_events(project_id: str, limit: int = 200) -> list[dict]:
    return _db().table("audit_log").select("id,project_id,actor_id,action,entity_type,entity_id,created_at,metadata,previous_hash,event_hash").eq("project_id", project_id).order("created_at", desc=True).limit(limit).execute().data


def register_project_document(project_id: str, category: str, uploaded_file) -> dict:
    if uploaded_file is None:
        raise ValueError("Document is required")
    suffix = str(getattr(uploaded_file, "name", "")).rsplit('.', 1)[-1].lower() if '.' in str(getattr(uploaded_file, "name", "")) else ''
    max_bytes = MAX_PDF_BYTES if suffix == 'pdf' else MAX_IMAGE_BYTES
    allowed = {'pdf'} if suffix == 'pdf' else {'jpg','jpeg','png'}
    content, meta = _validated_bytes(uploaded_file, allowed, max_bytes)
    name, mime, sha, size = meta['file_name'], meta['mime_type'], meta['sha256'], meta['size_bytes']
    path = f"projects/{project_id}/documents/{category}/{name}"
    return upload_with_cleanup('project-documents', path, content, mime, lambda: _rpc("epas_register_project_document_v15", {
        "p_project_id": project_id, "p_category": category, "p_file_name": name,
        "p_storage_path": path, "p_version": 1, "p_sha256": sha,
        "p_mime_type": mime, "p_size_bytes": size
    }))

def project_document_signed_url(document_id: str, expires_in: int = 600) -> str:
    rows = _db().table("documents").select("id,storage_path,project_id,stakeholder_visible,release_status").eq("id", document_id).limit(1).execute().data
    if not rows or not rows[0].get("storage_path"):
        raise RuntimeError("Document has no stored file")
    doc = rows[0]
    role = profile()["role"]
    if role in ("owner","shipyard") and not (doc.get("stakeholder_visible") and doc.get("release_status") == "released"):
        raise PermissionError("Document is not released for stakeholder access")
    log_document_access(document_id, "download")
    signed = _db().storage.from_("project-documents").create_signed_url(doc["storage_path"], expires_in)
    return signed.get("signedURL") or signed.get("signedUrl") or signed.get("url")



def certificate_pdf_signed_url(certificate_id: str, expires_in: int = 600) -> str:
    path = _rpc("epas_certificate_pdf_path", {"p_certificate_id": certificate_id})
    if not path:
        raise RuntimeError("Certificate PDF is not available")
    signed = _db().storage.from_("project-documents").create_signed_url(path, expires_in)
    return signed.get("signedURL") or signed.get("signedUrl") or signed.get("url")

def designer_submit_revision_v15(drawing_id: str, uploaded_file, note: str) -> dict:
    if uploaded_file is None:
        raise ValueError("Revision PDF is required")
    content, meta = _validated_bytes(uploaded_file, {'pdf'}, MAX_PDF_BYTES)
    d = plan_drawing(drawing_id)
    if not d:
        raise ValueError("Plan drawing not found")
    path = f"projects/{d['project_id']}/plan-appraisal/corrections/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, 'application/pdf', lambda: _rpc("epas_designer_submit_revision", {
        "p_drawing_id": drawing_id, "p_file_name": meta['file_name'], "p_storage_path": path,
        "p_note": note, "p_sha256": meta['sha256'], "p_mime_type": 'application/pdf', "p_size_bytes": meta['size_bytes']
    }))

def assignee_submit_corrective_v15(action_id: str, uploaded_file, completion_note: str) -> dict:
    if uploaded_file is None:
        raise ValueError("Controlled evidence file is required")
    suffix = str(getattr(uploaded_file, "name", "")).rsplit('.', 1)[-1].lower() if '.' in str(getattr(uploaded_file, "name", "")) else ''
    allowed = {'pdf'} if suffix == 'pdf' else {'jpg','jpeg','png'}
    content, meta = _validated_bytes(uploaded_file, allowed, MAX_PDF_BYTES if suffix == 'pdf' else MAX_IMAGE_BYTES)
    action = next((a for a in corrective_actions() if a["id"] == action_id), None)
    if not action:
        raise RuntimeError("Corrective action not found")
    path = f"projects/{action['project_id']}/corrective-actions/{action['id']}/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, meta['mime_type'], lambda: _rpc("epas_assignee_submit_corrective", {
        "p_action_id": action_id, "p_evidence_path": path, "p_evidence_sha256": meta['sha256'],
        "p_mime_type": meta['mime_type'], "p_size_bytes": meta['size_bytes'], "p_completion_note": completion_note
    }))

def gm_create_risk(project_id: str, code: str, title: str, description: str, probability: str, impact: str, severity: str, owner_id: str | None, mitigation: str, target_date: date | None) -> dict:
    return gm_add_risk(project_id, code, title, description, probability, impact, severity, owner_id, mitigation, target_date)


def gm_escalation_decide(escalation_id: str, decision: str, note: str) -> dict:
    # Backward-compatible UI wrapper.
    return gm_escalation_decide_v15(escalation_id, decision, note)


# Backward-compatible endpoints required by the GM/DM role workspaces.
def mark_notification_read(notification_id: str) -> dict:
    return _rpc("epas_mark_notification_read", {"p_notification_id": notification_id})

def mark_all_notifications_read() -> int:
    return int(_rpc("epas_mark_all_notifications_read", {}) or 0)

def clear_plan_observation(observation_id: str, note: str) -> dict:
    return _rpc("epas_close_plan_observation", {"p_observation_id": observation_id, "p_note": note})

def clear_survey_observation_v15(observation_id: str, note: str) -> dict:
    return clear_survey_observation(observation_id, note)

def engineer_submit_review(drawing_id: str, decision: str, note: str, observations_payload: list[dict] | None = None) -> dict:
    return _rpc("epas_engineer_submit_review", {
        "p_drawing_id": drawing_id, "p_decision": decision, "p_note": note,
        "p_observations": observations_payload or []
    })


def engineer_submit_review_v21(drawing_id: str, decision: str, note: str, observations_payload: list[dict] | None = None, needs_surveyor_verification: bool = False) -> dict:
    return _rpc("epas_engineer_submit_review_v21", {
        "p_drawing_id": drawing_id, "p_decision": decision, "p_note": note,
        "p_observations": observations_payload or [],
        "p_needs_surveyor_verification": needs_surveyor_verification,
    })

def engineer_register_appraisal_artifact(drawing_id: str, artifact_type: str, uploaded_file) -> dict:
    if uploaded_file is None:
        raise ValueError("PDF artifact is required")
    content, meta = _validated_bytes(uploaded_file, {'pdf'}, MAX_PDF_BYTES)
    d = plan_drawing(drawing_id)
    if not d:
        raise ValueError("Plan drawing not found")
    path = f"projects/{d['project_id']}/plan-appraisal/engineer-artifacts/{drawing_id}/{artifact_type}/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, 'application/pdf', lambda: _rpc("epas_engineer_register_appraisal_artifact", {
        "p_drawing_id": drawing_id, "p_artifact_type": artifact_type, "p_file_name": meta['file_name'],
        "p_storage_path": path, "p_sha256": meta['sha256'], "p_mime_type": 'application/pdf', "p_size_bytes": meta['size_bytes']
    }))

def surveyor_plan_verification_queue() -> list[dict]:
    return _rpc("epas_surveyor_plan_verification_queue", {}) or []

def surveyor_verify_plan_appraisal(drawing_id: str, result: str, note: str) -> dict:
    return _rpc("epas_surveyor_verify_plan_appraisal", {
        "p_drawing_id": drawing_id, "p_result": result, "p_note": note
    })

def submit_survey_report(rfi_id: str, report_note: str, observations_payload: list[dict] | None = None,
                          uploaded_file=None, location: str | None = None, attendance: str | None = None,
                          survey_date: date | None = None, declaration: str | None = None) -> dict:
    import hashlib
    evidence_path = None
    sha = None
    mime = None
    size = None
    if uploaded_file:
        safe_name = uploaded_file.name.replace("\\","_").replace("/","_")
        content = uploaded_file.getvalue()
        mime = uploaded_file.type or "application/octet-stream"
        sha = hashlib.sha256(content).hexdigest()
        evidence_path = f"projects/{rfi(rfi_id)['project_id']}/survey-reports/{rfi_id}/{safe_name}"
        _db().storage.from_("project-documents").upload(evidence_path, content, {"content-type": mime, "upsert": "false"})
        size = len(content)
    return _rpc("epas_submit_survey_report_v29", {
        "p_rfi_id": rfi_id, "p_report_note": report_note,
        "p_observations": observations_payload or [],
        "p_evidence_path": evidence_path, "p_evidence_sha256": sha,
        "p_mime_type": mime, "p_size_bytes": size, "p_location": location,
        "p_survey_date": (survey_date or date.today()).isoformat(),
        "p_attendance": attendance, "p_declaration": declaration
    })

def assignee_submit_corrective(action_id: str, evidence_path: str) -> dict:
    return _rpc("epas_assignee_submit_corrective", {"p_action_id": action_id, "p_evidence_path": evidence_path})

def designer_submit_revision(drawing_id: str, uploaded_file, note: str) -> dict:
    return designer_submit_revision_v15(drawing_id, uploaded_file, note)

def gm_amended_design_decision(drawing_id: str, decision: str, note: str) -> dict:
    return _rpc("epas_gm_amended_design_decision", {"p_drawing_id": drawing_id, "p_decision": decision, "p_note": note})

def project_health(project_id: str) -> dict | None:
    h = project_health_v15(project_id)
    return h

def certificates(project_id: str | None = None) -> list[dict]:
    q = _db().table("certificates").select("id,project_id,vessel_id,cert_number,cert_type,status,issue_date,expiry_date,pdf_storage_path,created_at,updated_at").order("created_at", desc=True)
    if project_id:
        q = q.eq("project_id", project_id)
    return q.execute().data

def dm_assign_engineer_v15(drawing_id: str, engineer_id: str, due_date: date) -> dict:
    return _rpc("epas_dm_assign_engineer_v15", {
        "p_drawing_id": drawing_id, "p_engineer_id": engineer_id, "p_due_date": due_date.isoformat()
    })

def dm_assign_surveyor_v15(rfi_id: str, surveyor_id: str, scheduled_date: date) -> dict:
    return _rpc("epas_dm_assign_surveyor_v15", {
        "p_rfi_id": rfi_id, "p_surveyor_id": surveyor_id, "p_scheduled_date": scheduled_date.isoformat()
    })

# ---------------------------------------------------------------------------
# v1.9 role-complete gap closure services
# ---------------------------------------------------------------------------
def survey_checklist(rfi_id: str) -> list[dict]:
    _rpc("epas_initialize_survey_checklist", {"p_rfi_id": rfi_id})
    return _db().table("survey_checklist_items").select("id,rfi_id,item_code,category,description,mandatory,status,response,completed_by,completed_at").eq("rfi_id", rfi_id).order("category").order("item_code").execute().data


def complete_survey_checklist_item(item_id: str, status: str, response: str = "", remarks: str = "") -> dict:
    return _rpc("epas_complete_survey_checklist_item", {"p_item_id": item_id, "p_status": status, "p_response": response, "p_remarks": remarks})


def survey_submission_gate(rfi_id: str) -> dict | None:
    rows = _rpc("epas_survey_submission_gate", {"p_rfi_id": rfi_id}) or []
    return rows[0] if isinstance(rows, list) and rows else None


def stakeholder_fleet_summary() -> dict | None:
    rows = _rpc("epas_stakeholder_fleet_summary", {}) or []
    return rows[0] if isinstance(rows, list) and rows else None


def stakeholder_vessel_dashboard(vessel_id: str) -> dict | None:
    rows = _rpc("epas_stakeholder_vessel_dashboard", {"p_vessel_id": vessel_id}) or []
    return rows[0] if isinstance(rows, list) and rows else None


def stakeholder_upcoming_surveys(vessel_id: str) -> list[dict]:
    return _rpc("epas_stakeholder_upcoming_surveys", {"p_vessel_id": vessel_id}) or []


def stakeholder_observation_summary(rfi_id: str) -> list[dict]:
    return _rpc("epas_stakeholder_observation_summary", {"p_rfi_id": rfi_id}) or []


def designer_submission_queue() -> list[dict]:
    return _rpc("epas_designer_submission_queue", {}) or []


def ship_management_action_queue() -> list[dict]:
    return _rpc("epas_ship_management_action_queue", {}) or []


def resource_allocation_matrix(project_id: str, role: str, discipline: str, work_date: date | None = None) -> list[dict]:
    return _rpc("epas_resource_allocation_matrix", {
        "p_project_id": project_id, "p_role": role, "p_discipline": discipline,
        "p_work_date": (work_date or date.today()).isoformat(),
    }) or []


def dm_create_follow_up_rfi(parent_rfi_id: str, follow_up_type: str, scope_note: str, requested_date: date) -> dict:
    return _rpc("epas_dm_create_follow_up_rfi", {
        "p_parent_rfi_id": parent_rfi_id, "p_follow_up_type": follow_up_type,
        "p_scope_note": scope_note, "p_requested_date": requested_date.isoformat(),
    })


def refresh_certificate_lifecycle() -> int:
    return int(_rpc("epas_refresh_certificate_lifecycle", {}) or 0)


def refresh_task_sla() -> int:
    return int(_rpc("epas_refresh_task_sla", {}) or 0)

# v2.0 professional completion services
def sla_dashboard(project_id: str | None = None) -> list[dict]:
    return _rpc("epas_sla_dashboard", {"p_project_id": project_id}) or []

def refresh_task_sla() -> int:
    return int(_rpc("epas_refresh_task_sla", {}) or 0)

def governance_register(project_id: str) -> list[dict]:
    return _rpc("epas_governance_register", {"p_project_id": project_id}) or []

def link_governance_entity(project_id: str, source_type: str, source_id: str, target_type: str, target_id: str, reason: str = "") -> dict:
    return _rpc("epas_link_governance_entity", {"p_project_id": project_id, "p_source_type": source_type, "p_source_id": source_id, "p_target_type": target_type, "p_target_id": target_id, "p_reason": reason})

def refresh_closure_readiness(project_id: str) -> dict:
    return _rpc("epas_refresh_closure_readiness", {"p_project_id": project_id})

def security_preflight() -> list[dict]:
    return _cached("security_preflight", lambda: _rpc_read("epas_security_preflight", {}) or [], 15.0)

def role_dashboard_summary() -> dict:
    return role_dashboard_bundle_v32()

def role_dashboard_detail() -> list[dict]:
    return _cached("role_dashboard_detail", lambda: _rpc_read("epas_role_dashboard_detail", {}) or [], 8.0)

def my_work_queue() -> list[dict]:
    return _cached("my_work_queue", lambda: _rpc_read("epas_my_work_queue", {}) or [], 5.0)

# EPAS v2.4 lifecycle / survey schedule helpers
def survey_schedule_queue(project_id: str | None = None) -> list[dict]:
    return _cached(f'survey_schedule_queue:{project_id or 'all'}', lambda: _rpc_read('epas_schedule_queue_v36', {'p_project_id': project_id}) or [], 8.0)


def project_timeline(project_id: str, limit: int = 100) -> list[dict]:
    return _cached(f'project_timeline:{project_id}:{limit}', lambda: _rpc_read('epas_timeline_v33', {'p_project_id': project_id, 'p_limit': limit}) or [], 8.0)


def refresh_survey_schedules() -> int:
    data = _rpc('epas_refresh_all_survey_schedules_as_operator', {})
    return int(data or 0)


def generate_survey_due_notifications() -> int:
    data = _rpc('epas_generate_survey_due_notifications_as_operator', {})
    return int(data or 0)


def drawing_revision_impact(rfi_id: str) -> list[dict]:
    return get_client().rpc('epas_survey_drawing_revision_impact', {'p_rfi_id': rfi_id}).execute().data or []

# v2.5 workflow-enforcement services
def surveyor_accept_assignment(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_surveyor_accept_assignment_v33", {"p_rfi_id": rfi_id, "p_note": note})


def survey_execution_prepare(rfi_id: str) -> dict | None:
    return _rpc("epas_prepare_survey_execution", {"p_rfi_id": rfi_id})


def surveyor_acknowledge_drawing_package(rfi_id: str) -> dict:
    return _rpc("epas_acknowledge_survey_drawing_package_v33", {"p_rfi_id": rfi_id, "p_note": ""}) or {}


def start_survey_execution(rfi_id: str) -> dict:
    return _rpc("epas_start_survey_execution_v26", {"p_rfi_id": rfi_id})


def freeze_survey_execution_basis(rfi_id: str) -> dict:
    return _rpc("epas_freeze_survey_execution_basis_v33", {"p_rfi_id": rfi_id})


def decide_drawing_revision_impact(package_id: str, impact: str, note: str) -> dict:
    return _rpc("epas_dm_decide_drawing_revision_impact", {
        "p_package_id": package_id, "p_impact": impact, "p_note": note
    })


def reissue_survey_drawing_package(package_id: str) -> dict:
    return _rpc("epas_reissue_survey_drawing_package", {"p_package_id": package_id})


def acknowledge_certificate_decision_package(package_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_certificate_decision_package_v33", {
        "p_package_id": package_id, "p_note": note
    })


def certificate_issuance_gate(rfi_id: str, cert_type: str) -> dict:
    return _rpc("epas_certificate_issuance_gate_v33", {
        "p_rfi_id": rfi_id, "p_cert_type": cert_type
    })


def set_in_service_schedule_basis(vessel_id: str, interval_months: int, basis: str,
                                   reference: str, window_days: int = 90, window_days_after: int = 30, basis_date: date | None = None) -> dict:
    chosen = basis_date or date.today()
    return _rpc("epas_set_in_service_schedule_basis_v33", {
        "p_vessel_id": vessel_id,
        "p_interval_months": interval_months,
        "p_due_basis": basis,
        "p_basis_reference": reference,
        "p_basis_date": chosen.isoformat(),
        "p_window_days_before": window_days,
        "p_window_days_after": window_days_after,
    })


def refresh_survey_schedules_as_operator() -> int:
    return int(_rpc("epas_refresh_all_survey_schedules_as_operator", {}) or 0)


def generate_survey_due_notifications_as_operator() -> int:
    return int(_rpc("epas_generate_survey_due_notifications_as_operator", {}) or 0)


def survey_control_tower(project_id: str | None = None) -> list[dict]:
    return _rpc("epas_schedule_queue_v35", {"p_project_id": project_id}) or []


def survey_start_gate_v26(rfi_id: str) -> dict:
    return _cached(f'survey_start_gate:{rfi_id}', lambda: _rpc_read("epas_survey_start_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)


def survey_submission_gate_v26(rfi_id: str) -> dict:
    return _rpc("epas_survey_submission_gate_v35", {"p_rfi_id": rfi_id}) or {}


def acknowledge_survey_scope(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_survey_scope_v33", {"p_rfi_id": rfi_id, "p_note": note}) or {}


def confirm_survey_execution_declaration(rfi_id: str, declaration_text: str, scope_confirmed: bool = True, drawings_confirmed: bool = True, attendance_confirmed: bool = True, safety_confirmed: bool = True, report_complete: bool = True) -> dict:
    return _rpc("epas_confirm_survey_execution_declaration", {
        "p_rfi_id": rfi_id,
        "p_scope_confirmed": scope_confirmed,
        "p_drawings_confirmed": drawings_confirmed,
        "p_attendance_confirmed": attendance_confirmed,
        "p_safety_confirmed": safety_confirmed,
        "p_report_complete": report_complete,
        "p_declaration_text": declaration_text,
    }) or {}


def schedule_action_context(schedule_id: str) -> dict:
    return _rpc("epas_survey_schedule_action_context", {"p_schedule_id": schedule_id}) or {}


def create_scheduled_in_service_rfi(schedule_id: str, survey_type: str, requested_date: date,
                                    priority: str, scope_note: str) -> dict:
    # v3.0 fixes In-Service survey type at the authoritative policy layer.
    return _rpc("epas_stakeholder_create_scheduled_in_service_rfi_v33", {
        "p_schedule_id": schedule_id,
        "p_scope": scope_note,
        "p_requested_date": requested_date.isoformat(),
        "p_priority": priority,
        "p_note": f"Requested survey type: {survey_type}" if survey_type else "",
    }) or {}


def project_scope_state(project_id: str) -> dict:
    return _cached(f"project_scope_state:{project_id}", lambda: _rpc_read("epas_project_scope_state", {"p_project_id": project_id}) or {}, 8.0)


def role_workflow_acceptance_summary(project_id: str | None = None) -> dict:
    return _cached(f"role_acceptance:{project_id or 'all'}", lambda: _rpc_read("epas_role_workflow_acceptance_summary", {"p_project_id": project_id}) or {}, 10.0)

# EPAS v2.7 final workflow controls
def survey_start_gate_v27(rfi_id: str) -> dict:
    return _rpc("epas_survey_start_gate_v35", {"p_rfi_id": rfi_id}) or {}


def start_survey_execution_v27(rfi_id: str) -> dict:
    return _rpc("epas_start_survey_execution_v33", {"p_rfi_id": rfi_id}) or {}


def survey_dependency_status_v27(rfi_id: str) -> dict:
    return _rpc("epas_survey_dependency_status_v33", {"p_rfi_id": rfi_id}) or {}


def acknowledge_survey_drawing_package_v27(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_survey_drawing_package_v33", {"p_rfi_id": rfi_id, "p_note": note}) or {}


def freeze_survey_execution_basis_v27(rfi_id: str) -> dict:
    return _rpc("epas_freeze_survey_execution_basis_v33", {"p_rfi_id": rfi_id}) or {}


def set_in_service_schedule_basis_v27(vessel_id: str, interval_months: int, basis: str, reference: str, window_days: int = 90, window_days_after: int = 30, basis_document_id: str | None = None, basis_date: date | None = None) -> dict:
    chosen_date = basis_date or date.today()
    return _rpc("epas_set_in_service_schedule_basis_v33", {
        "p_vessel_id": vessel_id,
        "p_interval_months": int(interval_months),
        "p_due_basis": basis,
        "p_basis_reference": reference,
        "p_basis_date": chosen_date.isoformat(),
        "p_window_days_before": int(window_days),
        "p_window_days_after": int(window_days_after),
        "p_basis_document_id": basis_document_id,
    })


def mark_in_service_cycle_complete_v27(rfi_id: str) -> dict:
    import uuid
    return _rpc("epas_mark_in_service_cycle_complete_v33", {"p_rfi_id": rfi_id, "p_idempotency_key": str(uuid.uuid4())}) or {}


def refresh_vessel_register_dates_v27(vessel_id: str) -> dict:
    return _rpc("epas_refresh_vessel_status_as_manager_v28", {"p_vessel_id": vessel_id}) or {}


def scheduler_status(project_id: str | None = None) -> list[dict]:
    # Scheduler history is intentionally read through RLS-backed table access; no trigger execution occurs here.
    q = _db().table("scheduler_runs").select("id,started_at,completed_at,status,error_message,metadata").order("started_at", desc=True).limit(20)
    if project_id:
        # scheduler_runs are global; project-specific filtering is represented by the UI's project-scoped schedule queue.
        pass
    return q.execute().data or []


def v27_lifecycle_cases() -> list[dict]:
    return _db().table("workflow_acceptance_cases_v27").select("case_code,role_name,phase,expected_result,negative,priority").order("priority,case_code").execute().data or []


def survey_start_gate_v28(rfi_id: str) -> dict:
    return _rpc("epas_survey_start_gate_v35", {"p_rfi_id": rfi_id}) or {}

def checklist_ready_v28(rfi_id: str) -> dict:
    return _rpc("epas_survey_checklist_ready_v33", {"p_rfi_id": rfi_id}) or {}

def acknowledge_survey_scope_v28(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_survey_scope_v33", {"p_rfi_id": rfi_id, "p_note": note}) or {}

def surveyor_accept_assignment_v28(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_surveyor_accept_assignment_v33", {"p_rfi_id": rfi_id, "p_note": note}) or {}

def start_survey_execution_v28(rfi_id: str) -> dict:
    return _rpc("epas_start_survey_execution_v33", {"p_rfi_id": rfi_id}) or {}

def set_in_service_schedule_basis_v28(vessel_id: str, interval_months: int, basis: str, reference: str, basis_date: date, window_days: int = 90, window_days_after: int = 30, basis_document_id: str | None = None) -> dict:
    return _rpc("epas_set_in_service_schedule_basis_v33", {
        "p_vessel_id": vessel_id,
        "p_interval_months": int(interval_months),
        "p_due_basis": basis,
        "p_basis_reference": reference,
        "p_basis_date": basis_date.isoformat(),
        "p_window_days_before": int(window_days),
        "p_window_days_after": int(window_days_after),
        "p_basis_document_id": basis_document_id,
    }) or {}

def survey_schedule_queue_v28(project_id: str | None = None) -> list[dict]:
    return _rpc("epas_schedule_queue_v35", {"p_project_id": project_id}) or []

def scheduler_health_v28() -> list[dict]:
    return _db().table("scheduler_runs").select("id,started_at,completed_at,status,error_message,metadata").order("started_at", desc=True).limit(20).execute().data or []


def mark_in_service_cycle_complete_v28(rfi_id: str) -> dict:
    import uuid
    return _rpc("epas_mark_in_service_cycle_complete_v33", {"p_rfi_id": rfi_id, "p_idempotency_key": str(uuid.uuid4())}) or {}


# EPAS v3.3 batch read helpers eliminate task/project N+1 queries.
def plan_drawings_by_ids(drawing_ids: list[str]) -> dict[str, dict]:
    ids=[str(x) for x in drawing_ids if x]
    if not ids: return {}
    rows=_cached(f"plan_drawings_by_ids:{','.join(sorted(ids))}", lambda: _rpc_read("epas_plan_drawing_bundle_v33", {"p_drawing_ids": ids}) or [], 6.0)
    return {str(r.get("id")): r for r in rows}

def rfis_by_ids(rfi_ids: list[str]) -> dict[str, dict]:
    ids=[str(x) for x in rfi_ids if x]
    if not ids: return {}
    rows=_cached(f"rfis_by_ids:{','.join(sorted(ids))}", lambda: _rpc_read("epas_rfi_bundle_v33", {"p_rfi_ids": ids}) or [], 6.0)
    return {str(r.get("id")): r for r in rows}

def plan_observations_by_drawing_ids(drawing_ids: list[str]) -> dict[str, list[dict]]:
    ids=[str(x) for x in drawing_ids if x]
    if not ids: return {}
    # RLS-backed direct table query; one round trip instead of one per drawing.
    rows=_cached(f"plan_obs_by_drawings:{','.join(sorted(ids))}", lambda: _db().table("plan_appraisal_observations").select("id,drawing_id,obs_code,description,severity,status,raised_at,response,responded_at").in_("drawing_id", ids).order("raised_at", desc=True).execute().data or [], 6.0)
    out={i:[] for i in ids}
    for row in rows: out.setdefault(str(row.get("drawing_id")),[]).append(row)
    return out

def role_dashboard_bundle_v33() -> dict:
    return _cached("role_dashboard_bundle_v33", lambda: _rpc_read("epas_role_dashboard_bundle_v33", {}) or {}, 5.0)

def authorized_projects_v33() -> list[dict]:
    return _cached("authorized_projects_v33", lambda: _rpc_read("epas_authorized_projects_v33", {}) or [], 10.0)

def stakeholder_fleet_bundle_v33() -> dict:
    return _cached("stakeholder_fleet_bundle_v33", lambda: _rpc_read("epas_stakeholder_fleet_bundle_v33", {}) or {}, 10.0)

def stakeholder_vessel_bundle_v33(vessel_id: str) -> dict:
    return _cached(f"stakeholder_vessel_bundle_v33:{vessel_id}", lambda: _rpc_read("epas_stakeholder_vessel_bundle_v33", {"p_vessel_id": vessel_id}) or {}, 10.0)

# EPAS v2.9 secure wrappers
def survey_checklist_ready_v29(rfi_id: str) -> dict:
    return _rpc("epas_survey_checklist_ready_v33", {"p_rfi_id": rfi_id}) or {}

def surveyor_accept_assignment_v29(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_surveyor_accept_assignment_v33", {"p_rfi_id": rfi_id, "p_note": note}) or {}

def acknowledge_survey_scope_v29(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_survey_scope_v33", {"p_rfi_id": rfi_id, "p_note": note}) or {}

def acknowledge_certificate_decision_package_v29(package_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_certificate_decision_package_v33", {"p_package_id": package_id, "p_note": note}) or {}

def refresh_vessel_status_manager_v29(vessel_id: str) -> dict:
    return _rpc("epas_refresh_vessel_status_as_manager_v33", {"p_vessel_id": vessel_id}) or {}


def global_search_v29(query: str, limit: int = 25) -> list[dict]:
    if not query.strip():
        return []
    return _cached(f'global_search:{query.strip().lower()}:{limit}', lambda: _rpc_read("epas_global_search_v29", {"p_query": query, "p_limit": int(limit)}) or [], 5.0)

def survey_schedule_queue_v30(project_id: str | None = None) -> list[dict]:
    return _cached(f"survey_schedule_queue_v30:{project_id or 'all'}", lambda: _rpc_read("epas_schedule_queue_v35", {"p_project_id": project_id}) or [], 8.0)

def project_timeline_v30(project_id: str, limit: int = 100) -> list[dict]:
    return _cached(f"project_timeline_v30:{project_id}:{limit}", lambda: _rpc_read("epas_timeline_v35", {"p_project_id": project_id, "p_limit": int(limit)}) or [], 8.0)

def survey_start_gate_v30(rfi_id: str) -> dict:
    return _cached(f"survey_start_gate_v30:{rfi_id}", lambda: _rpc_read("epas_survey_start_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)

def survey_submission_gate_v30(rfi_id: str) -> dict:
    return _cached(f'survey_submission_gate:{rfi_id}', lambda: _rpc_read("epas_survey_submission_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)

def certificate_issuance_gate_v30(rfi_id: str, cert_type: str) -> dict:
    return _cached(f'certificate_issuance_gate:{rfi_id}:{cert_type}', lambda: _rpc_read("epas_certificate_issuance_gate_v33", {"p_rfi_id": rfi_id, "p_cert_type": cert_type}) or {}, 3.0)

def submit_survey_report_v30(rfi_id: str, report_note: str, observations_payload: list[dict] | None = None,
                             uploaded_file=None, location: str | None = None, attendance: str | None = None,
                             survey_date: date | None = None, declaration: str | None = None) -> dict:
    if uploaded_file is None:
        raise ValueError("Controlled survey report PDF is required")
    content, meta = _validated_bytes(uploaded_file, {'pdf'}, MAX_PDF_BYTES)
    project_id=(rfi(rfi_id) or {}).get('project_id')
    if not project_id:
        raise ValueError("RFI project context is unavailable")
    path=f"projects/{project_id}/survey-reports/{rfi_id}/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, 'application/pdf', lambda: _rpc("epas_submit_survey_report_v33", {
        "p_rfi_id": rfi_id, "p_report_note": report_note, "p_observations": observations_payload or [],
        "p_evidence_path": path, "p_evidence_sha256": meta['sha256'], "p_mime_type": 'application/pdf',
        "p_size_bytes": meta['size_bytes'], "p_location": location,
        "p_survey_date": (survey_date or date.today()).isoformat(), "p_attendance": attendance, "p_declaration": declaration
    }))

def scheduler_health_v30() -> dict:
    return _cached('scheduler_health_v30', lambda: _rpc_read("epas_scheduler_health_v33", {}) or {}, 10.0)

def record_security_event_v29(event_type: str, success: bool = True, details: dict | None = None) -> dict:
    return _rpc("epas_record_security_event_v29", {"p_event_type": event_type, "p_success": success, "p_details": details or {}}) or {}


# EPAS v3.2 canonical application facade
def dashboard_project_health_bundle(project_ids: list[str]) -> dict[str, dict]:
    ids = [str(x) for x in project_ids if x]
    if not ids:
        return {}
    return _cached(f"project_health_bundle_v32:{','.join(sorted(ids))}", lambda: _rpc_read(
        "epas_project_health_bundle_v33", {"p_project_ids": ids}
    ) or {}, 8.0)

def role_dashboard_bundle_v32() -> dict:
    return _cached("role_dashboard_bundle_v32", lambda: _rpc_read("epas_role_dashboard_bundle_v33", {}) or {}, 5.0)

def survey_schedule_queue_v32(project_id: str | None = None) -> list[dict]:
    return _cached(f"survey_schedule_queue_v32:{project_id or 'all'}", lambda: _rpc_read("epas_schedule_queue_v35", {"p_project_id": project_id}) or [], 8.0)

def survey_start_gate_v32(rfi_id: str) -> dict:
    return _cached(f"survey_start_gate_v32:{rfi_id}", lambda: _rpc_read("epas_survey_start_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)

def survey_submission_gate_v32(rfi_id: str) -> dict:
    return _cached(f"survey_submission_gate_v32:{rfi_id}", lambda: _rpc_read("epas_survey_submission_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)

def certificate_issuance_gate_v32(rfi_id: str, cert_type: str) -> dict:
    return _cached(f"certificate_issuance_gate_v32:{rfi_id}:{cert_type}", lambda: _rpc_read("epas_certificate_issuance_gate_v33", {"p_rfi_id": rfi_id, "p_cert_type": cert_type}) or {}, 3.0)

def project_timeline_v32(project_id: str, limit: int = 100) -> list[dict]:
    return _cached(f"project_timeline_v32:{project_id}:{limit}", lambda: _rpc_read("epas_timeline_v35", {"p_project_id": project_id, "p_limit": int(limit)}) or [], 8.0)

def register_certificate_pdf_v32(cert_id: str, storage_path: str, sha256: str, size_bytes: int) -> dict:
    return _rpc("epas_register_certificate_pdf_v33", {"p_certificate_id": cert_id, "p_storage_path": storage_path, "p_sha256": sha256, "p_size_bytes": int(size_bytes)}) or {}


def set_in_service_schedule_basis_v32(vessel_id: str, interval_months: int, basis: str, reference: str, basis_date: date, window_days: int = 90, window_days_after: int = 30, basis_document_id: str | None = None) -> dict:
    return _rpc("epas_set_in_service_schedule_basis_v33", {
        "p_vessel_id": vessel_id, "p_interval_months": int(interval_months), "p_due_basis": basis,
        "p_basis_reference": reference, "p_basis_date": basis_date.isoformat(),
        "p_window_days_before": int(window_days), "p_window_days_after": int(window_days_after),
        "p_basis_document_id": basis_document_id,
    }) or {}


def authorized_projects_v32() -> list[dict]:
    return _cached("authorized_projects_v32", lambda: _rpc_read("epas_authorized_projects_v33", {}) or [], 10.0)

def scheduler_health_v32(limit: int = 20) -> list[dict]:
    return _cached(f"scheduler_health_v32:{limit}", lambda: _rpc_read("epas_scheduler_health_v33", {"p_limit": int(limit)}) or [], 10.0)

# EPAS v3.3 compatibility bindings — all active aliases route through v3.3.
def survey_schedule_queue_v30(project_id: str | None = None) -> list[dict]:
    return survey_schedule_queue_v33(project_id)

def project_timeline_v30(project_id: str, limit: int = 100) -> list[dict]:
    return project_timeline_v33(project_id, limit)

def survey_start_gate_v30(rfi_id: str) -> dict:
    return survey_start_gate_v33(rfi_id)

def survey_submission_gate_v30(rfi_id: str) -> dict:
    return survey_submission_gate_v33(rfi_id)

def certificate_issuance_gate_v30(rfi_id: str, cert_type: str) -> dict:
    return certificate_issuance_gate_v33(rfi_id, cert_type)

def submit_survey_report_v30(rfi_id: str, report_note: str, observations_payload: list[dict] | None = None, uploaded_file=None, location: str | None = None, attendance: str | None = None, survey_date: date | None = None, declaration: str | None = None) -> dict:
    if uploaded_file is None: raise ValueError("Controlled survey report PDF is required")
    content, meta = _validated_bytes(uploaded_file, {'pdf'}, MAX_PDF_BYTES)
    project_id=(rfi(rfi_id) or {}).get('project_id')
    if not project_id: raise ValueError("RFI project context is unavailable")
    path=f"projects/{project_id}/survey-reports/{rfi_id}/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, 'application/pdf', lambda: _rpc("epas_submit_survey_report_v33", {
        "p_rfi_id": rfi_id, "p_report_note": report_note, "p_observations": observations_payload or [],
        "p_evidence_path": path, "p_evidence_sha256": meta['sha256'], "p_mime_type": 'application/pdf',
        "p_size_bytes": meta['size_bytes'], "p_location": location, "p_survey_date": (survey_date or date.today()).isoformat(),
        "p_attendance": attendance, "p_declaration": declaration
    }, [f"survey_submission_gate:{rfi_id}", f"rfi:{rfi_id}", "survey_schedule_queue_v33:all"]))

def survey_schedule_queue_v33(project_id: str | None = None) -> list[dict]:
    return _cached(f"survey_schedule_queue_v33:{project_id or 'all'}", lambda: _rpc_read("epas_schedule_queue_v35", {"p_project_id": project_id}) or [], 8.0)

def project_timeline_v33(project_id: str, limit: int = 100) -> list[dict]:
    return _cached(f"project_timeline_v33:{project_id}:{limit}", lambda: _rpc_read("epas_timeline_v35", {"p_project_id": project_id, "p_limit": int(limit)}) or [], 8.0)

def survey_start_gate_v33(rfi_id: str) -> dict:
    return _cached(f"survey_start_gate_v33:{rfi_id}", lambda: _rpc_read("epas_survey_start_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)

def survey_submission_gate_v33(rfi_id: str) -> dict:
    return _cached(f"survey_submission_gate_v33:{rfi_id}", lambda: _rpc_read("epas_survey_submission_gate_v35", {"p_rfi_id": rfi_id}) or {}, 3.0)

def certificate_issuance_gate_v33(rfi_id: str, cert_type: str) -> dict:
    return _cached(f"certificate_issuance_gate_v33:{rfi_id}:{cert_type}", lambda: _rpc_read("epas_certificate_issuance_gate_v33", {"p_rfi_id": rfi_id, "p_cert_type": cert_type}) or {}, 3.0)

def register_certificate_pdf_v33(cert_id: str, storage_path: str, sha256: str, size_bytes: int) -> dict:
    return _rpc("epas_register_certificate_pdf_v33", {"p_certificate_id": cert_id, "p_storage_path": storage_path, "p_sha256": sha256, "p_size_bytes": int(size_bytes)}, ["certificates:"]) or {}



def upload_certificate_pdf_v34(cert_id: str, project_id: str, cert_number: str, pdf_bytes: bytes) -> str:
    """Upload a generated certificate PDF transactionally and register its true hash/size."""
    if not pdf_bytes:
        raise ValueError("Generated certificate PDF is empty")
    import hashlib
    path = f"projects/{project_id}/certificates/{cert_number}.pdf"
    sha256 = hashlib.sha256(pdf_bytes).hexdigest()
    upload_with_cleanup(
        'project-documents', path, pdf_bytes, 'application/pdf',
        lambda: register_certificate_pdf_v33(cert_id, path, sha256, len(pdf_bytes))
    )
    return path


def submit_survey_report_v34(rfi_id: str, report_note: str, observations_payload: list[dict] | None = None,
                             uploaded_file=None, location: str | None = None, attendance: str | None = None,
                             survey_date: date | None = None, declaration: str | None = None) -> dict:
    """Canonical survey-report submission with one materialization and orphan cleanup."""
    content, meta = _validated_bytes(uploaded_file, {'pdf'}, MAX_PDF_BYTES)
    project_id = (rfi(rfi_id) or {}).get('project_id')
    if not project_id:
        raise ValueError('RFI project context is unavailable')
    path = f"projects/{project_id}/survey-reports/{rfi_id}/{meta['file_name']}"
    return upload_with_cleanup('project-documents', path, content, 'application/pdf', lambda: _rpc(
        'epas_submit_survey_report_v33', {
            'p_rfi_id': rfi_id, 'p_report_note': report_note,
            'p_observations': observations_payload or [],
            'p_evidence_path': path, 'p_evidence_sha256': meta['sha256'],
            'p_mime_type': 'application/pdf', 'p_size_bytes': meta['size_bytes'],
            'p_location': location, 'p_survey_date': (survey_date or date.today()).isoformat(),
            'p_attendance': attendance, 'p_declaration': declaration,
        }, [make_key('survey_submission_gate', rfi_id), make_key('survey_start_gate', rfi_id), make_key('rfi', rfi_id), make_key('survey_schedule_queue', 'all')]
    ))

def set_in_service_schedule_basis_v33(vessel_id: str, interval_months: int, basis: str, reference: str, basis_date: date, window_days: int = 90, window_days_after: int = 30, basis_document_id: str | None = None) -> dict:
    return _rpc("epas_set_in_service_schedule_basis_v33", {"p_vessel_id": vessel_id,"p_interval_months": int(interval_months),"p_due_basis": basis,"p_basis_reference": reference,"p_basis_date": basis_date.isoformat(),"p_window_days_before": int(window_days),"p_window_days_after": int(window_days_after),"p_basis_document_id": basis_document_id}, ["survey_schedule_queue_v33:","role_dashboard_bundle_v33"]) or {}

def survey_checklist_ready_v33(rfi_id: str) -> dict:
    return _cached(f"survey_checklist_ready_v33:{rfi_id}", lambda: _rpc_read("epas_survey_checklist_ready_v33", {"p_rfi_id": rfi_id}) or {}, 3.0)

def acknowledge_survey_scope_v33(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_acknowledge_survey_scope_v33", {"p_rfi_id": rfi_id, "p_note": note}, [f"survey_start_gate_v33:{rfi_id}", f"survey_checklist_ready_v33:{rfi_id}"]) or {}

def surveyor_accept_assignment_v33(rfi_id: str, note: str = "") -> dict:
    return _rpc("epas_surveyor_accept_assignment_v33", {"p_rfi_id": rfi_id, "p_note": note}, [f"survey_start_gate_v33:{rfi_id}"]) or {}

def acknowledge_survey_drawing_package_v33(rfi_id: str) -> dict:
    return _rpc("epas_acknowledge_survey_drawing_package_v33", {"p_rfi_id": rfi_id}, [f"survey_start_gate_v33:{rfi_id}"]) or {}

def start_survey_execution_v33(rfi_id: str) -> dict:
    return _rpc("epas_start_survey_execution_v33", {"p_rfi_id": rfi_id}, [f"survey_start_gate_v33:{rfi_id}", f"survey_submission_gate_v33:{rfi_id}"]) or {}

def mark_in_service_cycle_complete_v33(rfi_id: str) -> dict:
    import uuid
    return _rpc("epas_mark_in_service_cycle_complete_v33", {"p_rfi_id": rfi_id, "p_idempotency_key": str(uuid.uuid4())}, [f"survey_schedule_queue_v33:all","role_dashboard_bundle_v33"]) or {}

# EPAS v3.5 active facade and role-native bundles.
def owner_fleet_bundle_v35() -> dict:
    return _cached(make_key('owner_fleet_bundle_v35'), lambda: _rpc_read('epas_owner_fleet_bundle_v35', {}) or {}, 8.0)

def owner_fleet_vessels_v35() -> list[dict]:
    return _cached(make_key('owner_fleet_vessels_v35'), lambda: _rpc_read('epas_owner_fleet_vessels_v35', {}) or [], 8.0)

def ship_management_bundle_v35() -> dict:
    return _cached(make_key('ship_management_bundle_v35'), lambda: _rpc_read('epas_ship_management_bundle_v35', {}) or {}, 6.0)

def ship_management_actions_v35() -> list[dict]:
    return _cached(make_key('ship_management_actions_v35'), lambda: _rpc_read('epas_ship_management_actions_v35', {}) or [], 6.0)

def shipyard_nsc_bundle_v35() -> dict:
    return _cached(make_key('shipyard_nsc_bundle_v35'), lambda: _rpc_read('epas_shipyard_nsc_bundle_v35', {}) or {}, 8.0)

def shipyard_nsc_projects_v35() -> list[dict]:
    return _cached(make_key('shipyard_nsc_projects_v35'), lambda: _rpc_read('epas_shipyard_nsc_projects_v35', {}) or [], 8.0)

def coordination_timeline_v35(project_id: str, limit: int = 100) -> list[dict]:
    return _cached(make_key('coordination_timeline_v35', project_id, limit), lambda: _rpc_read('epas_coordination_timeline_v35', {'p_project_id': project_id, 'p_limit': int(limit)}) or [], 6.0)

def project_phase_workflow_v35(project_id: str) -> dict:
    return _cached(make_key('project_phase_workflow_v35', project_id), lambda: _rpc_read('epas_project_phase_workflow_v35', {'p_project_id': project_id}) or {}, 6.0)

def survey_schedule_queue_v35(project_id: str | None = None) -> list[dict]:
    return _cached(make_key('survey_schedule_queue_v35', project_id or 'all'), lambda: _rpc_read('epas_schedule_queue_v36', {'p_project_id': project_id}) or [], 8.0)

def project_timeline_v35(project_id: str, limit: int = 100) -> list[dict]:
    return coordination_timeline_v35(project_id, limit)

def scheduler_health_v35(limit: int = 20) -> list[dict]:
    return _cached(make_key('scheduler_health_v35', limit), lambda: _rpc_read('epas_scheduler_health_v36', {'p_limit': int(limit)}) or [], 10.0)

def audit_chain_verify_v35(project_id: str) -> dict:
    return _rpc_read('epas_audit_chain_verify_v35', {'p_project_id': project_id}) or {}

def privilege_audit_v35() -> list[dict]:
    return _rpc_read('epas_privilege_audit_v35', {}) or []

def mark_in_service_cycle_complete_v35(rfi_id: str, idempotency_key: str | None = None) -> dict:
    import uuid
    key = idempotency_key or str(uuid.uuid4())
    return _rpc('epas_mark_in_service_cycle_complete_v36', {'p_rfi_id': rfi_id, 'p_idempotency_key': key}, [make_key('survey_schedule_queue_v35','all'), make_key('role_dashboard_summary')]) or {}


def role_dashboard_summary_v35() -> dict:
    return _cached(make_key('role_dashboard_summary_v35'), lambda: _rpc_read('epas_role_dashboard_bundle_v35', {}) or {}, 6.0)

def set_in_service_schedule_basis_v35(vessel_id: str, interval_months: int, basis: str, reference: str, basis_date: date, window_days: int = 90, window_days_after: int = 30, basis_document_id: str | None = None) -> dict:
    return _rpc('epas_set_in_service_schedule_basis_v36', {
        'p_vessel_id': vessel_id, 'p_interval_months': int(interval_months), 'p_due_basis': basis,
        'p_basis_reference': reference, 'p_basis_date': basis_date.isoformat(),
        'p_window_days_before': int(window_days), 'p_window_days_after': int(window_days_after),
        'p_basis_document_id': basis_document_id,
    }, [make_key('survey_schedule_queue_v35','all'), make_key('role_dashboard_summary_v35')]) or {}


# ---------------------------------------------------------------------------
# v3.6 compatibility facade for archived components/tests.
# These functions are production-only adapters: no demo state, no in-memory DB.
# ---------------------------------------------------------------------------
def current_gm() -> dict:
    return profile()

def get_user(user_id: str | None) -> dict | None:
    if not user_id: return None
    return (_db().table("profiles").select("id,full_name,email,role,active").eq("id", user_id).limit(1).execute().data or [None])[0]

def list_projects(status: str | None = None) -> list[dict]: return projects(status)
def get_project(project_id: str) -> dict | None: return project(project_id)
def get_vessel_for_project(project_id: str) -> dict | None: return vessel(project_id)
def get_vessel(vessel_id: str) -> dict | None:
    return (_db().table("vessels").select("id,project_id,name,imo_number,class_status,survey_status,next_survey_due,last_survey_date,last_survey_phase").eq("id", vessel_id).limit(1).execute().data or [None])[0]
def list_vessels() -> list[dict]:
    return _cached(make_key('vessels','all'), lambda: _db().table('vessels').select('id,project_id,name,imo_number,class_status,survey_status,next_survey_due,last_survey_date,last_survey_phase').order('name').execute().data, 15.0)
def list_team(project_id: str) -> list[dict]: return members(project_id)
def list_stakeholders(project_id: str) -> list[dict]: return stakeholders(project_id)
def list_rfis(phase: str | None = None, status: str | list[str] | None = None, project_id: str | None = None, assigned_to_me: bool = False) -> list[dict]:
    rows = rfis(status=status if isinstance(status,str) else None, project_id=project_id, assigned_to_me=assigned_to_me)
    if phase: rows = [r for r in rows if r.get('phase') == phase]
    if isinstance(status, list): rows = [r for r in rows if r.get('status') in status]
    return rows
def get_rfi(rfi_id: str) -> dict | None: return rfi(rfi_id)
def list_observations(rfi_id: str) -> list[dict]: return observations(rfi_id)
def open_observations(rfi_id: str) -> list[dict]: return [o for o in observations(rfi_id) if o.get('status')=='open']
def gm_actionable_rfis() -> list[dict]: return [r for r in rfis() if r.get('status') in ('pending_allocation','pending_gm_approval')]
def gm_decide(rfi_id: str, decision: str, note: str='') -> dict: return gm_decide_rfi(rfi_id, decision, note)
def list_gm_decisions(rfi_id: str) -> list[dict]:
    return _db().table('gm_decisions').select('id,rfi_id,decided_by,decision,note,decided_at').eq('rfi_id',rfi_id).order('decided_at',desc=True).execute().data
def list_certificates(vessel_id: str | None=None, status: str | None=None) -> list[dict]:
    q=_db().table('certificates').select('id,project_id,vessel_id,rfi_id,cert_type,cert_number,issue_date,expiry_date,status').order('issue_date',desc=True)
    if vessel_id: q=q.eq('vessel_id',vessel_id)
    if status: q=q.eq('status',status)
    return q.execute().data
def expiring_soon_certificates(days: int=90) -> list[dict]:
    today=date.today(); rows=list_certificates(status='active'); return [r for r in rows if r.get('expiry_date') and 0 <= (date.fromisoformat(r['expiry_date'])-today).days <= days]
def ship_register_rows() -> list[dict]:
    # Prefer the controlled register projection if available.
    rows=_cached(make_key('ship_register','all'), lambda: _db().from_('epas_ship_register').select('vessel_id,project_id,name,class_status,survey_status,next_survey_due,last_survey_date,last_survey_phase').order('name').execute().data, 10.0)
    return rows or []
def ship_register_project(project_id: str) -> list[dict]:
    # Project-scoped register read: never load the full fleet just to filter client-side.
    rows=_cached(make_key('ship_register','project',project_id), lambda: _db().from_('epas_ship_register').select('vessel_id,project_id,name,class_status,survey_status,next_survey_due,last_survey_date,last_survey_phase').eq('project_id', project_id).order('name').execute().data, 10.0)
    return rows or []
def audit_trail(project_id: str | None=None) -> list[dict]: return audit_events(project_id or '', 200) if project_id else []
def kpi_summary() -> dict: return metrics()
def project_phase_status(project_id: str) -> list[dict]:
    data=project_phase_workflow_v35(project_id)
    if not data: return []
    return [{'phase':k,'status':v} for k,v in data.items() if k in ('plan','nsc','in_service')]
def vessel_survey_status(vessel_id: str) -> dict:
    v=get_vessel(vessel_id); return v or {}
def list_documents(project_id: str) -> list[dict]: return released_documents(project_id, stakeholder_only=False)
def get_document(document_id: str) -> dict | None:
    return (_db().table('documents').select('id,project_id,file_name,category,version,status,storage_path,sha256,size_bytes,mime_type,uploaded_by,uploaded_at,stakeholder_visible,release_status').eq('id',document_id).limit(1).execute().data or [None])[0]
def list_document_remarks(document_id: str) -> list[dict]:
    return _db().table('document_remarks').select('id,document_id,author_id,body,created_at').eq('document_id',document_id).order('created_at').execute().data
def add_document_remark(document_id: str, author_id: str, body: str) -> dict:
    return _rpc('epas_add_document_remark', {'p_document_id': document_id,'p_author_id':author_id,'p_body':body})
def update_document_status(document_id: str, status: str) -> dict:
    return _rpc('epas_update_document_status', {'p_document_id':document_id,'p_status':status})

# Active convenience aliases to the v3.5 authoritative service layer.
def schedule_bundle_v36(project_id: str|None=None): return _rpc_read('epas_schedule_queue_v36', {'p_project_id': project_id}) or []
def scheduler_health_v36(limit: int=20): return _rpc_read('epas_scheduler_health_v36', {'p_limit': int(limit)}) or []
def mark_in_service_cycle_complete_v36(rfi_id: str, idempotency_key: str|None=None): return _rpc('epas_mark_in_service_cycle_complete_v36', {'p_rfi_id': rfi_id, 'p_idempotency_key': idempotency_key or __import__('uuid').uuid4().hex})
def set_in_service_schedule_basis_v36(*args, **kwargs): return _rpc('epas_set_in_service_schedule_basis_v36', {'p_vessel_id': args[0], 'p_interval_months': int(args[1]), 'p_due_basis': args[2], 'p_basis_reference': args[3], 'p_basis_date': args[4].isoformat(), 'p_window_days_before': int(kwargs.get('window_days',90)), 'p_window_days_after': int(kwargs.get('window_days_after',30)), 'p_basis_document_id': kwargs.get('basis_document_id')})
def survey_start_gate_v36(rfi_id: str): return _rpc_read('epas_survey_start_gate_v36', {'p_rfi_id':rfi_id}) or {}
def survey_submission_gate_v36(rfi_id: str): return _rpc_read('epas_survey_submission_gate_v36', {'p_rfi_id':rfi_id}) or {}


# v3.6 active facade helpers. These are the only names active components should call.
def role_dashboard_summary_v36() -> dict:
    """Fallback dashboard summary using direct table queries (v3.6 RPC not available yet)."""
    def _load() -> dict:
        try:
            uid = profile()['id']
            role = profile()['role']
            
            # Projects visible to this user
            q = _db().table('project_members').select('project_id').eq('user_id', uid).eq('active', True)
            project_rows = q.execute().data or []
            project_ids = [r['project_id'] for r in project_rows]
            
            result = {
                'active_projects': len(project_ids),
                'plan_pending_gm': 0,
                'pending_decisions': 0,
                'overdue_tasks': 0,
                'open_escalations': 0,
                'my_rfis': 0,
                'my_tasks': 0,
            }
            
            if not project_ids:
                return result
            
            # RFIs assigned to this user
            if role in ('dm', 'surveyor', 'engineer'):
                rfi_q = _db().table('rfis').select('id,status')
                if role == 'dm':
                    rfi_q = rfi_q.eq('assigned_dm_id', uid)
                elif role == 'surveyor':
                    rfi_q = rfi_q.eq('assigned_surveyor_id', uid)
                
                rfi_rows = rfi_q.execute().data or []
                result['my_rfis'] = len(rfi_rows)
                
                # Count by status for DMs
                if role == 'dm':
                    result['pending_decisions'] = len([r for r in rfi_rows if r['status'] in ('pending_gm_approval', 'observations_logged')])
            
            # Pending GM decisions
            if role == 'gm' and project_ids:
                gm_q = _db().table('rfis').select('id,status').in_('project_id', project_ids)
                gm_rows = gm_q.execute().data or []
                result['pending_decisions'] = len([r for r in gm_rows if r['status'] == 'pending_gm_approval'])
                result['my_rfis'] = len(gm_rows)
            
            # Certificate count
            cert_q = _db().table('certificates').select('id').eq('status', 'active')
            if project_ids:
                cert_q = cert_q.in_('project_id', project_ids)
            cert_rows = cert_q.execute().data or []
            result['active_certificates'] = len(cert_rows)
            
            return result
        except Exception as e:
            st.warning(f"Dashboard metrics loading issue (EPAS-36): {str(e)[:60]}")
            return {
                'active_projects': 0, 'plan_pending_gm': 0, 'pending_decisions': 0,
                'overdue_tasks': 0, 'open_escalations': 0, 'my_rfis': 0, 'my_tasks': 0,
            }
    
    return _cached(make_key('role_dashboard_summary_v36'), _load, 6.0)

def authorized_projects_v36(role: str | None = None) -> list[dict]:
    uid=profile()['id']
    role_name=role or profile()['role']
    key=make_key('authorized_projects_v36',uid,role_name)
    def _load():
        q=_db().table('project_members').select('project_id,role,active,projects:project_id(id,project_code,name,status,phases,created_at,updated_at)').eq('user_id',uid).eq('active',True)
        if role_name: q=q.eq('role',role_name)
        rows=q.execute().data or []
        return [r.get('projects') for r in rows if r.get('projects')]
    return _cached(key,_load,10.0)

def acknowledge_survey_drawing_package_v36(rfi_id: str, note: str='') -> dict:
    return _rpc('epas_acknowledge_survey_drawing_package_v36',{'p_rfi_id':rfi_id,'p_note':note},[make_key('survey_start_gate_v36',rfi_id)]) or {}

def surveyor_accept_assignment_v36(rfi_id: str, note: str='') -> dict:
    return _rpc('epas_surveyor_accept_assignment_v36',{'p_rfi_id':rfi_id,'p_note':note},[make_key('survey_start_gate_v36',rfi_id)]) or {}

def start_survey_execution_v36(rfi_id: str) -> dict:
    return _rpc('epas_start_survey_execution_v36',{'p_rfi_id':rfi_id},[make_key('survey_start_gate_v36',rfi_id),make_key('survey_submission_gate_v36',rfi_id)]) or {}

def submit_survey_report_v36(rfi_id: str, report_note: str, observations_payload=None, uploaded_file=None, location=None, attendance=None, survey_date=None, declaration=None) -> dict:
    return submit_survey_report_v34(rfi_id,report_note,observations_payload,uploaded_file,location,attendance,survey_date,declaration)

def checklist_ready_v36(rfi_id: str) -> dict:
    return _cached(make_key('survey_checklist_ready_v36',rfi_id), lambda:_rpc_read('epas_survey_checklist_ready_v36',{'p_rfi_id':rfi_id}) or {},3.0)


def owner_fleet_bundle_v36(): return owner_fleet_bundle_v35()
def owner_fleet_vessels_v36(): return owner_fleet_vessels_v35()
def ship_management_bundle_v36(): return ship_management_bundle_v35()
def ship_management_actions_v36(): return ship_management_actions_v35()
def shipyard_nsc_bundle_v36(): return shipyard_nsc_bundle_v35()
def shipyard_nsc_projects_v36(): return shipyard_nsc_projects_v35()
def coordination_timeline_v36(project_id: str, limit: int=100): return coordination_timeline_v35(project_id,limit)
def project_phase_workflow_v36(project_id: str): return project_phase_workflow_v35(project_id)
def stakeholder_fleet_bundle_v36(): return stakeholder_fleet_bundle_v33()
def stakeholder_vessel_bundle_v36(vessel_id: str): return stakeholder_vessel_bundle_v33(vessel_id)
def upload_certificate_pdf_v36(cert_id: str, project_id: str, cert_number: str, pdf_bytes: bytes) -> str:
    path=f"projects/{project_id}/certificates/{cert_number}.pdf"
    import hashlib
    sha=hashlib.sha256(pdf_bytes).hexdigest()
    upload_with_cleanup('project-documents',path,pdf_bytes,'application/pdf',lambda:_rpc('epas_register_certificate_pdf_v36',{'p_certificate_id':cert_id,'p_storage_path':path,'p_sha256':sha,'p_size_bytes':len(pdf_bytes)},[make_key('certificates')]))
    return path


def dm_assign_engineer_v36(drawing_id: str, engineer_id: str): return dm_assign_engineer(drawing_id, engineer_id)
def dm_assign_surveyor_v36(rfi_id: str, surveyor_id: str, scheduled_date: date): return dm_assign_surveyor(rfi_id,surveyor_id,scheduled_date)
def engineer_submit_review_v36(drawing_id: str, decision: str, note: str, observations_payload=None, needs_surveyor_verification: bool=False): return engineer_submit_review_v21(drawing_id,decision,note,observations_payload,needs_surveyor_verification)
def assignee_submit_corrective_v36(action_id: str, uploaded_file, completion_note: str): return assignee_submit_corrective_v15(action_id,uploaded_file,completion_note)
def gm_escalation_decide_v36(escalation_id: str, decision: str, note: str): return gm_escalation_decide_v15(escalation_id,decision,note)
def project_eligible_v36(project_id: str, role: str, discipline: str, work_date=None): return project_eligible(project_id,role,discipline,work_date)
def project_health_v36(project_id: str): return project_health(project_id)
def global_search_v36(term: str): return global_search_v29(term)
def v36_lifecycle_cases():
    return _db().table('workflow_acceptance_cases_v29').select('case_code,role_name,phase,expected_result,negative,priority').order('priority').execute().data or []


def survey_schedule_queue_v36(project_id: str|None=None): return schedule_bundle_v36(project_id)

# ---------------------------------------------------------------------------
# Demo runtime override
# ---------------------------------------------------------------------------
# The production query surface remains unchanged for professional mode. When
# EPAS_RUNTIME_MODE=demo, every active production query symbol is transparently
# served by the in-memory v4 demo adapter so GitHub/Codespaces can expose a
# realistic port-8501 preview without a Supabase project.
try:
    from config.supabase_client import is_demo_mode as _epas_is_demo_mode
    if _epas_is_demo_mode():
        from database import demo_queries_v40 as _demo_q
        _demo_symbols = [
            name for name, obj in list(globals().items())
            if not name.startswith('_') and callable(obj) and getattr(obj, '__module__', None) == __name__
        ]
        for _name in _demo_symbols:
            globals()[_name] = (lambda _n: (lambda *args, **kwargs: _demo_q.dispatch(_n, *args, **kwargs)))(_name)
except Exception:
    # Demo binding errors are surfaced through the demo login/startup screen;
    # production mode never enters this block.
    pass
