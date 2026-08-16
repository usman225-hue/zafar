"""EPAS upgrade query layer.

Adds:
- plan appraisal state machine
- authorization / competency / availability eligibility engine
- real task handover records
- document revision history
- in-app notifications

Demo mode is fully interactive. Live mode uses the Supabase tables defined in
`database/upgrade_schema.sql`; the UI code does not need to change.
"""
from __future__ import annotations

import uuid
from datetime import date, timedelta
from typing import Any

import streamlit as st

from config import settings as cfg
from config.supabase_client import get_client, is_demo_mode
from database import queries as q

# Plan appraisal states
PA_SUBMITTED = "submitted"
PA_ASSIGNED_MANAGER = "assigned_manager"
PA_ASSIGNED_ENGINEER = "assigned_engineer"
PA_UNDER_REVIEW = "under_engineer_review"
PA_OBSERVATION_RAISED = "observation_raised"
PA_DESIGNER_RESPONSE = "designer_response"
PA_REVIEW_RESUBMITTED = "review_resubmitted"
PA_MANAGER_REVIEW = "manager_review"
PA_PENDING_GM = "pending_gm_approval"
PA_APPROVED = "approved"
PA_REJECTED = "rejected"

PA_STATUS_LABELS = {
    PA_SUBMITTED: "Submitted",
    PA_ASSIGNED_MANAGER: "Manager Assigned",
    PA_ASSIGNED_ENGINEER: "Engineer Assigned",
    PA_UNDER_REVIEW: "Engineer Review",
    PA_OBSERVATION_RAISED: "Observation Raised",
    PA_DESIGNER_RESPONSE: "Designer Response",
    PA_REVIEW_RESUBMITTED: "Re-review",
    PA_MANAGER_REVIEW: "Manager Review",
    PA_PENDING_GM: "Pending GM Approval",
    PA_APPROVED: "Approved",
    PA_REJECTED: "Returned / Rejected",
}

TASK_PENDING = "pending"
TASK_ACCEPTED = "accepted"
TASK_IN_PROGRESS = "in_progress"
TASK_COMPLETED = "completed"
TASK_RETURNED = "returned"


def status_badge_kind(status: str) -> str:
    if status == PA_APPROVED:
        return "success"
    if status in (PA_OBSERVATION_RAISED, PA_REJECTED):
        return "warning"
    if status == PA_PENDING_GM:
        return "action"
    return "info"


def _store() -> dict:
    """Lazy demo upgrade store, seeded from the base application's data."""
    db = q._db()
    db.setdefault("authorizations", [])
    db.setdefault("competencies", [])
    db.setdefault("availability", [])
    db.setdefault("plan_drawings", [])
    db.setdefault("plan_observations", [])
    db.setdefault("plan_events", [])
    db.setdefault("document_revisions", [])
    db.setdefault("handover_tasks", [])
    db.setdefault("notifications", [])
    db.setdefault("survey_reports", [])
    _seed_if_empty(db)
    return db


def _uid() -> str:
    return str(uuid.uuid4())


def _seed_if_empty(db: dict) -> None:
    if not db["authorizations"]:
        for u in db["profiles"]:
            if u["role"] == cfg.ROLE_ENGINEER:
                db["authorizations"].append({"id": _uid(), "user_id": u["id"], "discipline": "Stability", "authorization_level": "Senior", "active": True, "valid_until": date.today() + timedelta(days=365)})
                db["authorizations"].append({"id": _uid(), "user_id": u["id"], "discipline": "Hull & Structure", "authorization_level": "Reviewer", "active": True, "valid_until": date.today() + timedelta(days=365)})
            if u["role"] == cfg.ROLE_SURVEYOR:
                disc = next((x["discipline"] for x in db["team_assignments"] if x["user_id"] == u["id"] and x.get("discipline")), "Hull & Structure")
                db["authorizations"].append({"id": _uid(), "user_id": u["id"], "discipline": disc, "authorization_level": "Surveyor", "active": True, "valid_until": date.today() + timedelta(days=365)})
    if not db["competencies"]:
        for a in db["authorizations"]:
            db["competencies"].append({"id": _uid(), "user_id": a["user_id"], "discipline": a["discipline"], "status": "competent", "valid_until": date.today() + timedelta(days=365), "last_assessed": date.today() - timedelta(days=30)})
    if not db["availability"]:
        for u in db["profiles"]:
            if u["role"] in (cfg.ROLE_ENGINEER, cfg.ROLE_SURVEYOR):
                db["availability"].append({"id": _uid(), "user_id": u["id"], "work_date": date.today(), "status": "available", "workload_pct": 35, "notes": "Available for new assignment"})

    if not db["plan_drawings"]:
        project = next((p for p in db["projects"] if cfg.PHASE_PLAN_APPRAISAL in p["phases"]), None)
        if project:
            designer = next((u for u in db["profiles"] if u["role"] == cfg.ROLE_DESIGNER), None)
            dm = next((u for u in db["profiles"] if u["role"] == cfg.ROLE_DM), None)
            eng = next((u for u in db["profiles"] if u["role"] == cfg.ROLE_ENGINEER), None)
            base_doc = next((d for d in db["documents"] if d["project_id"] == project["id"] and d["category"] == cfg.DOC_CATEGORY_DRAWING), None)
            if not base_doc:
                base_doc = {"id": _uid(), "project_id": project["id"], "category": cfg.DOC_CATEGORY_DRAWING, "file_name": "GA-001-General-Arrangement.pdf", "version": 1, "status": "pending_review", "uploaded_by": designer["id"] if designer else None, "uploaded_at": date.today()}
                db["documents"].append(base_doc)
            db["plan_drawings"].append({
                "id": _uid(), "project_id": project["id"], "document_id": base_doc["id"], "drawing_no": "GA-001", "title": "General Arrangement", "discipline": "Hull & Structure", "revision": 1, "status": PA_SUBMITTED, "manager_id": None, "engineer_id": None, "designer_id": designer["id"] if designer else None, "submitted_at": date.today() - timedelta(days=2), "updated_at": date.today(), "current_file_name": base_doc["file_name"]
            })
            db["plan_events"].append({"id": _uid(), "drawing_id": db["plan_drawings"][-1]["id"], "event_type": "SUBMITTED", "actor_id": designer["id"] if designer else None, "note": "Initial drawing submission", "created_at": date.today() - timedelta(days=2)})


def _live_table(name: str):
    return get_client().table(name)


def list_plan_drawings(project_id: str) -> list[dict]:
    if is_demo_mode():
        return [d for d in _store()["plan_drawings"] if d["project_id"] == project_id]
    return _live_table("plan_drawings").select("*").eq("project_id", project_id).order("updated_at", desc=True).execute().data

def list_approved_plan_drawings(project_id: str) -> list[dict]:
    """Return only Plan Appraisal approved drawings eligible for survey handover."""
    return [d for d in list_plan_drawings(project_id) if d.get("status") == PA_APPROVED]

def surveyor_drawing_package(rfi_id: str) -> list[dict]:
    if is_demo_mode():
        rows = []
        for x in _store().get("survey_rfi_drawings", []):
            if x.get("rfi_id") == rfi_id and not x.get("revoked_at"):
                d = get_plan_drawing(x["drawing_id"])
                if d and d.get("status") == PA_APPROVED:
                    rows.append(d)
        return rows
    return get_client().rpc("epas_surveyor_drawing_package", {"p_rfi_id": rfi_id}).execute().data or []


def get_plan_drawing(drawing_id: str) -> dict | None:
    if is_demo_mode():
        return next((d for d in _store()["plan_drawings"] if d["id"] == drawing_id), None)
    data = _live_table("plan_drawings").select("*").eq("id", drawing_id).limit(1).execute().data
    return data[0] if data else None


def list_plan_events(drawing_id: str) -> list[dict]:
    if is_demo_mode():
        return sorted([e for e in _store()["plan_events"] if e["drawing_id"] == drawing_id], key=lambda x: x["created_at"], reverse=True)
    return _live_table("plan_appraisal_events").select("*").eq("drawing_id", drawing_id).order("created_at", desc=True).execute().data


def _event(drawing: dict, event_type: str, actor_id: str | None, note: str = ""):
    row = {"id": _uid(), "drawing_id": drawing["id"], "event_type": event_type, "actor_id": actor_id, "note": note, "created_at": date.today()}
    if is_demo_mode():
        _store()["plan_events"].append(row)
    else:
        _live_table("plan_appraisal_events").insert(row).execute()


def _notify(user_id: str | None, title: str, body: str, project_id: str | None = None, link_page: str = ""):
    if not user_id:
        return
    row = {"id": _uid(), "user_id": user_id, "title": title, "body": body, "project_id": project_id, "link_page": link_page, "created_at": date.today(), "read_at": None}
    if is_demo_mode():
        _store()["notifications"].append(row)
    else:
        _live_table("notifications").insert(row).execute()


def _set_drawing(drawing_id: str, **changes) -> dict:
    if is_demo_mode():
        d = get_plan_drawing(drawing_id)
        d.update(changes)
        d["updated_at"] = date.today()
        return d
    return _live_table("plan_drawings").update({**changes, "updated_at": date.today().isoformat()}).eq("id", drawing_id).execute().data[0]


def list_plan_observations(drawing_id: str, open_only: bool = False) -> list[dict]:
    if is_demo_mode():
        rows = [o for o in _store()["plan_observations"] if o["drawing_id"] == drawing_id]
    else:
        rows = _live_table("plan_appraisal_observations").select("*").eq("drawing_id", drawing_id).execute().data
    if open_only:
        rows = [o for o in rows if o["status"] == "open"]
    return rows


def is_project_manager_eligible(project_id: str, user_id: str) -> bool:
    u = q.get_user(user_id)
    return bool(u and u["role"] == cfg.ROLE_DM)


def assign_plan_manager(drawing_id: str, manager_id: str, actor_id: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if not d or not is_project_manager_eligible(d["project_id"], manager_id):
        raise ValueError("Selected Plan Appraisal Manager is not eligible.")
    d = _set_drawing(drawing_id, manager_id=manager_id, status=PA_ASSIGNED_MANAGER)
    _event(d, "MANAGER_ASSIGNED", actor_id, "Plan appraisal handed over to manager")
    create_task(d["project_id"], "PLAN_APPRAISAL_MANAGER_HANDOVER", actor_id, manager_id, drawing_id=drawing_id, note=f'{d["drawing_no"]} · {d["title"]} is ready for manager allocation.')
    return d


def user_disciplines(user_id: str) -> list[str]:
    if is_demo_mode():
        return sorted({a["discipline"] for a in _store()["authorizations"] if a["user_id"] == user_id and a["active"]})
    rows = _live_table("authorization_matrix").select("discipline").eq("user_id", user_id).eq("active", True).execute().data
    return sorted({r["discipline"] for r in rows})


def _eligibility(user_id: str, discipline: str, role: str) -> dict:
    today = date.today()
    if is_demo_mode():
        db = _store()
        u = q.get_user(user_id)
        auth = next((a for a in db["authorizations"] if a["user_id"] == user_id and a["discipline"] == discipline and a["active"]), None)
        comp = next((c for c in db["competencies"] if c["user_id"] == user_id and c["discipline"] == discipline), None)
        avail = next((a for a in db["availability"] if a["user_id"] == user_id and a["work_date"] == today), None)
    else:
        auth_rows = _live_table("authorization_matrix").select("*").eq("user_id", user_id).eq("discipline", discipline).eq("active", True).execute().data
        auth = auth_rows[0] if auth_rows else None
        comp_rows = _live_table("competency_records").select("*").eq("user_id", user_id).eq("discipline", discipline).limit(1).execute().data
        comp = comp_rows[0] if comp_rows else None
        avail_rows = _live_table("resource_availability").select("*").eq("user_id", user_id).eq("work_date", today.isoformat()).limit(1).execute().data
        avail = avail_rows[0] if avail_rows else None
        u = q.get_user(user_id)
    reasons = []
    auth_ok = bool(auth and auth.get("active") and _date_ok(auth.get("valid_until")))
    comp_ok = bool(comp and comp.get("status") == "competent" and _date_ok(comp.get("valid_until")))
    avail_ok = bool(avail and avail.get("status") == "available" and float(avail.get("workload_pct", 100)) < 90)
    role_ok = bool(u and u.get("role") == role)
    if auth_ok: reasons.append("Authorization valid")
    else: reasons.append("Authorization invalid/expired")
    if comp_ok: reasons.append("Competency valid")
    else: reasons.append("Competency missing/expired")
    if avail_ok: reasons.append("Available")
    else: reasons.append("Unavailable / workload ≥ 90%")
    return {"eligible": auth_ok and comp_ok and avail_ok and role_ok, "authorization": auth_ok, "competency": comp_ok, "availability": avail_ok, "role": role_ok, "reasons": reasons}


def _date_ok(value: Any) -> bool:
    if not value:
        return False
    if isinstance(value, date):
        return value >= date.today()
    try:
        return date.fromisoformat(str(value)[:10]) >= date.today()
    except Exception:
        return False


def engineer_eligibility(user_id: str, discipline: str) -> dict:
    return _eligibility(user_id, discipline, cfg.ROLE_ENGINEER)


def surveyor_eligibility(user_id: str, discipline: str) -> dict:
    return _eligibility(user_id, discipline, cfg.ROLE_SURVEYOR)


def eligible_engineers(discipline: str) -> list[dict]:
    return [u for u in q.list_users(role=cfg.ROLE_ENGINEER) if engineer_eligibility(u["id"], discipline)["eligible"]]


def eligible_surveyors(discipline: str) -> list[dict]:
    return [u for u in q.list_users(role=cfg.ROLE_SURVEYOR) if surveyor_eligibility(u["id"], discipline)["eligible"]]


def manager_start_review(drawing_id: str, manager_id: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("manager_id") != manager_id:
        raise ValueError("Only the assigned manager may start this workflow.")
    if d.get("status") == PA_ASSIGNED_MANAGER:
        d = _set_drawing(drawing_id, status=PA_ASSIGNED_MANAGER)
        _event(d, "MANAGER_TASK_ACCEPTED", manager_id)
    return d


def assign_engineer(drawing_id: str, engineer_id: str, actor_id: str) -> dict:
    d = get_plan_drawing(drawing_id)
    check = engineer_eligibility(engineer_id, d["discipline"])
    if not check["eligible"]:
        raise ValueError("Engineer cannot be assigned: " + "; ".join(check["reasons"]))
    d = _set_drawing(drawing_id, engineer_id=engineer_id, status=PA_ASSIGNED_ENGINEER)
    _event(d, "ENGINEER_ASSIGNED", actor_id, "Authorized and competent engineer assigned")
    create_task(d["project_id"], "PLAN_APPRAISAL_ENGINEERING", actor_id, engineer_id, drawing_id=drawing_id, note=f'{d["drawing_no"]} ready for engineering review')
    _notify(engineer_id, "Engineering review assigned", f'{d["drawing_no"]} · {d["title"]} requires your review.', d["project_id"], "workflow_inbox")
    return d


def start_engineer_review(drawing_id: str, actor_id: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("engineer_id") != actor_id:
        raise ValueError("Only the assigned engineer may start this review.")
    d = _set_drawing(drawing_id, status=PA_UNDER_REVIEW)
    _event(d, "ENGINEER_REVIEW_STARTED", actor_id)
    return d


def raise_plan_observation(drawing_id: str, engineer_id: str, description: str, severity: str = "Major") -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("engineer_id") != engineer_id:
        raise ValueError("Only the assigned engineer may raise an observation.")
    row = {"id": _uid(), "drawing_id": drawing_id, "obs_code": f"PA-{len(_store()['plan_observations'])+1:04d}", "description": description, "severity": severity, "status": "open", "raised_by": engineer_id, "raised_at": date.today(), "response": None}
    if is_demo_mode(): _store()["plan_observations"].append(row)
    else: _live_table("plan_appraisal_observations").insert(row).execute()
    d = _set_drawing(drawing_id, status=PA_MANAGER_REVIEW)
    _event(d, "OBSERVATION_RAISED", engineer_id, description)
    if d.get("manager_id"):
        create_task(d["project_id"], "PLAN_APPRAISAL_MANAGER_REVIEW", engineer_id, d["manager_id"], drawing_id=drawing_id, note=f'{d["drawing_no"]}: engineer observation {row["obs_code"]} requires DM appraisal review.')
    return row


def designer_respond(drawing_id: str, designer_id: str, response: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("designer_id") != designer_id:
        raise ValueError("Only the submitting designer may respond.")
    obs = list_plan_observations(drawing_id, open_only=True)
    if not obs:
        raise ValueError("No open observation requires a response.")
    if is_demo_mode():
        for o in obs: o["response"] = response
    else:
        for o in obs: _live_table("plan_appraisal_observations").update({"response": response}).eq("id", o["id"]).execute()
    d = _set_drawing(drawing_id, status=PA_DESIGNER_RESPONSE)
    _event(d, "DESIGNER_RESPONSE", designer_id, response)
    if d.get("engineer_id"):
        _notify(d["engineer_id"], "Designer response received", f'{d["drawing_no"]} has a response ready for re-review.', d["project_id"], "workflow_inbox")
    return d


def resubmit_for_engineer_review(drawing_id: str, actor_id: str, uploaded_file: Any = None) -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("designer_id") != actor_id:
        raise ValueError("Only the designer may resubmit the revised drawing.")
    if uploaded_file is not None:
        rev_row = create_revision_from_upload(d["document_id"], uploaded_file, actor_id)
        d = _set_drawing(drawing_id, revision=int(rev_row["revision"]), current_file_name=rev_row["file_name"], status=PA_REVIEW_RESUBMITTED)
    else:
        d = _set_drawing(drawing_id, revision=int(d["revision"]) + 1, status=PA_REVIEW_RESUBMITTED)
    _event(d, "REVISION_RESUBMITTED", actor_id, f'Revision {d["revision"]}')
    if d.get("engineer_id"):
        create_task(d["project_id"], "PLAN_APPRAISAL_ENGINEERING", actor_id, d["engineer_id"], drawing_id=drawing_id, note=f'{d["drawing_no"]} Rev {d["revision"]} is ready for re-review.')
        _notify(d["engineer_id"], "Revised drawing submitted", f'{d["drawing_no"]} Rev {d["revision"]} is ready for re-review.', d["project_id"], "workflow_inbox")
    return d


def designer_amendment_response(drawing_id: str, designer_id: str, response: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if not d or d.get("designer_id") != designer_id:
        raise ValueError("Only the submitting designer may respond to the amendment.")
    d = _set_drawing(drawing_id, status=PA_DESIGNER_RESPONSE)
    _event(d, "DESIGNER_AMENDMENT_RESPONSE", designer_id, response)
    return d


def engineer_complete_review(drawing_id: str, engineer_id: str, accepted: bool, note: str = "") -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("engineer_id") != engineer_id:
        raise ValueError("Only the assigned engineer may complete this review.")
    if not accepted:
        return raise_plan_observation(drawing_id, engineer_id, note or "Technical correction required", "Major")
    for o in list_plan_observations(drawing_id, open_only=True):
        if is_demo_mode(): o["status"] = "cleared"
        else: _live_table("plan_appraisal_observations").update({"status": "cleared"}).eq("id", o["id"]).execute()
    d = _set_drawing(drawing_id, status=PA_MANAGER_REVIEW)
    _event(d, "ENGINEER_REVIEW_COMPLETED", engineer_id, note)
    if d.get("manager_id"):
        create_task(d["project_id"], "PLAN_APPRAISAL_MANAGER_REVIEW", engineer_id, d["manager_id"], drawing_id=drawing_id, note=f'{d["drawing_no"]} has completed engineering review and is ready for manager review.')
    return d


def manager_forward_to_gm(drawing_id: str, manager_id: str, note: str = "") -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("manager_id") != manager_id:
        raise ValueError("Only the assigned manager may forward this drawing.")
    d = _set_drawing(drawing_id, status=PA_PENDING_GM)
    _event(d, "MANAGER_FORWARDED_TO_GM", manager_id, note)
    gm = q.current_gm()
    _notify(gm["id"], "Plan appraisal awaiting GM approval", f'{d["drawing_no"]} · {d["title"]} is ready for GM decision.', d["project_id"], "plan_appraisal")
    return d


def gm_plan_decision(drawing_id: str, decision: str, note: str, gm_id: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if d.get("status") != PA_PENDING_GM:
        raise ValueError("Drawing is not pending GM approval.")
    if decision == "approved":
        d = _set_drawing(drawing_id, status=PA_APPROVED)
        _event(d, "GM_APPROVED", gm_id, note)
        # Lock the current document revision at approval.
        update_document_revision_status(d["document_id"], d["revision"], "approved")
        if d.get("designer_id"): _notify(d["designer_id"], "Drawing approved", f'{d["drawing_no"]} Rev {d["revision"]} has been approved.', d["project_id"], "plan_appraisal")
    else:
        d = _set_drawing(drawing_id, status=PA_MANAGER_REVIEW)
        _event(d, "GM_RETURNED", gm_id, note)
        if d.get("manager_id"): _notify(d["manager_id"], "GM returned drawing", f'{d["drawing_no"]} requires further manager action: {note}', d["project_id"], "workflow_inbox")
    return d


def plan_progress(status: str) -> float:
    order = [PA_SUBMITTED, PA_ASSIGNED_MANAGER, PA_ASSIGNED_ENGINEER, PA_UNDER_REVIEW, PA_OBSERVATION_RAISED, PA_DESIGNER_RESPONSE, PA_REVIEW_RESUBMITTED, PA_MANAGER_REVIEW, PA_PENDING_GM, PA_APPROVED]
    if status == PA_REJECTED: return 0.0
    return min(1.0, (order.index(status) + 1) / len(order)) if status in order else 0.0

# Document revision control -------------------------------------------------

def list_document_revisions(document_id: str) -> list[dict]:
    if is_demo_mode():
        rows = [r for r in _store()["document_revisions"] if r["document_id"] == document_id]
        if not rows:
            doc = q.get_document(document_id)
            if doc:
                row = {"id": _uid(), "document_id": document_id, "revision": doc.get("version", 1), "file_name": doc["file_name"], "status": doc["status"], "storage_path": doc.get("storage_path"), "created_by": doc.get("uploaded_by"), "created_at": doc.get("uploaded_at", date.today())}
                _store()["document_revisions"].append(row)
                rows = [row]
        return sorted(rows, key=lambda x: x["revision"], reverse=True)
    return _live_table("document_revisions").select("*").eq("document_id", document_id).order("revision", desc=True).execute().data


def create_revision_from_upload(document_id: str, uploaded_file: Any, created_by: str) -> dict:
    """Create a controlled revision from a Streamlit UploadedFile.

    Demo mode records the revision metadata. Live mode also uploads the file
    to Supabase Storage bucket `project-documents` before creating the DB row.
    """
    if uploaded_file is None:
        raise ValueError("Select a file before submitting a revision.")
    file_name = getattr(uploaded_file, "name", "revision.pdf")
    storage_path = ""
    if not is_demo_mode():
        client = get_client()
        document = q.get_document(document_id)
        if not document:
            raise ValueError("Document not found.")
        revisions = list_document_revisions(document_id)
        next_rev = (max([r["revision"] for r in revisions]) + 1) if revisions else 1
        storage_path = f'{document["project_id"]}/{document_id}/rev-{next_rev}/{file_name}'
        content = uploaded_file.getvalue()
        client.storage.from_("project-documents").upload(storage_path, content, {"content-type": getattr(uploaded_file, "type", "application/pdf"), "upsert": "false"})
    return create_document_revision(document_id, file_name, created_by, storage_path, "pending_review")


def create_document_revision(document_id: str, file_name: str, created_by: str, storage_path: str = "", status: str = "pending_review") -> dict:
    revisions = list_document_revisions(document_id)
    next_rev = (max([r["revision"] for r in revisions]) + 1) if revisions else 1
    row = {"id": _uid(), "document_id": document_id, "revision": next_rev, "file_name": file_name, "storage_path": storage_path, "status": status, "created_by": created_by, "created_at": date.today()}
    if is_demo_mode():
        for r in revisions:
            if r["status"] == "current": r["status"] = "superseded"
        _store()["document_revisions"].append(row)
        doc = q.get_document(document_id)
        if doc:
            doc["version"] = next_rev; doc["file_name"] = file_name; doc["status"] = status
    else:
        _live_table("document_revisions").insert(row).execute()
        _live_table("documents").update({"version": next_rev, "file_name": file_name, "status": status, "storage_path": storage_path}).eq("id", document_id).execute()
    return row


def update_document_revision_status(document_id: str, revision: int, status: str) -> None:
    if is_demo_mode():
        for r in _store()["document_revisions"]:
            if r["document_id"] == document_id:
                if r["revision"] == revision: r["status"] = status
                elif status == "approved" and r["revision"] != revision: r["status"] = "superseded"
    else:
        _live_table("document_revisions").update({"status": status}).eq("document_id", document_id).eq("revision", revision).execute()

# Handover / tasks ----------------------------------------------------------

def create_task(project_id: str, task_type: str, from_user_id: str, to_user_id: str, rfi_id: str | None = None, drawing_id: str | None = None, note: str = "") -> dict:
    row = {"id": _uid(), "project_id": project_id, "task_type": task_type, "from_user_id": from_user_id, "to_user_id": to_user_id, "rfi_id": rfi_id, "drawing_id": drawing_id, "status": TASK_PENDING, "note": note, "created_at": date.today(), "accepted_at": None, "completed_at": None}
    if is_demo_mode(): _store()["handover_tasks"].append(row)
    else: _live_table("workflow_tasks").insert(row).execute()
    _notify(to_user_id, "New workflow task", note or task_type.replace("_", " ").title(), project_id, "workflow_inbox")
    return row


def handover_rfi_to_dm(rfi_id: str, dm_id: str, gm_id: str) -> dict:
    rfi = q.get_rfi(rfi_id)
    dm = q.get_user(dm_id)
    if not rfi or not dm or dm.get("role") != cfg.ROLE_DM:
        raise ValueError("Invalid Department Manager selection.")
    if is_demo_mode():
        rfi["assigned_dm_id"] = dm_id; rfi["status"] = cfg.RFI_ALLOCATED
    else:
        _live_table("rfis").update({"assigned_dm_id": dm_id, "status": cfg.RFI_ALLOCATED}).eq("id", rfi_id).execute()
    task = create_task(rfi["project_id"], "SURVEY_RFI_HANDOVER", gm_id, dm_id, rfi_id=rfi_id, note=f'{rfi["rfi_code"]} has been handed over by GM for departmental action.')
    if is_demo_mode(): q._log(rfi["project_id"], gm_id, "RFI_HANDED_TO_DM", {"rfi_code": rfi["rfi_code"], "dm_id": dm_id})
    return task


def list_tasks_for_user(user_id: str) -> list[dict]:
    if is_demo_mode():
        return sorted([t for t in _store()["handover_tasks"] if t["to_user_id"] == user_id and t["status"] in (TASK_PENDING, TASK_ACCEPTED, TASK_IN_PROGRESS)], key=lambda x: x["created_at"], reverse=True)
    return _live_table("workflow_tasks").select("*").eq("to_user_id", user_id).in_("status", [TASK_PENDING, TASK_ACCEPTED, TASK_IN_PROGRESS]).order("created_at", desc=True).execute().data


def accept_task(task_id: str, actor_id: str) -> dict:
    if is_demo_mode():
        t = next(t for t in _store()["handover_tasks"] if t["id"] == task_id)
        if t["to_user_id"] != actor_id: raise ValueError("This task is assigned to another user.")
        t["status"] = TASK_ACCEPTED; t["accepted_at"] = date.today(); return t
    return _live_table("workflow_tasks").update({"status": TASK_ACCEPTED, "accepted_at": date.today().isoformat()}).eq("id", task_id).eq("to_user_id", actor_id).execute().data[0]

# Notifications ------------------------------------------------------------

def list_notifications(user_id: str) -> list[dict]:
    if is_demo_mode():
        return sorted([n for n in _store()["notifications"] if n["user_id"] == user_id], key=lambda x: x["created_at"], reverse=True)
    return _live_table("notifications").select("*").eq("user_id", user_id).order("created_at", desc=True).execute().data


def mark_notification_read(notification_id: str, user_id: str) -> None:
    if is_demo_mode():
        n = next((n for n in _store()["notifications"] if n["id"] == notification_id and n["user_id"] == user_id), None)
        if n: n["read_at"] = date.today()
    else:
        _live_table("notifications").update({"read_at": date.today().isoformat()}).eq("id", notification_id).eq("user_id", user_id).execute()

# ---------------------------------------------------------------------------
# Department Manager workflow — exact DM flowchart branches
# ---------------------------------------------------------------------------

def survey_discipline_for_rfi(rfi: dict) -> str:
    """Map a survey request to the default specialist discipline."""
    stype = str(rfi.get("survey_type", "")).lower()
    if "fire" in stype or "lsa" in stype or stype == "ftp":
        return "Fire & LSA"
    if "machinery" in stype or stype == "itp":
        return "Machinery"
    if "electrical" in stype:
        return "Electrical"
    if "stability" in stype:
        return "Stability"
    return "Hull & Structure"


def assign_surveyor(rfi_id: str, surveyor_id: str, manager_id: str, discipline: str, scheduled_date: Any = None) -> dict:
    rfi = q.get_rfi(rfi_id)
    if not rfi or rfi.get("assigned_dm_id") != manager_id:
        raise ValueError("Only the assigned Department Manager may assign this survey.")
    check = surveyor_eligibility(surveyor_id, discipline)
    if not check["eligible"]:
        raise ValueError("Surveyor cannot be assigned: " + "; ".join(check["reasons"]))
    scheduled = scheduled_date or date.today()
    if is_demo_mode():
        raw = q._db()["rfis"]
        row = next(x for x in raw if x["id"] == rfi_id)
        row["assigned_surveyor_id"] = surveyor_id
        row["scheduled_date"] = scheduled
        row["status"] = cfg.RFI_SURVEY_IN_PROGRESS
        _event_like_rfi(row, "SURVEYOR_ASSIGNED", manager_id, f"Authorized surveyor assigned: {surveyor_id}")
    else:
        # v2.3: assignment and controlled approved-drawing handover are one
        # server-side transaction. The UI passes the selected relevant drawing IDs
        # through session state; the RPC revalidates approval, project and role.
        drawing_ids = st.session_state.get(f"survey_drawings_{rfi_id}", [])
        get_client().rpc("epas_assign_surveyor_with_drawings", {
            "p_rfi_id": rfi_id,
            "p_surveyor_id": surveyor_id,
            "p_scheduled_date": str(scheduled),
            "p_drawing_ids": drawing_ids,
            "p_discipline": discipline,
        }).execute()
    if is_demo_mode():
        package = _store().setdefault("survey_rfi_drawings", [])
        drawing_ids = st.session_state.get(f"survey_drawings_{rfi_id}", [])
        for did in drawing_ids:
            package.append({"id": _uid(), "rfi_id": rfi_id, "drawing_id": did, "surveyor_id": surveyor_id, "granted_by": manager_id, "granted_at": date.today(), "revoked_at": None})
        create_task(rfi["project_id"], "SURVEY_RFI_EXECUTION", manager_id, surveyor_id, rfi_id=rfi_id, note=f'{rfi["rfi_code"]} survey assigned for {scheduled}; approved drawing package handed over.')
    return q.get_rfi(rfi_id)


def _event_like_rfi(rfi: dict, event_type: str, actor_id: str, note: str = "") -> None:
    if is_demo_mode():
        q._log(rfi["project_id"], actor_id, event_type, {"rfi_code": rfi["rfi_code"], "note": note})


def submit_survey_report(rfi_id: str, surveyor_id: str, report_note: str, observations: list[dict] | None = None) -> dict:
    rfi = q.get_rfi(rfi_id)
    if not rfi or rfi.get("assigned_surveyor_id") != surveyor_id:
        raise ValueError("Only the assigned surveyor may submit this survey report.")
    observations = observations or []
    if is_demo_mode():
        db = _store()
        db.setdefault("survey_reports", [])
        report = {"id": _uid(), "rfi_id": rfi_id, "surveyor_id": surveyor_id, "report_note": report_note, "submitted_at": date.today()}
        db["survey_reports"] = [x for x in db["survey_reports"] if x["rfi_id"] != rfi_id]
        db["survey_reports"].append(report)
        raw = next(x for x in q._db()["rfis"] if x["id"] == rfi_id)
        for item in observations:
            idx = len(q._db()["observations"]) + 1
            q._db()["observations"].append({
                "id": _uid(), "rfi_id": rfi_id, "obs_code": item.get("obs_code") or f"OBS-{idx:04d}",
                "description": item["description"], "severity": item.get("severity", "Minor"),
                "status": cfg.OBS_OPEN, "raised_by": surveyor_id, "raised_at": date.today(),
            })
        raw["status"] = cfg.RFI_OBSERVATIONS_LOGGED
    else:
        report = _live_table("survey_reports").insert({"rfi_id": rfi_id, "surveyor_id": surveyor_id, "report_note": report_note}).execute().data[0]
        for item in observations:
            _live_table("observations").insert({"rfi_id": rfi_id, "obs_code": item.get("obs_code") or f"OBS-{uuid.uuid4().hex[:8].upper()}", "description": item["description"], "severity": item.get("severity", "Minor"), "status": "open", "raised_by": surveyor_id}).execute()
        _live_table("rfis").update({"status": cfg.RFI_OBSERVATIONS_LOGGED}).eq("id", rfi_id).execute()
    rfi = q.get_rfi(rfi_id)
    if rfi.get("assigned_dm_id"):
        create_task(rfi["project_id"], "SURVEY_DM_REVIEW", surveyor_id, rfi["assigned_dm_id"], rfi_id=rfi_id, note=f'{rfi["rfi_code"]} survey report is ready for DM review.')
    _event_like_rfi(rfi, "SURVEY_REPORT_SUBMITTED", surveyor_id, report_note)
    return report


def get_survey_report(rfi_id: str) -> dict | None:
    if is_demo_mode():
        return next((x for x in _store().get("survey_reports", []) if x["rfi_id"] == rfi_id), None)
    rows = _live_table("survey_reports").select("*").eq("rfi_id", rfi_id).order("submitted_at", desc=True).limit(1).execute().data
    return rows[0] if rows else None


def dm_review_and_forward_survey(rfi_id: str, manager_id: str, remarks: str = "") -> dict:
    rfi = q.get_rfi(rfi_id)
    if not rfi or rfi.get("assigned_dm_id") != manager_id:
        raise ValueError("Only the assigned Department Manager may review this survey.")
    open_obs = q.open_observations(rfi_id)
    # Both clean and observation-bearing reports are forwarded to the GM. The
    # observation state determines whether the GM's certificate decision is
    # full class or interim.
    if is_demo_mode():
        raw = next(x for x in q._db()["rfis"] if x["id"] == rfi_id)
        raw["status"] = cfg.RFI_PENDING_GM_APPROVAL
    else:
        _live_table("rfis").update({"status": cfg.RFI_PENDING_GM_APPROVAL}).eq("id", rfi_id).execute()
    _event_like_rfi(rfi, "DM_FORWARDED_TO_GM", manager_id, remarks)
    gm = q.current_gm()
    _notify(gm["id"], "Survey RFI awaiting GM approval", f'{rfi["rfi_code"]} has been reviewed by the DM and is ready for GM decision.', rfi["project_id"], "rfi_nsc" if rfi["phase"] == cfg.PHASE_NSC_SURVEY else "rfi_in_service")
    return q.get_rfi(rfi_id)


def route_gm_return_to_dm(rfi_id: str, gm_id: str, note: str) -> dict:
    rfi = q.get_rfi(rfi_id)
    if not rfi or not rfi.get("assigned_dm_id"):
        return rfi or {}
    task = create_task(rfi["project_id"], "SURVEY_CORRECTIVE_ACTION", gm_id, rfi["assigned_dm_id"], rfi_id=rfi_id, note=f'{rfi["rfi_code"]} returned by GM. Corrective action required: {note}')
    return task


def create_followup_rfi(rfi_id: str, manager_id: str, instruction: str = "") -> dict:
    parent = q.get_rfi(rfi_id)
    if not parent or parent.get("assigned_dm_id") != manager_id:
        raise ValueError("Only the assigned Department Manager may create a follow-up RFI.")
    if is_demo_mode():
        row = q.create_rfi(parent["project_id"], parent["vessel_id"], parent["phase"], parent["survey_type"], parent.get("requested_by") or manager_id, parent.get("priority", "medium"))
        raw = next(x for x in q._db()["rfis"] if x["id"] == row["id"])
        raw["assigned_dm_id"] = manager_id
        raw["status"] = cfg.RFI_ALLOCATED
        raw["scheduled_date"] = None
        _event_like_rfi(raw, "FOLLOW_UP_RFI_CREATED", manager_id, instruction)
        create_task(raw["project_id"], "SURVEY_RFI_HANDOVER", manager_id, manager_id, rfi_id=raw["id"], note=f'{raw["rfi_code"]} follow-up RFI created. Review scope and assign an authorized surveyor.')
        return q.get_rfi(raw["id"])
    # Live mode: create through Supabase directly because the legacy helper is demo-only.
    data = _live_table("rfis").insert({"project_id": parent["project_id"], "vessel_id": parent["vessel_id"], "phase": parent["phase"], "survey_type": parent["survey_type"], "rfi_code": f"FU-{uuid.uuid4().hex[:8].upper()}", "status": cfg.RFI_ALLOCATED, "requested_by": parent.get("requested_by"), "assigned_dm_id": manager_id, "priority": parent.get("priority", "medium")}).execute().data[0]
    create_task(data["project_id"], "SURVEY_RFI_HANDOVER", manager_id, manager_id, rfi_id=data["id"], note=f'{data["rfi_code"]} follow-up RFI created. Review scope and assign an authorized surveyor.')
    return data


def manager_return_to_engineer(drawing_id: str, manager_id: str, feedback: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if not d or d.get("manager_id") != manager_id or not d.get("engineer_id"):
        raise ValueError("Only the assigned manager may return this appraisal to its engineer.")
    d = _set_drawing(drawing_id, status=PA_ASSIGNED_ENGINEER)
    _event(d, "MANAGER_SENT_BACK_TO_ENGINEER", manager_id, feedback)
    create_task(d["project_id"], "PLAN_APPRAISAL_ENGINEER_FEEDBACK", manager_id, d["engineer_id"], drawing_id=drawing_id, note=feedback)
    _notify(d["engineer_id"], "DM feedback on appraisal", f'{d["drawing_no"]}: {feedback}', d["project_id"], "workflow_inbox")
    return d


def manager_review_decision(drawing_id: str, manager_id: str, decision: str, note: str) -> dict:
    d = get_plan_drawing(drawing_id)
    if not d or d.get("manager_id") != manager_id:
        raise ValueError("Only the assigned manager may decide this appraisal.")
    if decision == "Appraisal Approved":
        return manager_forward_to_gm(drawing_id, manager_id, note)
    if decision == "Appraisal Requires Changes":
        return manager_return_to_engineer(drawing_id, manager_id, note)
    # Design rejected/amended: DM escalates to GM to notify the Designer.
    d = _set_drawing(drawing_id, status=PA_REJECTED)
    _event(d, "DESIGN_REJECTED_OR_AMENDED", manager_id, note)
    gm = q.current_gm()
    create_task(d["project_id"], "PLAN_APPRAISAL_GM_DESIGNER_CORRECTION", manager_id, gm["id"], drawing_id=drawing_id, note=f'{d["drawing_no"]} requires designer amendment/rejection action: {note}')
    _notify(gm["id"], "Plan appraisal design amendment required", f'{d["drawing_no"]} requires GM action to send the drawing to the Designer.', d["project_id"], "plan_appraisal")
    return d


def complete_task(task_id: str, actor_id: str) -> dict:
    if is_demo_mode():
        t = next((x for x in _store()["handover_tasks"] if x["id"] == task_id), None)
        if not t or t["to_user_id"] != actor_id:
            raise ValueError("Task is not assigned to this user.")
        t["status"] = TASK_COMPLETED
        t["completed_at"] = date.today()
        return t
    rows = _live_table("workflow_tasks").update({"status": TASK_COMPLETED, "completed_at": date.today().isoformat()}).eq("id", task_id).eq("to_user_id", actor_id).execute().data
    return rows[0] if rows else {}


def gm_send_to_designer(drawing_id: str, gm_id: str, note: str = "") -> dict:
    d = get_plan_drawing(drawing_id)
    if not d or d.get("status") not in (PA_REJECTED, PA_PENDING_GM):
        raise ValueError("This drawing is not awaiting GM designer-correction action.")
    if not d.get("designer_id"):
        raise ValueError("No Designer is linked to this drawing.")
    d = _set_drawing(drawing_id, status=PA_DESIGNER_RESPONSE)
    _event(d, "GM_SENT_TO_DESIGNER", gm_id, note)
    create_task(d["project_id"], "PLAN_APPRAISAL_DESIGNER_RESPONSE", gm_id, d["designer_id"], drawing_id=drawing_id, note=f'{d["drawing_no"]} requires correction / amendment: {note}')
    _notify(d["designer_id"], "Drawing correction required", f'{d["drawing_no"]} requires correction / amendment before resubmission.', d["project_id"], "workflow_inbox")
    return d
