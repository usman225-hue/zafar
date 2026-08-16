"""
EPAS · Query & Mutation Layer
------------------------------
Every read AND every state transition from the flowchart lives here:

    - assign_rfi_to_dm()   → "GM clicks [ASSIGN TO DM]" node
    - gm_decide()           → "GM Approval Decision" diamond (Send Back / Approve)
    - issue_certificate()   → "GM issues CLASS / INTERIM CERTIFICATE" nodes,
                               gated by "Are there any open observations?"

Components never mutate state directly — they always call a function
here, which enforces the same rules a real backend (Supabase RPC /
Postgres function) would enforce. This is deliberate: swapping demo
mode for live Supabase later means rewriting the *bodies* of these
functions, not the callers.

DEMO MODE:
    State lives in `st.session_state["_db"]`, seeded once from
    `seed_data.build_seed_db()`. Because it's session_state, every
    click really mutates the working set for that browser session —
    the RFI queue, KPI counts, and Ship Register all update live.

LIVE MODE:
    Each function below has a `# LIVE:` comment block showing the
    equivalent supabase-py call. Wire these in once your schema
    (see database/schema.sql) is deployed and RLS/auth is configured.
"""

from __future__ import annotations

import uuid
from datetime import date, timedelta

import streamlit as st

from config import settings as cfg
from config.supabase_client import get_client, is_demo_mode
from database.seed_data import build_seed_db


# =========================================================================
# DEMO STORE
# =========================================================================

def _db() -> dict:
    if "_db" not in st.session_state:
        st.session_state["_db"] = build_seed_db()
    return st.session_state["_db"]


def _next_code(kind: str) -> str:
    db = _db()
    db["_counters"][kind] += 1
    n = db["_counters"][kind]
    year = date.today().year
    if kind == "rfi":
        return f"RFI-{year}-{n:03d}"
    if kind == "obs":
        return f"OBS-{n:04d}"
    if kind == "cert":
        return f"{n:04d}"
    return str(n)


def _log(project_id: str, actor_id: str, action: str, details: dict | None = None):
    _db()["audit_log"].append({
        "id": str(uuid.uuid4()), "project_id": project_id, "actor_id": actor_id,
        "action": action, "details": details or {}, "created_at": date.today(),
    })


def current_gm() -> dict:
    """Return the authenticated GM profile in live mode, seed GM in demo mode."""
    if is_demo_mode():
        return next(p for p in _db()["profiles"] if p["role"] == "gm")
    client = get_client()
    try:
        auth_user = client.auth.get_user().user
        row = client.table("profiles").select("*").eq("id", auth_user.id).limit(1).execute().data
        if row:
            return row[0]
    except Exception:
        pass
    raise RuntimeError("Authenticated GM profile was not found.")


# =========================================================================
# PROFILES / TEAM LOOKUPS
# =========================================================================

def list_users(role: str | None = None) -> list[dict]:
    if is_demo_mode():
        users = _db()["profiles"]
        return [u for u in users if role is None or u["role"] == role]

    client = get_client()
    query = client.table("profiles").select("*")
    if role:
        query = query.eq("role", role)
    return query.execute().data


def get_user(user_id: str | None) -> dict | None:
    if user_id is None:
        return None
    if is_demo_mode():
        return next((u for u in _db()["profiles"] if u["id"] == user_id), None)
    data = get_client().table("profiles").select("*").eq("id", user_id).limit(1).execute().data
    return data[0] if data else None


# =========================================================================
# PROJECTS
# =========================================================================

def list_projects(status: str | None = None) -> list[dict]:
    if is_demo_mode():
        rows = _db()["projects"]
        if status and status != "all":
            rows = [p for p in rows if p["status"] == status]
        return sorted(rows, key=lambda p: p["created_at"], reverse=True)

    query = get_client().table("projects").select("*")
    if status and status != "all":
        query = query.eq("status", status)
    return query.order("created_at", desc=True).execute().data


def get_project(project_id: str) -> dict | None:
    if is_demo_mode():
        return next((p for p in _db()["projects"] if p["id"] == project_id), None)
    data = get_client().table("projects").select("*").eq("id", project_id).limit(1).execute().data
    return data[0] if data else None


def get_vessel_for_project(project_id: str) -> dict | None:
    if is_demo_mode():
        return next((v for v in _db()["vessels"] if v["project_id"] == project_id), None)
    data = get_client().table("vessels").select("*").eq("project_id", project_id).limit(1).execute().data
    return data[0] if data else None


def get_vessel(vessel_id: str) -> dict | None:
    if is_demo_mode():
        return next((v for v in _db()["vessels"] if v["id"] == vessel_id), None)
    data = get_client().table("vessels").select("*").eq("id", vessel_id).limit(1).execute().data
    return data[0] if data else None


def list_vessels() -> list[dict]:
    if is_demo_mode():
        return list(_db()["vessels"])
    return get_client().table("vessels").select("*").order("name").execute().data


def list_team(project_id: str) -> list[dict]:
    if is_demo_mode():
        rows = [t for t in _db()["team_assignments"] if t["project_id"] == project_id]
        for r in rows:
            r["_user"] = get_user(r["user_id"])
        return rows
    rows = get_client().table("team_assignments").select("*").eq("project_id", project_id).execute().data
    for r in rows:
        r["_user"] = get_user(r.get("user_id"))
    return rows


def list_stakeholders(project_id: str) -> list[dict]:
    if is_demo_mode():
        return [s for s in _db()["stakeholders"] if s["project_id"] == project_id]
    return get_client().table("stakeholders").select("*").eq("project_id", project_id).execute().data


def create_project(payload: dict) -> dict:
    """
    payload keys: name, vessel_type, flag_state, phases (list),
                  vessel: {..particulars..}, team: [{user_id, role, discipline}],
                  stakeholders: [{company_name, contact_name, contact_email, stakeholder_type}],
                  documents: [{category, file_name}]
    Mirrors wizard Steps 1–5 exactly, in one atomic call.
    """
    if is_demo_mode():
        db = _db()
        n_existing = len(db["projects"]) + 1
        project = {
            "id": str(uuid.uuid4()),
            "project_code": payload.get("project_code") or f"P-{2027}{n_existing:03d}",
            "name": payload["name"],
            "vessel_type": payload["vessel_type"],
            "flag_state": payload["flag_state"],
            "phases": payload["phases"],
            "status": cfg.PROJECT_STATUS_ACTIVE,
            "created_by": current_gm()["id"],
            "created_at": date.today(),
        }
        db["projects"].append(project)

        vessel_payload = payload.get("vessel", {})
        vessel = {
            "id": str(uuid.uuid4()), "project_id": project["id"],
            "name": vessel_payload.get("name", payload["name"]),
            "imo_number": vessel_payload.get("imo_number", "—"),
            "flag_state": payload["flag_state"],
            "loa_m": vessel_payload.get("loa_m"), "beam_m": vessel_payload.get("beam_m"),
            "draft_m": vessel_payload.get("draft_m"), "power_kw": vessel_payload.get("power_kw"),
            "speed_knots": vessel_payload.get("speed_knots"),
            "build_year": vessel_payload.get("build_year", date.today().year),
            "owner_company": vessel_payload.get("owner_company", "—"),
            "current_class": "Classification Authority (pending)",
        }
        db["vessels"].append(vessel)

        for t in payload.get("team", []):
            db["team_assignments"].append({
                "id": str(uuid.uuid4()), "project_id": project["id"],
                "user_id": t.get("user_id"), "role": t["role"], "discipline": t.get("discipline"),
            })

        for s in payload.get("stakeholders", []):
            if not s.get("company_name"):
                continue
            db["stakeholders"].append({
                "id": str(uuid.uuid4()), "project_id": project["id"],
                "company_name": s["company_name"], "contact_name": s.get("contact_name", ""),
                "contact_email": s.get("contact_email", ""), "stakeholder_type": s["stakeholder_type"],
            })

        for d in payload.get("documents", []):
            db["documents"].append({
                "id": str(uuid.uuid4()), "project_id": project["id"],
                "category": d["category"], "file_name": d["file_name"], "version": 1,
                "status": "pending_review", "uploaded_by": current_gm()["id"], "uploaded_at": date.today(),
            })

        _log(project["id"], current_gm()["id"], "PROJECT_CREATED", {"project_code": project["project_code"]})
        return project

    # LIVE: wrap the above in a Postgres RPC / transaction for atomicity.
    return {}


# =========================================================================
# DOCUMENTS
# =========================================================================

def list_documents(project_id: str) -> list[dict]:
    if is_demo_mode():
        return [d for d in _db()["documents"] if d["project_id"] == project_id]
    return get_client().table("documents").select("*").eq("project_id", project_id).order("uploaded_at", desc=True).execute().data


def get_document(document_id: str) -> dict | None:
    if is_demo_mode():
        return next((d for d in _db()["documents"] if d["id"] == document_id), None)
    data = get_client().table("documents").select("*").eq("id", document_id).limit(1).execute().data
    return data[0] if data else None


def list_document_remarks(document_id: str) -> list[dict]:
    if is_demo_mode():
        rows = [r for r in _db()["document_remarks"] if r["document_id"] == document_id]
        for r in rows:
            r["_author"] = get_user(r["author_id"])
        return sorted(rows, key=lambda r: r["created_at"])
    return []


def add_document_remark(document_id: str, author_id: str, body: str) -> dict:
    if is_demo_mode():
        row = {"id": str(uuid.uuid4()), "document_id": document_id, "author_id": author_id,
               "body": body, "created_at": date.today()}
        _db()["document_remarks"].append(row)
        return row
    return {}


def update_document_status(document_id: str, status: str) -> dict:
    if is_demo_mode():
        doc = next(d for d in _db()["documents"] if d["id"] == document_id)
        doc["status"] = status
        _log(doc["project_id"], current_gm()["id"], "DOCUMENT_STATUS_CHANGED",
             {"file_name": doc["file_name"], "status": status})
        return doc
    return {}


# =========================================================================
# PROJECT PHASE ORCHESTRATION / VESSEL SURVEY STATUS
# =========================================================================

def project_phase_status(project_id: str) -> list[dict]:
    """Return the executable phase roadmap. Demo mode mirrors the same gates
    used by the production SQL: Plan Appraisal -> NSC -> In-Service when
    those phases are selected. A missing preceding phase is skipped."""
    project = get_project(project_id)
    if not project:
        return []
    phases = project.get("phases", [])
    if not is_demo_mode():
        try:
            rows = get_client().rpc("epas_project_phase_status", {"p_project_id": project_id}).execute().data or []
            return rows
        except Exception:
            pass

    out = []
    order = [cfg.PHASE_PLAN_APPRAISAL, cfg.PHASE_NSC_SURVEY, cfg.PHASE_IN_SERVICE]
    labels = {cfg.PHASE_PLAN_APPRAISAL: "Plan Appraisal", cfg.PHASE_NSC_SURVEY: "NSC Survey", cfg.PHASE_IN_SERVICE: "In-Service Survey"}
    completed = {}
    for ph in order:
        if ph not in phases:
            out.append({"phase": ph, "sequence_no": order.index(ph)+1, "status": "NOT_APPLICABLE", "gate_passed": False, "gate_note": "Not selected for this project"})
            continue
        if ph == cfg.PHASE_PLAN_APPRAISAL:
            # Demo plan_drawings may be absent; use the existing appraisal helper when available.
            try:
                from database import upgrade_queries as uq
                drawings = uq.list_plan_drawings(project_id)
                approved = [d for d in drawings if d.get("status") == uq.PA_APPROVED]
                open_obs = sum(len(uq.list_plan_observations(d["id"], open_only=True)) for d in drawings)
                done = bool(drawings) and len(drawings) == len(approved) and open_obs == 0
            except Exception:
                done = False
            status = "COMPLETED" if done else "IN_PROGRESS"
            note = "All drawings approved and no open plan observations remain" if done else "Plan Appraisal is still in progress"
        else:
            rfis = list_rfis(phase=ph, project_id=project_id)
            done_rfis = [r for r in rfis if r.get("status") in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED)]
            open_obs = sum(len([o for o in r.get("_observations", []) if o.get("status") == cfg.OBS_OPEN]) for r in rfis)
            done = bool(rfis) and len(done_rfis) == len(rfis) and open_obs == 0
            predecessor = cfg.PHASE_NSC_SURVEY if ph == cfg.PHASE_IN_SERVICE and cfg.PHASE_NSC_SURVEY in phases else (cfg.PHASE_PLAN_APPRAISAL if cfg.PHASE_PLAN_APPRAISAL in phases else None)
            if predecessor and not completed.get(predecessor, False):
                status, gate, note = "LOCKED", False, f"Waiting for {labels[predecessor]} completion"
            elif done:
                status, gate, note = "COMPLETED", True, f"{labels[ph]} cycle is closed"
            elif rfis:
                status, gate, note = "IN_PROGRESS", False, f"{len(done_rfis)}/{len(rfis)} RFI(s) closed; open observations: {open_obs}"
            else:
                status, gate, note = "READY", True, f"Ready for {labels[ph]} RFI initiation"
        if ph == cfg.PHASE_PLAN_APPRAISAL:
            completed[ph] = status == "COMPLETED"
        else:
            completed[ph] = status == "COMPLETED"
        out.append({"phase": ph, "sequence_no": order.index(ph)+1, "status": status, "gate_passed": status in ("READY", "COMPLETED"), "gate_note": note})
    return out


def vessel_survey_status(vessel_id: str) -> dict:
    vessel = get_vessel(vessel_id)
    if not vessel:
        return {}
    if not is_demo_mode():
        try:
            rows = get_client().from_("epas_ship_register").select("*").eq("vessel_id", vessel_id).limit(1).execute().data or []
            if rows:
                return rows[0]
        except Exception:
            pass
    project = get_project(vessel.get("project_id"))
    rfis = [r for r in list_rfis() if r.get("vessel_id") == vessel_id]
    certs = list_certificates(vessel_id=vessel_id)
    status = vessel.get("survey_status", "NOT_STARTED")
    if project:
        if project.get("status") == cfg.PROJECT_STATUS_CLOSED:
            status = "PROJECT_CLOSED"
        elif any(r.get("phase") == cfg.PHASE_IN_SERVICE and r.get("status") not in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED) for r in rfis):
            status = "IN_SERVICE_IN_PROGRESS"
        elif any(r.get("phase") == cfg.PHASE_NSC_SURVEY and r.get("status") not in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED) for r in rfis):
            status = "NSC_IN_PROGRESS"
        elif cfg.PHASE_IN_SERVICE in project.get("phases", []) and not any(r.get("phase") == cfg.PHASE_IN_SERVICE for r in rfis):
            status = "IN_SERVICE_DUE"
        elif cfg.PHASE_NSC_SURVEY in project.get("phases", []) and any(r.get("phase") == cfg.PHASE_NSC_SURVEY and r.get("status") in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED) for r in rfis):
            status = "CLASS_ACTIVE"
    latest = certs[0] if certs else None
    return {"vessel_id": vessel_id, "project_id": vessel.get("project_id"), "vessel": vessel,
            "survey_status": status, "next_survey_due": vessel.get("next_survey_due") or (latest.get("expiry_date") if latest else None),
            "last_survey_date": vessel.get("last_survey_date"), "last_survey_phase": vessel.get("last_survey_phase"),
            "latest_cert": latest, "survey_history": rfis}


# =========================================================================
# RFIs  — the workflow spine
# =========================================================================

def list_rfis(phase: str | None = None, status: str | list[str] | None = None,
              project_id: str | None = None) -> list[dict]:
    if is_demo_mode():
        rows = list(_db()["rfis"])
        if phase:
            rows = [r for r in rows if r["phase"] == phase]
        if project_id:
            rows = [r for r in rows if r["project_id"] == project_id]
        if status:
            wanted = {status} if isinstance(status, str) else set(status)
            rows = [r for r in rows if r["status"] in wanted]
        # enrich for display
        for r in rows:
            r["_project"] = get_project(r["project_id"])
            r["_vessel"] = get_vessel(r["vessel_id"])
            r["_dm"] = get_user(r.get("assigned_dm_id"))
            r["_surveyor"] = get_user(r.get("assigned_surveyor_id"))
            r["_observations"] = list_observations(r["id"])
        return sorted(rows, key=lambda r: r["created_at"], reverse=True)
    rows = get_client().table("rfis").select("*").order("created_at", desc=True).execute().data
    if phase:
        rows = [r for r in rows if r.get("phase") == phase]
    if project_id:
        rows = [r for r in rows if r.get("project_id") == project_id]
    if status:
        wanted = {status} if isinstance(status, str) else set(status)
        rows = [r for r in rows if r.get("status") in wanted]
    for r in rows:
        r["_project"] = get_project(r.get("project_id"))
        r["_vessel"] = get_vessel(r.get("vessel_id"))
        r["_dm"] = get_user(r.get("assigned_dm_id"))
        r["_surveyor"] = get_user(r.get("assigned_surveyor_id"))
        r["_observations"] = list_observations(r["id"])
    return rows


def get_rfi(rfi_id: str) -> dict | None:
    rows = list_rfis()
    return next((r for r in rows if r["id"] == rfi_id), None)


def list_observations(rfi_id: str) -> list[dict]:
    if is_demo_mode():
        return [o for o in _db()["observations"] if o["rfi_id"] == rfi_id]
    return get_client().table("observations").select("*").eq("rfi_id", rfi_id).order("raised_at", desc=True).execute().data


def open_observations(rfi_id: str) -> list[dict]:
    return [o for o in list_observations(rfi_id) if o["status"] == cfg.OBS_OPEN]


def gm_actionable_rfis() -> list[dict]:
    """RFIs sitting in a stage that needs a GM click right now."""
    return list_rfis(status=list(cfg.RFI_GM_ACTIONABLE))


def create_rfi(project_id: str, vessel_id: str, phase: str, survey_type: str,
               requested_by: str, priority: str = "medium") -> dict:
    if is_demo_mode():
        row = {
            "id": str(uuid.uuid4()), "project_id": project_id, "vessel_id": vessel_id,
            "phase": phase, "survey_type": survey_type, "rfi_code": _next_code("rfi"),
            "status": cfg.RFI_PENDING_ALLOCATION, "requested_by": requested_by,
            "assigned_dm_id": None, "assigned_surveyor_id": None,
            "requested_date": date.today(), "scheduled_date": None, "priority": priority,
            "created_at": date.today(),
        }
        _db()["rfis"].append(row)
        _log(project_id, current_gm()["id"], "RFI_RECEIVED", {"rfi_code": row["rfi_code"]})
        return row
    return {}


def assign_rfi_to_dm(rfi_id: str, dm_id: str) -> dict:
    """'GM clicks [ASSIGN TO DM]' → status becomes allocated_to_dm."""
    if is_demo_mode():
        rfi = next(r for r in _db()["rfis"] if r["id"] == rfi_id)
        rfi["assigned_dm_id"] = dm_id
        rfi["status"] = cfg.RFI_ALLOCATED
        _log(rfi["project_id"], current_gm()["id"], "RFI_ASSIGNED",
             {"rfi_code": rfi["rfi_code"], "dm_id": dm_id})
        return rfi
    return {}


def dev_advance_stage(rfi_id: str) -> dict:
    """
    DEMO-ONLY helper: simulates the off-screen actions of the DM and
    Surveyor (allocated → survey in progress → observations logged →
    forwarded to GM) so the full loop can be exercised from a
    GM-only dashboard. Clearly separated from real GM actions.
    """
    if not is_demo_mode():
        return {}
    rfi = next(r for r in _db()["rfis"] if r["id"] == rfi_id)
    order = [cfg.RFI_ALLOCATED, cfg.RFI_SURVEY_IN_PROGRESS,
             cfg.RFI_OBSERVATIONS_LOGGED, cfg.RFI_PENDING_GM_APPROVAL]
    if rfi["status"] not in order:
        return rfi
    idx = order.index(rfi["status"])
    if idx == 0:
        rfi["status"] = cfg.RFI_SURVEY_IN_PROGRESS
        rfi["scheduled_date"] = date.today()
    elif idx == 1:
        rfi["status"] = cfg.RFI_OBSERVATIONS_LOGGED
        # 50/50 deterministic-ish: give it one open observation for variety
        _db()["observations"].append({
            "id": str(uuid.uuid4()), "rfi_id": rfi["id"], "obs_code": _next_code("obs"),
            "description": "Simulated field observation — surface corrosion noted during inspection.",
            "severity": "Minor", "status": cfg.OBS_OPEN,
            "raised_by": rfi.get("assigned_surveyor_id"), "raised_at": date.today(),
        })
    elif idx == 2:
        rfi["status"] = cfg.RFI_PENDING_GM_APPROVAL
    _log(rfi["project_id"], current_gm()["id"], "DEMO_STAGE_ADVANCED", {"rfi_code": rfi["rfi_code"]})
    return rfi


def gm_decide(rfi_id: str, decision: str, note: str = "") -> dict:
    """
    'GM Approval Decision' diamond.

    decision == "sent_back"  → status = sent_back_for_rework, loops to DM.
    decision == "approved"   → evaluate "Are there any open observations?"
                                  NO  → approved_no_observations (Full Certificate Eligible)
                                  YES → approved_with_observations (Interim Certificate Required)
    """
    if not is_demo_mode():
        return {}
    rfi = next(r for r in _db()["rfis"] if r["id"] == rfi_id)

    _db()["gm_decisions"].append({
        "id": str(uuid.uuid4()), "rfi_id": rfi_id, "decided_by": current_gm()["id"],
        "decision": decision, "note": note, "decided_at": date.today(),
    })

    if decision == "sent_back":
        rfi["status"] = cfg.RFI_SENT_BACK
        _log(rfi["project_id"], current_gm()["id"], "RFI_SENT_BACK", {"rfi_code": rfi["rfi_code"], "note": note})
    elif decision == "approved":
        has_open = len(open_observations(rfi_id)) > 0
        rfi["status"] = cfg.RFI_APPROVED_WITH_OBS if has_open else cfg.RFI_APPROVED_CLEAN
        _log(rfi["project_id"], current_gm()["id"], "RFI_APPROVED",
             {"rfi_code": rfi["rfi_code"], "open_observations": has_open})
    return rfi


def list_gm_decisions(rfi_id: str) -> list[dict]:
    if is_demo_mode():
        rows = [d for d in _db()["gm_decisions"] if d["rfi_id"] == rfi_id]
        return sorted(rows, key=lambda d: d["decided_at"], reverse=True)
    return []


def resubmit_rfi(rfi_id: str) -> dict:
    """DM 'resubmits' after rework — demo helper to loop sent_back → pending_gm_approval."""
    if not is_demo_mode():
        return {}
    rfi = next(r for r in _db()["rfis"] if r["id"] == rfi_id)
    if rfi["status"] == cfg.RFI_SENT_BACK:
        rfi["status"] = cfg.RFI_PENDING_GM_APPROVAL
        _log(rfi["project_id"], current_gm()["id"], "RFI_RESUBMITTED", {"rfi_code": rfi["rfi_code"]})
    return rfi


# =========================================================================
# CERTIFICATES
# =========================================================================

def list_certificates(vessel_id: str | None = None, status: str | None = None) -> list[dict]:
    if is_demo_mode():
        rows = list(_db()["certificates"])
        if vessel_id:
            rows = [c for c in rows if c["vessel_id"] == vessel_id]
        if status:
            rows = [c for c in rows if c["status"] == status]
        for c in rows:
            c["_vessel"] = get_vessel(c["vessel_id"])
        return sorted(rows, key=lambda c: c["issue_date"], reverse=True)
    return []


def expiring_soon_certificates(days: int = cfg.CERT_EXPIRING_SOON_DAYS) -> list[dict]:
    today = date.today()
    out = []
    for c in list_certificates(status=cfg.CERT_STATUS_ACTIVE):
        remaining = (c["expiry_date"] - today).days
        if 0 <= remaining <= days:
            out.append(c)
    return sorted(out, key=lambda c: c["expiry_date"])


def issue_certificate(vessel_id: str, project_id: str, rfi_id: str | None,
                       cert_type: str, validity_months: int,
                       pending_observation_descriptions: list[str] | None = None) -> dict:
    """
    'GM issues CLASS/INTERIM CERTIFICATE' node.
    Caller is responsible for having already checked open_observations()
    to decide cert_type — this function just persists the decision and
    (for a linked RFI) closes the loop back to the flowchart's terminal
    nodes: cert sent to Shipyard & Owner / vessel added to Ship Register.
    """
    if not is_demo_mode():
        return {}

    vessel = get_vessel(vessel_id)
    prefix = cfg.CERT_TYPE_PREFIX[cert_type]
    code = _next_code("cert")
    cert_number = f"{prefix}-{date.today().year}-{code}-{vessel['name'].split()[0]}"

    cert = {
        "id": str(uuid.uuid4()), "vessel_id": vessel_id, "project_id": project_id, "rfi_id": rfi_id,
        "cert_type": cert_type, "cert_number": cert_number,
        "issue_date": date.today(),
        "expiry_date": date.today() + timedelta(days=30 * validity_months),
        "status": cfg.CERT_STATUS_ACTIVE,
        "pending_observations": pending_observation_descriptions or [],
        "issued_by": current_gm()["id"],
    }
    _db()["certificates"].append(cert)

    if rfi_id:
        rfi = next((r for r in _db()["rfis"] if r["id"] == rfi_id), None)
        if rfi:
            rfi["status"] = cfg.RFI_CERT_ISSUED

    vessel["current_class"] = "Classification Authority"
    _log(project_id, current_gm()["id"], "CERTIFICATE_ISSUED",
         {"cert_number": cert_number, "cert_type": cert_type})
    return cert


# =========================================================================
# SHIP REGISTER
# =========================================================================

def ship_register_rows() -> list[dict]:
    if is_demo_mode():
        rows = []
        for v in _db()["vessels"]:
            certs = list_certificates(vessel_id=v["id"])
            latest = certs[0] if certs else None
            rows.append({
                "vessel": v,
                "latest_cert": latest,
                "survey_history": list_rfis(project_id=v["project_id"]),
            })
        return rows
    try:
        rows = get_client().from_("epas_ship_register").select("*").order("name").execute().data or []
        out = []
        for row in rows:
            vessel = get_vessel(row["vessel_id"])
            certs = list_certificates(vessel_id=row["vessel_id"])
            out.append({"vessel": vessel or row, "latest_cert": certs[0] if certs else None, "survey_history": list_rfis(project_id=row["project_id"])})
        return out
    except Exception:
        return []


# =========================================================================
# AUDIT / REPORTS
# =========================================================================

def audit_trail(project_id: str | None = None) -> list[dict]:
    if is_demo_mode():
        rows = _db()["audit_log"]
        if project_id:
            rows = [a for a in rows if a["project_id"] == project_id]
        for a in rows:
            a["_actor"] = get_user(a["actor_id"])
        return sorted(rows, key=lambda a: a["created_at"], reverse=True)
    return []


# =========================================================================
# KPI SUMMARY  (Overview page)
# =========================================================================

def kpi_summary() -> dict:
    projects = list_projects()
    active_projects = [p for p in projects if p["status"] == cfg.PROJECT_STATUS_ACTIVE]
    all_rfis = list_rfis()
    needs_gm = gm_actionable_rfis()
    expiring = expiring_soon_certificates()
    in_progress = [r for r in all_rfis if r["status"] in
                   (cfg.RFI_ALLOCATED, cfg.RFI_SURVEY_IN_PROGRESS, cfg.RFI_OBSERVATIONS_LOGGED)]

    return {
        "active_projects": len(active_projects),
        "total_projects": len(projects),
        "rfis_in_progress": len(in_progress),
        "needs_gm_action": len(needs_gm),
        "pending_allocation": len([r for r in needs_gm if r["status"] == cfg.RFI_PENDING_ALLOCATION]),
        "pending_approval": len([r for r in needs_gm if r["status"] == cfg.RFI_PENDING_GM_APPROVAL]),
        "certs_expiring_soon": len(expiring),
    }
