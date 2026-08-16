"""PSB EPAS v4.0 — Project-specific role workspace.

A project click opens a dedicated project context. The project identity,
health, workflow state and role-specific actions remain visible while the
left project navigation changes by authenticated role.
"""
from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as pq
from utils import helpers as h

from components import certificates, reports, rfi_queue
from components import plan_appraisal

# Project navigation is intentionally project-specific and phase-aware.
# Once a project is opened, the left sidebar becomes the primary navigation for
# that project. The backend still enforces every role/phase permission.
PROJECT_NAV = [
    ("Project Overview", "overview", "Project health, phase status and next actions"),
    ("Plan Appraisal", "plan_appraisal", "Drawing appraisal, revision and approval"),
    ("NSC Survey", "nsc_survey", "New Construction Survey workflow"),
    ("In-Service Survey", "in_service", "Recurring In-Service survey cycles"),
    ("Survey Status", "survey_status", "Review-only live survey status for this project"),
    ("Risk Register", "risk_register", "Project risks and management decisions"),
    ("Ship Register", "ship_register", "Review-only vessel/class/survey status for this project"),
    ("Certification", "certification", "Certificate lifecycle and issued certificates"),
    ("Documents", "documents", "Controlled project documents and releases"),
    ("Notifications", "notifications", "Project-specific notifications"),
    ("Audit Trail", "audit", "Project history and traceable activity"),
]

# Role labels remain visible in the project context header.
ROLE_LABELS = {
    "gm": "GM Classification",
    "dm": "Department Manager",
    "engineer": "Authorized Engineer",
    "surveyor": "Authorized Surveyor",
    "designer": "Designer · Stakeholder",
    "ship_management": "Ship Management · Stakeholder",
    "owner": "Owner · Stakeholder",
    "shipyard": "Shipyard · Stakeholder",
}

def _safe(fn, label="Project operation"):
    try:
        return fn()
    except Exception as exc:
        ref = abs(hash(f"{label}:{type(exc).__name__}")) % 100000
        st.error(f"{label} could not be loaded. Reference PSB-{ref:05d}.")
        return None

def open_project(project_id: str):
    st.session_state["selected_project_id"] = project_id
    st.session_state["project_nav_key"] = "overview"

def clear_project():
    st.session_state.pop("selected_project_id", None)
    st.session_state.pop("project_nav_key", None)

def render_project_launcher(role: str):
    """Role-safe project register. Only GM can create a project; all other roles may only open projects."""
    st.markdown('<div class="psb-section-eyebrow">PROJECT REGISTER</div>', unsafe_allow_html=True)
    head_left, head_right = st.columns([5, 1])
    with head_left:
        st.markdown("<div class='page-title'>Projects</div>", unsafe_allow_html=True)
        st.caption("Select a project to open its dedicated workspace. Project navigation appears after selection and remains scoped to that vessel/project.")
    with head_right:
        if role == "gm":
            if st.button("+ Create Project", key="gm_create_project_from_projects", type="primary", use_container_width=True):
                st.session_state["gm_create_project_open"] = True

    if role == "gm" and st.session_state.get("gm_create_project_open"):
        from components.gm_production import render_create_project
        with st.container(border=True):
            st.markdown("### Create Project")
            st.caption("GM-only action. New projects are created and activated from this Projects tab.")
            if st.button("Close", key="close_gm_create_project"):
                st.session_state["gm_create_project_open"] = False
                st.rerun()
            render_create_project()
        st.markdown("---")

    search = st.text_input(
        "Search project",
        placeholder="Project code, vessel name or vessel type…",
        label_visibility="collapsed",
        key=f"psb_project_search_{role}",
    )

    projects = _safe(lambda: pq.projects("active"), "Project register") or []
    if search.strip():
        q = search.lower()
        projects = [
            p for p in projects
            if q in str(p.get("project_code","")).lower()
            or q in str(p.get("name","")).lower()
            or q in str(p.get("vessel_type","")).lower()
        ]

    if not projects:
        st.info("No projects are available to this account.")
        return

    for p in projects:
        health = _safe(
            lambda pid=p["id"]: pq.dashboard_project_health_bundle([pid]).get(pid),
            "Project health",
        ) or {}
        with st.container(border=True):
            left, mid, right = st.columns([4.2, 1.8, 1])
            with left:
                status = str(p.get("status","active")).replace("_"," ").title()
                phases = ", ".join(str(x).replace("_"," ").title() for x in (p.get("phases") or [])) or "Configured workflow"
                st.markdown(
                    f"<div class='psb-project-row-title'><span class='psb-project-code'>{p.get('project_code','—')}</span>"
                    f"<span class='psb-project-name'>{p.get('name','—')}</span>"
                    f"<span class='psb-project-status'>{status}</span></div>",
                    unsafe_allow_html=True,
                )
                st.caption(f"{p.get('vessel_type','—')} · {p.get('flag_state','—')} · {phases}")
            with mid:
                mc1, mc2, mc3 = st.columns(3)
                mc1.metric("Complete", f"{health.get('completion_pct',0)}%")
                mc2.metric("Overdue", health.get('overdue_tasks',0))
                mc3.metric("Open Obs.", health.get('open_observations',0))
            with right:
                if st.button("Open Project →", key=f"psb_open_project_{role}_{p['id']}", use_container_width=True, type="primary"):
                    open_project(p["id"])
                    st.rerun()

def render(role: str, project_id: str | None):
    if not project_id:
        render_project_launcher(role)
        return

    project = _safe(lambda: pq.project(project_id), "Project") or None
    if not project:
        st.error("The selected project is unavailable or you are not authorized to view it.")
        if st.button("← Back to Projects"):
            clear_project()
            st.rerun()
        return

    vessel = _safe(lambda: pq.get_vessel_for_project(project_id), "Vessel particulars")
    health = _safe(lambda: pq.dashboard_project_health_bundle([project_id]).get(project_id), "Project health") or {}
    role_name = ROLE_LABELS.get(role, "Authenticated User")

    # Project identity bar
    st.markdown(
        f"""
        <div class="psb-project-header">
          <div class="psb-project-header__identity">
            <div class="psb-project-header__code">{project.get('project_code','—')}</div>
            <div class="psb-project-header__name">{project.get('name','—')}</div>
            <div class="psb-project-header__meta">
              {project.get('vessel_type','—')} · {project.get('flag_state','—')} · {role_name}
            </div>
          </div>
          <div class="psb-project-header__metrics">
            <span><b>{health.get('completion_pct',0)}%</b><small>completion</small></span>
            <span><b>{health.get('overdue_tasks',0)}</b><small>overdue</small></span>
            <span><b>{health.get('open_escalations',0)}</b><small>escalations</small></span>
            <span class="psb-project-health psb-project-health--{str(health.get('health_status','watch')).lower()}">
              {str(health.get('health_status','Watch')).title()}
            </span>
          </div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    if st.button("← Back to Projects", key=f"back_projects_{role}", type="secondary"):
        clear_project()
        st.rerun()

    phases = {str(x).lower() for x in (project.get("phases") or [])}
    # Only phases actually included in the selected project are shown. This keeps
    # the project navigation honest: Plan/NSC/In-Service appear only when they
    # are part of that project's scope. Certification, Documents, Notifications
    # and Audit are always available within the project context.
    nav = []
    for label, value, desc in PROJECT_NAV:
        if value == "plan_appraisal" and "plan_appraisal" not in phases:
            continue
        if value == "nsc_survey" and "nsc_survey" not in phases:
            continue
        if value == "in_service" and "in_service" not in phases:
            continue
        nav.append((label, value, desc))

    labels = [x[0] for x in nav]
    values = {x[0]: x[1] for x in nav}
    descriptions = {x[0]: x[2] for x in nav}
    current = st.session_state.get("project_nav_key", "overview")
    default_label = next((x[0] for x in nav if x[1] == current), labels[0])

    # Project-specific left navigation. The global navigation is intentionally
    # suppressed once a project is open so the selected project becomes the
    # primary context for the entire workspace.
    with st.sidebar:
        st.markdown('<div class="psb-project-sidebar-kicker">SELECTED PROJECT</div>', unsafe_allow_html=True)
        st.markdown(
            f"<div class='psb-project-sidebar-project'><div class='psb-project-sidebar-code'>{project.get('project_code','—')}</div>"
            f"<div class='psb-project-sidebar-name'>{project.get('name','—')}</div>"
            f"<div class='psb-project-sidebar-meta'>{project.get('vessel_type','—')} · {project.get('flag_state','—')}</div></div>",
            unsafe_allow_html=True,
        )
        if st.button("↔  Change Project", key=f"project_change_{role}", use_container_width=True):
            clear_project()
            st.rerun()
        st.markdown('<div class="psb-project-sidebar-section">PROJECT NAVIGATION</div>', unsafe_allow_html=True)
        selected = st.radio(
            "Project navigation",
            labels,
            index=labels.index(default_label),
            key=f"project_sidebar_{role}_{project_id}",
            label_visibility="collapsed",
        )
        st.session_state["project_nav_key"] = values[selected]
        st.markdown(
            f"<div class='psb-project-sidebar-current'><b>{selected}</b><span>{descriptions[selected]}</span></div>",
            unsafe_allow_html=True,
        )
        st.markdown('<div class="psb-project-sidebar-section">PROJECT SUMMARY</div>', unsafe_allow_html=True)
        summary_rows = [
            ("Project ID", project.get("project_code")),
            ("Vessel", project.get("name")),
            ("Current Phase", (health.get("current_phase") or ("In-Service Active" if "in_service" in phases else "—"))),
            ("Current Cycle", health.get("current_cycle") or "—"),
            ("Next Survey", health.get("next_survey_due") or vessel.get("next_survey_due") if vessel else "—"),
        ]
        for k, v in summary_rows:
            st.markdown(f"<div class='psb-project-sidebar-row'><span>{k}</span><b>{v or '—'}</b></div>", unsafe_allow_html=True)
        st.markdown(
            "<div class='psb-project-sidebar-note'>"
            "Project context is role-controlled. Workflow actions and data access remain enforced by Supabase RLS and workflow RPCs."
            "</div>",
            unsafe_allow_html=True,
        )

    _render_section(role, values[selected], project, vessel, health)

def _render_section(role, section, project, vessel, health):
    pid = project["id"]

    if section == "overview":
        _overview(role, project, vessel, health)
    elif section == "info":
        _info(project, vessel)
    elif section == "plan_appraisal":
        if role == "gm":
            plan_appraisal.render(project)
        else:
            # Use the role-specific work queue when the role module has one.
            from components.role_workspaces import render_engineer
            if role == "engineer":
                render_engineer()
            else:
                _project_task_snapshot(pid, "Plan Appraisal")
    elif section == "nsc_survey":
        _survey(role, pid, phase_filter="nsc_survey")
    elif section == "in_service":
        _survey(role, pid, phase_filter="in_service")
    elif section == "survey_status":
        _survey_status(role, pid, project, vessel, health)
    elif section == "risk_register":
        _risk_register(pid, role)
    elif section == "ship_register":
        _ship_register(pid, vessel)
    elif section == "certification":
        certificates.render_for_project(pid)
    elif section == "milestones":
        _milestones(pid)
    elif section == "observations":
        _observations(pid)
    elif section == "documents" or section == "approved":
        _documents(role, pid, approved_only=(section == "approved"))
    elif section == "governance":
        from components.professional_center_v36 import render_governance
        render_governance(pid)
    elif section == "audit":
        _audit(pid)
    elif section == "work":
        _work(role, pid)
    elif section == "resources":
        _resources(pid)
    elif section == "corrective":
        _corrective(pid)
    elif section == "coordination":
        from components.professional_center_v36 import render_phase_and_coordination
        render_phase_and_coordination(pid)
    elif section == "revisions":
        _project_task_snapshot(pid, "Revision Requests")
    elif section == "notifications":
        _notifications(pid)
    elif section == "evidence":
        _corrective(pid, evidence_mode=True)
    elif section == "followup":
        _survey(role, pid, followup_only=True)
    elif section == "approved":
        _documents(role, pid, approved_only=True)

def _overview(role, project, vessel, health):
    """Project landing page matching the PSB reference: no workflow snapshot and no recent activity."""
    pid = project["id"]
    st.markdown("### Project Summary")
    phases = {str(x).lower() for x in (project.get("phases") or [])}
    summary_rows = [
        ("Project ID", project.get("project_code")),
        ("Current Phase", health.get("current_phase") or ("In-Service Active" if "in_service" in phases else "—")),
        ("Vessel", project.get("name")),
        ("Current Cycle", health.get("current_cycle") or "—"),
        ("Classification No.", project.get("classification_number") or "—"),
        ("Next Survey", health.get("next_survey_due") or (vessel.get("next_survey_due") if vessel else "—")),
    ]
    cols = st.columns(2)
    for i, (label, value) in enumerate(summary_rows):
        with cols[i % 2]:
            st.markdown(
                f"<div class='psb-project-sidebar-row'><span>{label}</span><b>{value or '—'}</b></div>",
                unsafe_allow_html=True,
            )
    st.markdown("---")
    st.markdown("### Project Overview")
    st.caption(f"Projects  ›  {project.get('project_code','—')}  ›  Overview")
    phase_rows = _safe(lambda: pq.project_phase_status(pid), "Phase status") or []
    tasks = _safe(lambda: pq.tasks(statuses=["pending","accepted","in_progress"], project_id=pid), "Project tasks") or []
    ship_rows = _safe(lambda: pq.ship_register_project(pid), "Survey status") or []
    ship = ship_rows[0] if ship_rows else (vessel or {})
    certs = _safe(lambda: pq.certificates(pid), "Project certificates") or []
    milestones = _safe(lambda: pq.project_milestones(pid), "Project milestones") or []
    priority = _safe(lambda: [r for r in (pq.my_work_queue() or []) if str(r.get("project_id")) == str(pid)], "Priority actions") or []

    next_due = health.get("next_survey_due") or ship.get("next_survey_due") or "—"
    survey_status = ship.get("survey_status") or health.get("survey_status") or "—"
    cert_expiring = len([c for c in certs if str(c.get("status","")).lower() in ("expiring","expiring_soon")])

    cards = [
        ("Project Health", f"{health.get('completion_pct',0)}%", str(health.get('health_status','—')).title(), "green"),
        ("Survey Due", str(next_due), str(survey_status).replace("_"," ").title(), "blue"),
        ("Open Observations", str(health.get('open_observations',0)), "Requires attention" if health.get('open_observations',0) else "None open", "amber"),
        ("Certificates", str(len(certs)), f"{cert_expiring} expiring soon" if cert_expiring else "Current", "teal"),
        ("Overdue Tasks", str(health.get('overdue_tasks',0)), "Requires attention" if health.get('overdue_tasks',0) else "On track", "red"),
    ]
    cols=st.columns(5)
    for col,(label,value,foot,tone) in zip(cols,cards):
        with col:
            st.markdown(
                f"<div class='ref-kpi ref-kpi--{tone}'><div class='ref-kpi__label'>{label}</div>"
                f"<div class='ref-kpi__value'>{value}</div><div class='ref-kpi__foot'>{foot}</div></div>",
                unsafe_allow_html=True,
            )

    left, mid, right = st.columns([1.2,1.15,1.0])
    with left:
        _project_panel_open("PROJECT LIFECYCLE & PHASE", "Scope-aware project progress")
        for p in phase_rows:
            status=str(p.get("status","")).upper()
            icon={"COMPLETED":"✓","IN_PROGRESS":"→","READY":"●","LOCKED":"○","BLOCKED":"!"}.get(status,"•")
            st.markdown(f"**{icon} {str(p.get('phase','')).replace('_',' ').title()}**")
            st.caption(p.get("gate_note") or status.replace("_"," ").title())
        if not phase_rows:
            st.info("No phase records are available.")
        _project_panel_close()
    with mid:
        _project_panel_open("SURVEY STATUS", "Review-only live status for this project")
        rows = ship_rows or ([ship] if ship else [])
        if rows:
            for r in rows[:4]:
                st.markdown(f"**{r.get('name') or project.get('name') or 'Vessel'}**")
                st.caption(f"Class: {r.get('class_status') or '—'} · Survey: {str(r.get('survey_status') or '—').replace('_',' ').title()}")
                st.caption(f"Next survey: {r.get('next_survey_due') or next_due}")
        else:
            st.info("Survey status is not yet available.")
        if st.button("View Survey Status →", key=f"overview_survey_status_{pid}"):
            st.session_state["project_nav_key"]="survey_status"; st.rerun()
        _project_panel_close()
    with right:
        _project_panel_open("MY PRIORITY ACTIONS", "Current work inside this project")
        if not priority:
            st.success("No immediate assigned actions.")
        else:
            for r in priority[:6]:
                st.markdown(f"**{str(r.get('task_type','Task')).replace('_',' ').title()}**")
                st.caption(f"{r.get('sla_state') or 'ON_TRACK'} · due {r.get('sla_due_at') or r.get('due_at') or '—'}")
        if priority and st.button("Open My Project Work →", key=f"overview_work_{pid}"):
            st.session_state["project_nav_key"]="work"; st.rerun()
        _project_panel_close()

    bottom_left, bottom_mid = st.columns([1.2,1.0])
    with bottom_left:
        _project_panel_open("MILESTONE STATUS", "Plan, NSC and In-Service milestones")
        if not milestones:
            st.info("No project milestones are available.")
        else:
            for m in milestones[:10]:
                status=str(m.get("status","pending")).replace("_"," ").title()
                st.markdown(f"**{m.get('name') or m.get('milestone_code') or 'Milestone'}** · {status}")
                st.caption(f"Due {m.get('due_date') or '—'}")
        _project_panel_close()
    with bottom_mid:
        _project_panel_open("CERTIFICATES OVERVIEW", "Current controlled project certificates")
        if not certs:
            st.info("No certificates issued.")
        else:
            for cert in certs[:5]:
                st.markdown(f"**{cert.get('cert_number','—')}** · {str(cert.get('cert_type','—')).replace('_',' ').title()}")
                st.caption(f"Status {str(cert.get('status','—')).title()} · Expiry {cert.get('expiry_date') or '—'}")
        if certs and st.button("View all Certificates →", key=f"overview_certificates_{pid}"):
            st.session_state["project_nav_key"]="certification"; st.rerun()
        _project_panel_close()

def _project_panel_open(title, subtitle=''):
    st.markdown(
        f"<div class='psb-project-panel'><div class='psb-project-panel__title'>{title}</div><div class='psb-project-panel__subtitle'>{subtitle}</div>",
        unsafe_allow_html=True,
    )

def _project_panel_close():
    st.markdown("</div>", unsafe_allow_html=True)

def _survey_status(role, pid, project, vessel, health):
    st.markdown("### Survey Status")
    st.caption("Review-only project survey status. Values are refreshed from the controlled project and vessel records.")
    phase_rows = _safe(lambda: pq.project_phase_status(pid), "Survey phase status") or []
    current_cycle = health.get("current_cycle") or "—"
    next_due = health.get("next_survey_due") or (vessel.get("next_survey_due") if vessel else None) or "—"
    c = st.columns(5)
    c[0].metric("Current Phase", str(health.get("current_phase") or "—").replace("_"," " ).title())
    c[1].metric("Current Cycle", current_cycle)
    c[2].metric("Next Survey", next_due)
    c[3].metric("Open Observations", health.get("open_observations", 0))
    c[4].metric("Overdue Tasks", health.get("overdue_tasks", 0))

    st.markdown("#### Project Phase Status")
    for row in phase_rows:
        status = str(row.get("status","—")).replace("_"," " ).title()
        st.markdown(f"**{str(row.get('phase','—')).replace('_',' ').title()}** · {status}")
        st.progress(1.0 if status == "Completed" else 0.6 if status in ("In Progress","Ready") else 0.0)

    rfi_rows = _safe(lambda: pq.list_rfis(project_id=pid), "Project survey status") or []
    if rfi_rows:
        st.markdown("#### Survey / RFI Register")
        for r in rfi_rows[:30]:
            phase = str(r.get("phase","")).replace("_"," " ).title()
            status = str(r.get("status","")).replace("_"," " ).title()
            st.markdown(f"**{r.get('rfi_code','RFI')}** · {phase} · {status}")
            st.caption(f"Requested {r.get('requested_date') or '—'} · Priority {str(r.get('priority','—')).title()}")
    else:
        st.info("No survey RFI records are currently available.")

def _risk_register(pid, role):
    st.markdown("### Risk Register")
    rows = _safe(lambda: pq.risks(pid, open_only=False), "Project risk register") or []
    if not rows:
        st.success("No project risks are currently registered.")
    for r in rows:
        st.markdown(f"**{r.get('risk_code','RISK')} · {r.get('title','Untitled')}** · {str(r.get('severity','')).upper()} · {str(r.get('status','')).replace('_',' ').title()}")
        st.caption(f"{r.get('mitigation') or 'No mitigation recorded.'}")
    if role in ("gm", "dm"):
        st.caption("GM/DM may add or update risks through the controlled governance controls.")

def _ship_register(pid, vessel):
    st.markdown("### Ship Register")
    st.caption("Review-only vessel/class/survey status for this selected project. The register is updated from controlled survey and certificate activity.")
    rows = _safe(lambda: pq.ship_register_project(pid), "Ship Register") or []
    if not rows and vessel:
        rows = [{
            "project_id": pid, "vessel_id": vessel.get("id"), "name": vessel.get("name"),
            "class_status": vessel.get("class_status") or vessel.get("current_class"),
            "survey_status": vessel.get("survey_status"), "next_survey_due": vessel.get("next_survey_due")
        }]
    if not rows:
        st.info("No vessel record is available for this project.")
        return
    for r in rows:
        c = st.columns([2.0,1.25,1.25,1.45,1.45])
        c[0].markdown(f"**{r.get('name') or 'Vessel'}**")
        c[0].caption(f"Vessel ID {r.get('vessel_id') or '—'}")
        c[1].write(f"Class: {r.get('class_status') or '—'}")
        c[2].write(f"Survey: {str(r.get('survey_status') or '—').replace('_',' ').title()}")
        c[3].write(f"Next Due: {r.get('next_survey_due') or '—'}")
        certs = _safe(lambda vid=r.get('vessel_id'): pq.list_certificates(vessel_id=vid), "Ship Register certificates") or []
        c[4].write(f"Certificates: {len(certs)}")
        st.markdown("<hr class='divider-hr' style='margin:6px 0;'>", unsafe_allow_html=True)


def _info(project, vessel):
    st.markdown("### Project Information")
    c1, c2 = st.columns([1.25, 1])
    with c1:
        with st.container(border=True):
            st.markdown("#### Vessel particulars")
            rows = [
                ("Project code", project.get("project_code")),
                ("Vessel", project.get("name")),
                ("Vessel type", project.get("vessel_type")),
                ("Flag", project.get("flag_state")),
                ("Classification No.", project.get("classification_number")),
                ("Register No.", project.get("register_number")),
                ("Contract No.", project.get("contract_number")),
                ("Classification scope", project.get("classification_scope")),
                ("Classification request", project.get("classification_request")),
            ]
            for k,v in rows:
                a,b = st.columns([1,1.5])
                a.caption(k); b.write(v or "—")
        if vessel:
            with st.container(border=True):
                st.markdown("#### Principal particulars")
                for k,v in [
                    ("IMO / Reg.", vessel.get("imo_number")),
                    ("LOA", f"{vessel.get('loa_m')} m" if vessel.get('loa_m') else "—"),
                    ("Beam", f"{vessel.get('beam_m')} m" if vessel.get('beam_m') else "—"),
                    ("Draft", f"{vessel.get('draft_m')} m" if vessel.get('draft_m') else "—"),
                    ("Power", f"{vessel.get('power_kw')} kW" if vessel.get('power_kw') else "—"),
                    ("Speed", f"{vessel.get('speed_knots')} kn" if vessel.get('speed_knots') else "—"),
                ]:
                    a,b = st.columns([1,1.5]); a.caption(k); b.write(v or "—")
    with c2:
        with st.container(border=True):
            st.markdown("#### Role within this project")
            st.success(ROLE_LABELS.get(pq.profile().get("role"), "Authenticated role"))
            st.caption("Permissions and available actions are enforced by the authenticated role and project membership.")
        with st.container(border=True):
            st.markdown("#### Project phases")
            for ph in project.get("phases",[]):
                st.write("•", str(ph).replace("_"," ").title())

def _survey(role, pid, followup_only=False, phase_filter: str | None = None):
    try:
        phase_label = {"nsc_survey": "NSC Survey", "in_service": "In-Service Survey"}.get(phase_filter, "Survey / RFI")
        st.caption(f"{phase_label} follows the controlled GM → DM → Surveyor → DM → GM workflow.")
        if followup_only:
            st.info("Follow-up RFI view — controlled corrective-action loop.")
        if phase_filter:
            st.markdown(f"**Current survey phase:** {phase_label}")
        rfi_queue.render(project_id=pid)
    except Exception as exc:
        st.error(f"Survey workspace unavailable: {exc}")

def _work(role, pid):
    rows = _safe(lambda: pq.tasks(statuses=["pending","accepted","in_progress"], project_id=pid), "My project work") or []
    user = pq.profile()
    rows = [r for r in rows if str(r.get("to_user_id")) == str(user.get("id"))]
    if not rows:
        st.success("No assigned project tasks.")
        return
    for r in rows[:100]:
        state = r.get("sla_state") or "ON_TRACK"
        st.markdown(
            f"<div class='psb-task-row'><b>{str(r.get('task_type','Task')).replace('_',' ').title()}</b>"
            f"<span class='psb-task-state psb-task-state--{str(state).lower()}'>{state}</span></div>",
            unsafe_allow_html=True,
        )
        st.caption(f"Due {r.get('sla_due_at') or r.get('due_at') or '—'} · {r.get('note') or ''}")

def _milestones(pid):
    rows = _safe(lambda: pq.project_milestones(pid), "Project milestones") or []
    if not rows:
        st.info("No project milestones are available.")
        return
    for r in rows:
        state = str(r.get("status","")).replace("_"," ").title()
        st.markdown(f"**{r.get('name') or r.get('milestone_code') or 'Milestone'}** · {state}")
        st.caption(f"Due {r.get('due_date') or '—'} · {r.get('gate_note') or ''}")

def _observations(pid):
    rows = _safe(lambda: pq.observations_for_project(pid), "Project observations") or []
    if not rows:
        st.success("No project observations are currently visible.")
        return
    for r in rows[:150]:
        state = str(r.get("status","open")).upper()
        st.markdown(
            f"**{r.get('obs_code','Observation')}** · {r.get('severity','—')} · {state}"
        )
        st.caption(
            f"{r.get('description','—')} · Rule {r.get('rule_reference') or '—'} · "
            f"Location {r.get('location') or '—'}"
        )

def _documents(role, pid, approved_only=False):
    rows = _safe(lambda: pq.list_documents(pid), "Project documents") or []
    if approved_only:
        rows = [r for r in rows if str(r.get("release_status","")).lower() in ("released","approved") or r.get("status") in ("approved","released")]
    if not rows:
        st.info("No documents are currently visible in this project workspace.")
        return
    for r in rows[:150]:
        st.markdown(f"**{r.get('file_name','Document')}** · {r.get('version','—')} · {r.get('release_status') or r.get('status') or '—'}")
        st.caption(f"{r.get('category','—')} · {r.get('uploaded_at','—')}")

def _audit(pid):
    rows = _safe(lambda: pq.project_timeline_v35(pid,100), "Project audit") or []
    if not rows:
        st.info("No project history is available.")
        return
    for r in rows:
        st.caption(f"{r.get('occurred_at') or r.get('created_at') or '—'} · {r.get('actor_role','system')} · {r.get('event_type','')} · {r.get('summary') or r.get('note') or '—'}")

def _resources(pid):
    try:
        from components.professional_center_v36 import render_sla
        render_sla(pid)
    except Exception as exc:
        st.error(str(exc))

def _corrective(pid, evidence_mode=False):
    rows = _safe(lambda: pq.corrective_actions(project_id=pid), "Corrective actions") or []
    if not rows:
        st.success("No corrective actions are currently visible.")
        return
    for r in rows[:100]:
        st.markdown(f"**{r.get('action_code') or r.get('id','Corrective Action')}** · {str(r.get('status','')).replace('_',' ').title()}")
        st.caption(r.get("instruction") or "No instruction recorded.")

def _notifications(pid):
    rows = _safe(pq.notifications, "Notifications") or []
    rows = [r for r in rows if not pid or str(r.get("project_id")) == str(pid)]
    if not rows:
        st.success("No project notifications.")
        return
    for r in rows[:100]:
        st.markdown(f"**{r.get('title','Notification')}**")
        st.caption(r.get('body') or '')

def _project_task_snapshot(pid, title):
    rows = _safe(lambda: pq.tasks(statuses=["pending","accepted","in_progress"], project_id=pid), title) or []
    st.markdown(f"### {title}")
    if not rows:
        st.info(f"No {title.lower()} tasks are currently visible.")
        return
    for r in rows[:100]:
        st.write(f"**{str(r.get('task_type','Task')).replace('_',' ').title()}**")
        st.caption(r.get('note') or '—')
