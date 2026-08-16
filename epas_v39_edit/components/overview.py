"""
EPAS · Overview
-----------------
The flowchart's "GM Dashboard" landing node, sitting just before the
"Primary Actions" decision (New Project vs. open Projects). Surfaces
everything that needs the GM's signature — across both NSC and
In-Service RFIs — in one combined queue, plus expiring certificates
and the most recently touched projects.
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h
from components import kpi_cards, rfi_queue, certificates


def render() -> None:
    st.markdown(
        '<div class="eyebrow">GM Dashboard</div>'
        '<div class="page-title">Good day, Captain.</div>'
        '<div class="page-sub">Here\'s everything on your desk right now.</div>',
        unsafe_allow_html=True,
    )
    st.write("")
    kpi_cards.render()
    st.write("")

    col_action, col_side = st.columns([2, 1.1])

    with col_action:
        _needs_your_signature()

    with col_side:
        certificates.expiring_soon_widget()
        _recent_projects()

    st.write("")
    _primary_actions()


def _needs_your_signature() -> None:
    st.markdown('<div class="section-title">Needs Your Signature</div>', unsafe_allow_html=True)
    st.markdown('<div class="section-caption" style="margin-bottom:10px;">'
                'Combined across NSC and In-Service RFIs, most urgent first.</div>', unsafe_allow_html=True)

    actionable = q.gm_actionable_rfis()
    if not actionable:
        st.markdown(
            '<div class="empty-state"><div class="empty-icon">🎉</div>'
            '<div class="empty-title">Nothing waiting on you</div>'
            '<div class="empty-sub">New RFIs and approvals will appear here.</div></div>',
            unsafe_allow_html=True,
        )
        return

    priority_rank = {"high": 0, "medium": 1, "low": 2}
    actionable.sort(key=lambda r: (priority_rank.get(r["priority"], 1), r["created_at"]))

    for rfi in actionable:
        if rfi["status"] == cfg.RFI_PENDING_ALLOCATION:
            rfi_queue.render_allocation_card(rfi)
        elif rfi["status"] == cfg.RFI_PENDING_GM_APPROVAL:
            rfi_queue.render_approval_card(rfi)


def _recent_projects() -> None:
    st.write("")
    st.markdown('<div class="section-title">Recent Projects</div>', unsafe_allow_html=True)
    projects = q.list_projects()[:5]
    if not projects:
        st.caption("No projects yet.")
        return
    with st.container(border=True):
        for p in projects:
            c1, c2 = st.columns([3, 1])
            c1.markdown(
                f'<span class="row-code">{p["project_code"]}</span> <b>{p["name"]}</b><br>'
                f'<span class="section-caption">{h.relative_age(p["created_at"])}</span>',
                unsafe_allow_html=True,
            )
            with c2:
                if st.button("Open", key=f"recent_open_{p['id']}", use_container_width=True):
                    st.session_state["page"] = "workspace"
                    st.session_state["selected_project_id"] = p["id"]
                    st.rerun()


def _primary_actions() -> None:
    st.markdown('<hr class="divider-hr">', unsafe_allow_html=True)
    st.markdown('<div class="section-title">Primary Actions</div>', unsafe_allow_html=True)
    c1, c2 = st.columns(2)
    role = q.profile().get("role") if hasattr(q, "profile") else None
    with c1:
        if role == "gm" and st.button("+ New Project", type="primary", use_container_width=True, key="overview_new_project"):
            st.session_state["page"] = "wizard"
            st.rerun()
    with c2:
        if st.button("📁 Browse All Projects", use_container_width=True, key="overview_browse_projects"):
            st.session_state["page"] = "projects"
            st.rerun()
