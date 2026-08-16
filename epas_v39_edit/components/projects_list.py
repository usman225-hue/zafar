"""
EPAS · Projects List View
---------------------------
The flowchart's "Projects List View → Filter: All / Active / Closed"
node, plus the "+ NEW PROJECT" primary action that opens the wizard.
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h

_PHASE_BADGE_KIND = {
    cfg.PHASE_PLAN_APPRAISAL: "info",
    cfg.PHASE_NSC_SURVEY: "action",
    cfg.PHASE_IN_SERVICE: "success",
}

_STATUS_BADGE_KIND = {
    cfg.PROJECT_STATUS_ACTIVE: "success",
    cfg.PROJECT_STATUS_ON_HOLD: "warning",
    cfg.PROJECT_STATUS_CLOSED: "neutral",
}


def render() -> None:
    header_col, action_col = st.columns([4, 1])
    with header_col:
        st.markdown(
            '<div class="eyebrow">Project Register</div>'
            '<div class="page-title">Projects</div>'
            '<div class="page-sub">Every project on the books — filter by status or open one to enter its workspace.</div>',
            unsafe_allow_html=True,
        )
    role = q.profile().get("role") if hasattr(q, "profile") else None
    with action_col:
        st.write("")
        st.write("")
        if role == "gm" and st.button("+ New Project", type="primary", use_container_width=True, key="projects_new_btn"):
            st.session_state["page"] = "wizard"
            st.rerun()

    st.write("")
    search = st.text_input("Search projects", placeholder="Search by name, code, or vessel type…",
                            label_visibility="collapsed")

    tab_all, tab_active, tab_hold, tab_closed = st.tabs([
        f"All ({len(q.list_projects())})",
        f"Active ({len(q.list_projects(cfg.PROJECT_STATUS_ACTIVE))})",
        f"On Hold ({len(q.list_projects(cfg.PROJECT_STATUS_ON_HOLD))})",
        f"Closed ({len(q.list_projects(cfg.PROJECT_STATUS_CLOSED))})",
    ])
    with tab_all:
        _render_list(q.list_projects(), search, scope="all")
    with tab_active:
        _render_list(q.list_projects(cfg.PROJECT_STATUS_ACTIVE), search, scope="active")
    with tab_hold:
        _render_list(q.list_projects(cfg.PROJECT_STATUS_ON_HOLD), search, scope="hold")
    with tab_closed:
        _render_list(q.list_projects(cfg.PROJECT_STATUS_CLOSED), search, scope="closed")


def _render_list(projects: list[dict], search: str, scope: str) -> None:
    if search:
        needle = search.lower()
        projects = [
            p for p in projects
            if needle in p["name"].lower() or needle in p["project_code"].lower()
            or needle in p["vessel_type"].lower()
        ]

    if not projects:
        st.markdown(
            '<div class="empty-state"><div class="empty-icon">📁</div>'
            '<div class="empty-title">No projects here</div>'
            '<div class="empty-sub">Try a different filter or open an available project.</div></div>',
            unsafe_allow_html=True,
        )
        return

    for p in projects:
        _render_project_card(p, scope)


def _render_project_card(p: dict, scope: str) -> None:
    vessel = q.get_vessel_for_project(p["id"])
    rfis = q.list_rfis(project_id=p["id"])
    open_actions = len([r for r in rfis if r["status"] in cfg.RFI_GM_ACTIONABLE])
    phase_badges = "".join(
        h.badge(cfg.PHASE_LABELS[ph], _PHASE_BADGE_KIND.get(ph, "neutral")) + " " for ph in p["phases"]
    )
    action_badge = f'<span class="badge badge--action">⚑ {open_actions} need action</span>' if open_actions else ""
    imo_bit = ""
    if vessel and vessel.get("imo_number") not in (None, "—"):
        imo_bit = f'· IMO {vessel["imo_number"]}'

    with st.container(border=True):
        c1, c2 = st.columns([4, 1])
        with c1:
            st.markdown(
                f'<div class="row-title-line">'
                f'<span class="row-code">{p["project_code"]}</span>'
                f'<span class="row-vessel">{p["name"]}</span>'
                f'{h.badge(cfg.PROJECT_STATUS_LABELS[p["status"]], _STATUS_BADGE_KIND.get(p["status"], "neutral"))}'
                f'{action_badge}'
                f'</div>'
                f'<div class="row-meta">{p["vessel_type"]} · {p["flag_state"]} {imo_bit}'
                f' · created {h.relative_age(p["created_at"])}</div>'
                f'<div style="margin-top:6px;">{phase_badges}</div>',
                unsafe_allow_html=True,
            )
        with c2:
            st.write("")
            if st.button("Open →", key=f"open_proj_{scope}_{p['id']}", use_container_width=True):
                st.session_state["page"] = "workspace"
                st.session_state["selected_project_id"] = p["id"]
                st.rerun()
