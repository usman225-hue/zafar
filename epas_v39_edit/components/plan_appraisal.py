"""EPAS Plan Appraisal Control Center.

Production intent:
Designer -> GM/Plan Appraisal Manager -> Authorized Engineer -> Review ->
Observations -> Designer Response -> Re-review -> Manager Review -> GM Approval.

The demo implementation uses the existing session database. The same state
transitions are mirrored by the upgrade_schema.sql tables for Supabase.
"""
from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from database import upgrade_queries as uq
from utils import helpers as h


def render(project: dict | None = None) -> None:
    if project is None:
        pid = st.session_state.get("selected_project_id")
        project = q.get_project(pid) if pid else None
    if not project:
        st.warning("No project selected.")
        return

    st.markdown('<div class="section-title">Plan Appraisal Control Center</div>', unsafe_allow_html=True)
    st.caption("Controlled drawing workflow with manager handover, competency/authorization checks, revision control and GM approval.")

    drawings = uq.list_plan_drawings(project["id"])
    _summary(drawings)
    st.write("")

    pending_gm = [d for d in drawings if d["status"] == uq.PA_PENDING_GM]
    rejected_for_gm = [d for d in drawings if d["status"] == uq.PA_REJECTED]
    if pending_gm or rejected_for_gm:
        st.markdown('<div class="section-title">GM Action</div>', unsafe_allow_html=True)
        for d in pending_gm:
            _gm_review_card(d, project)
        for d in rejected_for_gm:
            _gm_designer_correction_card(d, project)

    st.markdown('<div class="section-title">Drawing Register</div>', unsafe_allow_html=True)
    if not drawings:
        st.info("No plan appraisal drawings have been submitted for this project.")
    for d in drawings:
        _drawing_card(d, project)


def _summary(drawings: list[dict]) -> None:
    total = len(drawings)
    approved = sum(d["status"] == uq.PA_APPROVED for d in drawings)
    observations = sum(len(uq.list_plan_observations(d["id"], open_only=True)) for d in drawings)
    pending = sum(d["status"] == uq.PA_PENDING_GM for d in drawings)
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Drawings", total)
    c2.metric("Approved", approved)
    c3.metric("Open Observations", observations)
    c4.metric("Pending GM", pending)


def _drawing_card(d: dict, project: dict) -> None:
    with st.container(border=True):
        engineer = q.get_user(d.get("engineer_id"))
        manager = q.get_user(d.get("manager_id"))
        status_label = uq.PA_STATUS_LABELS.get(d["status"], d["status"])
        st.markdown(
            f'<div class="row-title-line"><span class="row-code">{d["drawing_no"]}</span>'
            f'<span class="row-vessel">{d["title"]}</span>'
            f'{h.badge(status_label, uq.status_badge_kind(d["status"]))}</div>'
            f'<div class="row-meta">Rev {d["revision"]} · {d["discipline"]} · '
            f'Manager: {manager["full_name"] if manager else "Unassigned"} · '
            f'Engineer: {engineer["full_name"] if engineer else "Unassigned"}</div>',
            unsafe_allow_html=True,
        )
        st.progress(uq.plan_progress(d["status"]))

        if d["status"] in (uq.PA_SUBMITTED, uq.PA_DESIGNER_RESPONSE):
            _manager_assignment(d, project)
        elif d["status"] in (uq.PA_ASSIGNED_ENGINEER, uq.PA_UNDER_REVIEW, uq.PA_REVIEW_RESUBMITTED):
            _resource_snapshot(d)
        elif d["status"] == uq.PA_OBSERVATION_RAISED:
            obs = uq.list_plan_observations(d["id"], open_only=True)
            for o in obs:
                st.warning(f'{o["obs_code"]} · {o["severity"]}: {o["description"]}')
        elif d["status"] == uq.PA_MANAGER_REVIEW:
            st.info("Engineer review completed. Manager review is required before GM sign-off.")
        elif d["status"] == uq.PA_APPROVED:
            st.success("Approved drawing — current revision is locked.")

        with st.expander("Revision history / workflow", expanded=False):
            for r in uq.list_document_revisions(d["document_id"]):
                st.markdown(f'**Rev {r["revision"]}** · {r["status"]} · {r["file_name"]} · {r["created_at"]}')
            events = uq.list_plan_events(d["id"])
            for e in events:
                actor = q.get_user(e.get("actor_id"))
                st.caption(f'{e["created_at"]} · {actor["full_name"] if actor else "System"} · {e["event_type"]} · {e.get("note", "")}')


def _manager_assignment(d: dict, project: dict) -> None:
    dms = q.list_users(role=cfg.ROLE_DM)
    eligible = [u for u in dms if uq.is_project_manager_eligible(project["id"], u["id"])]
    if not eligible:
        st.error("No eligible Plan Appraisal Manager is available for this project.")
        return
    options = [u["id"] for u in eligible]
    selected = st.selectbox("Plan Appraisal Manager", options, format_func=lambda x: q.get_user(x)["full_name"], key=f"pa_mgr_{d['id']}")
    if st.button("Hand over to Manager →", key=f"pa_handover_{d['id']}", type="primary"):
        uq.assign_plan_manager(d["id"], selected, q.current_gm()["id"])
        st.toast("Plan appraisal handed over to the manager.", icon="📨")
        st.rerun()


def _resource_snapshot(d: dict) -> None:
    engineer = q.get_user(d.get("engineer_id"))
    if engineer:
        check = uq.engineer_eligibility(engineer["id"], d["discipline"])
        st.markdown(f'**Assigned engineer:** {engineer["full_name"]}')
        st.caption(" · ".join(check["reasons"]))


def _gm_review_card(d: dict, project: dict) -> None:
    with st.container(border=True):
        st.markdown(f'**{d["drawing_no"]} — {d["title"]}** · Rev {d["revision"]}')
        st.write(f'Discipline: **{d["discipline"]}**')
        st.success("Manager has completed review and forwarded this drawing to GM.")
        obs = uq.list_plan_observations(d["id"], open_only=True)
        if obs:
            st.warning(f"{len(obs)} open observation(s) remain.")
            for o in obs:
                st.markdown(f'- **{o["obs_code"]}** · {o["severity"]}: {o["description"]}')
        note = st.text_area("GM decision / Designer instruction", key=f"gm_pa_note_{d['id']}")
        c1, c2, c3 = st.columns(3)
        with c1:
            if st.button("✅ Approve Drawing", key=f"gm_pa_approve_{d['id']}", type="primary", use_container_width=True):
                uq.gm_plan_decision(d["id"], "approved", note, q.current_gm()["id"])
                st.rerun()
        with c2:
            if st.button("✏️ Send to Designer", key=f"gm_pa_designer_{d['id']}", use_container_width=True):
                if not note.strip():
                    st.error("Add the Designer correction instruction.")
                else:
                    uq.gm_send_to_designer(d["id"], q.current_gm()["id"], note)
                    st.rerun()
        with c3:
            if st.button("↩ Return to Manager", key=f"gm_pa_return_{d['id']}", use_container_width=True):
                if not note.strip():
                    st.error("Add a reason before returning.")
                else:
                    uq.gm_plan_decision(d["id"], "returned", note, q.current_gm()["id"])
                    st.rerun()


def _gm_designer_correction_card(d: dict, project: dict) -> None:
    with st.container(border=True):
        st.markdown(f'**{d["drawing_no"]} — {d["title"]}** · Rev {d["revision"]}')
        st.warning("Manager marked the design as rejected / amended. GM must send it to the Designer for correction.")
        note = st.text_area("GM instruction to Designer", key=f"gm_designer_note_{d["id"]}")
        if st.button("Send to Designer for Correction →", key=f"gm_to_designer_{d["id"]}", type="primary"):
            if not note.strip():
                st.error("Enter the correction instruction before sending.")
            else:
                uq.gm_send_to_designer(d["id"], q.current_gm()["id"], note)
                st.rerun()
