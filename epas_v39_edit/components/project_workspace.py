"""
EPAS · Project Workspace
--------------------------
The flowchart's "Project Workspace → Contextual Tabs (visible based on
Phase selection)" node. Project Info, Certificates, and Survey Logs &
Reports are always present; Plan Appraisal / NSC Survey / In-Service
Surveys only appear if that phase was selected in the wizard.
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h
from components import rfi_queue, certificates, reports, plan_appraisal
from components.document_panel import open_document_dialog

_STATUS_BADGE_KIND = {
    cfg.PROJECT_STATUS_ACTIVE: "success",
    cfg.PROJECT_STATUS_ON_HOLD: "warning",
    cfg.PROJECT_STATUS_CLOSED: "neutral",
}


def render() -> None:
    project_id = st.session_state.get("selected_project_id")
    project = q.get_project(project_id) if project_id else None

    if not project:
        st.warning("No project selected.")
        if st.button("← Back to Projects"):
            st.session_state["page"] = "projects"
            st.rerun()
        return

    if st.button("← All Projects", key="workspace_back"):
        st.session_state["page"] = "projects"
        st.rerun()

    vessel = q.get_vessel_for_project(project_id)
    phase_rows = q.project_phase_status(project_id)
    phase_map = {r["phase"]: r for r in phase_rows}
    phase_badges = "".join(h.badge(cfg.PHASE_LABELS[ph], "info") + " " for ph in project["phases"])
    st.markdown(
        f'<div class="eyebrow">{project["project_code"]}</div>'
        f'<div class="page-title">{project["name"]}</div>'
        f'<div class="page-sub">{project["vessel_type"]} · {project["flag_state"]} '
        f'{h.badge(cfg.PROJECT_STATUS_LABELS[project["status"]], _STATUS_BADGE_KIND.get(project["status"], "neutral"))}</div>'
        f'<div style="margin-top:8px;">{phase_badges}</div>',
        unsafe_allow_html=True,
    )
    st.write("")

    _render_phase_roadmap(project, phase_rows, vessel)

    # The operational workspace follows the selected project scope and its
    # sequential gates. A phase is not exposed as executable work until its
    # predecessor has closed. This prevents parallel NSC/In-Service execution
    # when the project contract requires sequential completion.
    tab_labels = ["📋 Project Info"]
    tab_keys = ["info"]
    if cfg.PHASE_PLAN_APPRAISAL in project["phases"]:
        tab_labels.append("📐 Plan Appraisal")
        tab_keys.append("plan_appraisal")
    if cfg.PHASE_NSC_SURVEY in project["phases"]:
        tab_labels.append("🏗️ NSC Survey")
        tab_keys.append("nsc_survey")
    if cfg.PHASE_IN_SERVICE in project["phases"]:
        tab_labels.append("⚓ In-Service Surveys")
        tab_keys.append("in_service")
    if cfg.PHASE_NSC_SURVEY in project["phases"] or cfg.PHASE_IN_SERVICE in project["phases"]:
        tab_labels.append("📜 Certificates")
        tab_keys.append("certificates")
    tab_labels.append("📊 Survey Logs & Reports")
    tab_keys.append("reports")

    tabs = st.tabs(tab_labels)
    for key, tab in zip(tab_keys, tabs):
        with tab:
            if key == "info":
                _project_info_tab(project, vessel)
            elif key == "plan_appraisal":
                _plan_appraisal_tab(project)
            elif key == "nsc_survey":
                gate = phase_map.get(cfg.PHASE_NSC_SURVEY, {})
                if gate.get("status") in ("LOCKED", "BLOCKED"):
                    _locked_phase(gate, "NSC Survey")
                else:
                    rfi_queue.render(phase=cfg.PHASE_NSC_SURVEY, project_id=project_id)
            elif key == "in_service":
                gate = phase_map.get(cfg.PHASE_IN_SERVICE, {})
                if gate.get("status") in ("LOCKED", "BLOCKED"):
                    _locked_phase(gate, "In-Service Survey")
                else:
                    rfi_queue.render(phase=cfg.PHASE_IN_SERVICE, project_id=project_id)
            elif key == "certificates":
                certificates.render_for_project(project_id)
            elif key == "reports":
                reports.render(project_id=project_id)


def _render_phase_roadmap(project: dict, phase_rows: list[dict], vessel: dict | None) -> None:
    """Professional project execution roadmap: only selected phases execute,
    and later phases are gated by completion of the preceding selected phase."""
    st.markdown('<div class="section-title">Project Execution Roadmap</div>', unsafe_allow_html=True)
    labels = {cfg.PHASE_PLAN_APPRAISAL: "Plan Appraisal", cfg.PHASE_NSC_SURVEY: "NSC Survey", cfg.PHASE_IN_SERVICE: "In-Service Survey"}
    icons = {cfg.PHASE_PLAN_APPRAISAL: "📐", cfg.PHASE_NSC_SURVEY: "🏗️", cfg.PHASE_IN_SERVICE: "⚓"}
    selected = [r for r in phase_rows if r.get("status") != "NOT_APPLICABLE"]
    cols = st.columns(max(1, len(selected)))
    for col, row in zip(cols, selected):
        status = row.get("status", "LOCKED")
        kind = {"COMPLETED":"success", "IN_PROGRESS":"info", "READY":"success", "LOCKED":"warning", "BLOCKED":"danger"}.get(status, "neutral")
        with col:
            with st.container(border=True):
                st.markdown(f'<div style="font-size:12px;">{icons[row["phase"]]} <b>{labels[row["phase"]]}</b></div>', unsafe_allow_html=True)
                st.markdown(h.badge(status.replace("_", " "), kind), unsafe_allow_html=True)
                st.caption(row.get("gate_note") or "—")

    if vessel:
        sv = q.vessel_survey_status(vessel["id"])
        if sv:
            st.write("")
            c1, c2, c3, c4 = st.columns(4)
            c1.metric("Survey Status", str(sv.get("survey_status", "NOT_STARTED")).replace("_", " ").title())
            c2.metric("Class Status", vessel.get("class_status", "PENDING_CLASSIFICATION").replace("_", " ").title())
            c3.metric("Next Survey Due", h.fmt_date(sv.get("next_survey_due")) if sv.get("next_survey_due") else "—")
            c4.metric("Last Survey", h.fmt_date(sv.get("last_survey_date")) if sv.get("last_survey_date") else "—")

    # Explicit end-of-scope behavior.
    if selected and selected[-1].get("status") == "COMPLETED":
        st.success(f'All selected project phases are complete. This project has reached the end of its configured scope.')


def _locked_phase(gate: dict, label: str) -> None:
    st.warning(f'{label} is currently locked.')
    st.markdown(f'**Gate:** {gate.get("gate_note") or "Complete the preceding phase before starting this phase."}')


# -------------------------------------------------------------------------
# Project Info tab
# -------------------------------------------------------------------------

def _project_info_tab(project: dict, vessel: dict | None) -> None:
    col_particulars, col_team = st.columns([1.3, 1])

    with col_particulars:
        st.markdown('<div class="section-title">Vessel Particulars</div>', unsafe_allow_html=True)
        if vessel:
            rows = [
                ("IMO / Reg. No.", vessel.get("imo_number") or "—"),
                ("Owner", vessel.get("owner_company") or "—"),
                ("Length Overall", f'{vessel["loa_m"]} m' if vessel.get("loa_m") else "—"),
                ("Beam", f'{vessel["beam_m"]} m' if vessel.get("beam_m") else "—"),
                ("Draft", f'{vessel["draft_m"]} m' if vessel.get("draft_m") else "—"),
                ("Power", f'{vessel["power_kw"]:,.0f} kW' if vessel.get("power_kw") else "—"),
                ("Speed", f'{vessel["speed_knots"]} knots' if vessel.get("speed_knots") else "—"),
                ("Build Year", vessel.get("build_year") or "—"),
                ("Current Class", vessel.get("current_class") or "—"),
            ]
            with st.container(border=True):
                for label, value in rows:
                    c1, c2 = st.columns([1, 1.4])
                    c1.markdown(f'<span class="section-caption">{label}</span>', unsafe_allow_html=True)
                    c2.markdown(f"**{value}**")
        else:
            st.caption("No vessel record.")

        st.write("")
        st.markdown('<div class="section-title">Contract Documents</div>', unsafe_allow_html=True)
        docs = [d for d in q.list_documents(project["id"]) if d["category"] in
                (cfg.DOC_CATEGORY_CONTRACT, cfg.DOC_CATEGORY_RULES, cfg.DOC_CATEGORY_TIMELINE)]
        if not docs:
            st.caption("No contract documents uploaded yet.")
        for d in docs:
            with st.container(border=True):
                c1, c2 = st.columns([3, 1])
                c1.markdown(
                    f'<b>{d["file_name"]}</b><br>'
                    f'<span class="section-caption">{cfg.DOC_CATEGORY_LABELS[d["category"]]} · '
                    f'{h.relative_age(d["uploaded_at"])}</span>',
                    unsafe_allow_html=True,
                )
                with c2:
                    if st.button("View →", key=f"doc_view_{d['id']}", use_container_width=True):
                        open_document_dialog(d["id"])

    with col_team:
        st.markdown('<div class="section-title">Team &amp; Stakeholders</div>', unsafe_allow_html=True)
        team = q.list_team(project["id"])
        with st.container(border=True):
            if not team:
                st.caption("No internal team assigned.")
            for t in team:
                u = t.get("_user")
                disc = f" · {t['discipline']}" if t.get("discipline") else ""
                st.markdown(
                    f'<div style="padding:5px 0; border-bottom:1px solid var(--hairline-warm); font-size:13.5px;">'
                    f'<b>{u["full_name"] if u else "—"}</b><br>'
                    f'<span class="section-caption">{cfg.ROLE_LABELS.get(t["role"], t["role"])}{disc}</span></div>',
                    unsafe_allow_html=True,
                )

        st.write("")
        stakeholders = q.list_stakeholders(project["id"])
        with st.container(border=True):
            if not stakeholders:
                st.caption("No external stakeholders added.")
            for s in stakeholders:
                st.markdown(
                    f'<div style="padding:5px 0; border-bottom:1px solid var(--hairline-warm); font-size:13.5px;">'
                    f'<b>{s["company_name"]}</b><br>'
                    f'<span class="section-caption">{cfg.ROLE_LABELS.get(s["stakeholder_type"], s["stakeholder_type"])}'
                    f'{" · " + s["contact_name"] if s.get("contact_name") else ""}</span></div>',
                    unsafe_allow_html=True,
                )


# -------------------------------------------------------------------------
# Plan Appraisal tab
# -------------------------------------------------------------------------

def _plan_appraisal_tab(project: dict) -> None:
    """Render the upgraded multi-user plan appraisal control center."""
    plan_appraisal.render(project)
