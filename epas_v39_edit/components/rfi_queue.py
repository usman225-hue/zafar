"""
EPAS · RFI Queue
-----------------
Implements the RFI spine of the flowchart end-to-end:

    Pending Allocation → [GM: Assign to DM] → Allocated to DM
        → Survey in Progress → Observations Logged → Pending GM Approval
        (the DM/Surveyor steps happen off a GM-only dashboard in real
         life; a clearly-labelled "Simulate next step" control stands
         in for them here so the whole loop is exercisable)
    Pending GM Approval → [GM: Approve | Send Back]
        Send Back  → Returned for Rework → (DM resubmits) → back to Pending GM Approval
        Approve, no open observations    → Approved (Clean)    → Class Certificate eligible
        Approve, observations still open → Approved (w/ Obs.)  → Interim Certificate required
    → Certificate Issued / Closed
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from database import upgrade_queries as uq
from utils import helpers as h
from components.certificates import open_certificate_dialog


def render(phase: str, project_id: str | None = None) -> None:
    phase_label = cfg.PHASE_LABELS[phase]
    all_rfis = q.list_rfis(phase=phase, project_id=project_id)

    if not all_rfis:
        st.markdown(
            f'<div class="empty-state"><div class="empty-icon">🗂️</div>'
            f'<div class="empty-title">No {phase_label} RFIs yet</div>'
            f'<div class="empty-sub">New requests for inspection will appear here once received.</div></div>',
            unsafe_allow_html=True,
        )
        return

    needs_allocation = [r for r in all_rfis if r["status"] == cfg.RFI_PENDING_ALLOCATION]
    needs_approval = [r for r in all_rfis if r["status"] == cfg.RFI_PENDING_GM_APPROVAL]
    in_progress = [r for r in all_rfis if r["status"] in
                   (cfg.RFI_ALLOCATED, cfg.RFI_SURVEY_IN_PROGRESS, cfg.RFI_OBSERVATIONS_LOGGED)]
    sent_back = [r for r in all_rfis if r["status"] == cfg.RFI_SENT_BACK]
    ready_to_certify = [r for r in all_rfis if r["status"] in
                         (cfg.RFI_APPROVED_CLEAN, cfg.RFI_APPROVED_WITH_OBS)]
    closed = [r for r in all_rfis if r["status"] in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED)]

    action_count = len(needs_allocation) + len(needs_approval)
    if action_count:
        st.markdown(f'<span class="badge badge--action">⚑ {action_count} need your signature</span>',
                     unsafe_allow_html=True)
        st.write("")

    if needs_allocation:
        _section_header("Pending Allocation", len(needs_allocation),
                         "New requests for inspection — assign a Department Manager to begin the survey.")
        for rfi in needs_allocation:
            _render_allocation_card(rfi)

    if needs_approval:
        _section_header("Pending Your Approval", len(needs_approval),
                         "Survey complete, observations reviewed by the DM — your decision closes the loop.")
        for rfi in needs_approval:
            _render_approval_card(rfi)

    if ready_to_certify:
        _section_header("Ready to Certify", len(ready_to_certify),
                         "Approved — issue the certificate to close out the survey.")
        for rfi in ready_to_certify:
            _render_ready_to_certify_card(rfi)

    if in_progress:
        with st.expander(f"🔄 In Progress ({len(in_progress)})", expanded=False):
            for rfi in in_progress:
                _render_readonly_card(rfi, show_dev_advance=True)

    if sent_back:
        with st.expander(f"↩️ Returned for Rework ({len(sent_back)})", expanded=False):
            for rfi in sent_back:
                _render_sent_back_card(rfi)

    if closed:
        with st.expander(f"✅ Closed / Certified ({len(closed)})", expanded=False):
            for rfi in closed:
                _render_readonly_card(rfi, show_dev_advance=False)


# -------------------------------------------------------------------------
# Section / row rendering helpers
# -------------------------------------------------------------------------

def _section_header(title: str, count: int, caption: str) -> None:
    st.markdown(
        f'<div style="margin-top:18px;"><span class="section-title">{title}</span> '
        f'<span class="badge badge--neutral">{count}</span></div>'
        f'<div class="section-caption" style="margin-bottom:10px;">{caption}</div>',
        unsafe_allow_html=True,
    )


def _row_header_html(rfi: dict, extra_badges: str = "") -> str:
    v = rfi["_vessel"]
    p = rfi["_project"]
    return (
        f'<div class="row-title-line">'
        f'<span class="row-code">{rfi["rfi_code"]}</span>'
        f'<span class="row-vessel">{v["name"] if v else "—"}</span>'
        f'{h.priority_badge(rfi["priority"])}'
        f'{h.rfi_status_badge(rfi["status"])}'
        f'{extra_badges}'
        f'</div>'
        f'<div class="row-meta">{rfi["survey_type"]} · requested {h.relative_age(rfi["requested_date"])}'
        f'{" · " + p["project_code"] if p else ""}</div>'
    )


def _render_allocation_card(rfi: dict) -> None:
    with st.container(border=True):
        st.markdown(_row_header_html(rfi), unsafe_allow_html=True)
        dms = q.list_users(role=cfg.ROLE_DM)
        col1, col2 = st.columns([3, 1])
        with col1:
            dm_id = st.selectbox(
                "Assign to Department Manager",
                options=[d["id"] for d in dms],
                format_func=lambda uid: next(d["full_name"] for d in dms if d["id"] == uid),
                key=f"dm_select_{rfi['id']}",
                label_visibility="collapsed",
            )
        with col2:
            if st.button("Assign to DM →", key=f"assign_{rfi['id']}", type="primary", use_container_width=True):
                try:
                    uq.handover_rfi_to_dm(rfi["id"], dm_id, q.current_gm()["id"])
                    st.toast(f"{rfi['rfi_code']} handed over to DM — task and notification created.", icon="📨")
                    st.rerun()
                except ValueError as exc:
                    st.error(str(exc))


def _render_approval_card(rfi: dict) -> None:
    open_obs = [o for o in rfi["_observations"] if o["status"] == cfg.OBS_OPEN]
    with st.container(border=True):
        st.markdown(_row_header_html(rfi), unsafe_allow_html=True)
        st.markdown(h.stage_track_html(rfi["status"]), unsafe_allow_html=True)

        dm, surveyor = rfi["_dm"], rfi["_surveyor"]
        st.markdown(
            f'<div class="row-meta">Reviewed by <b>{dm["full_name"] if dm else "—"}</b> (DM) '
            f'· surveyed by <b>{surveyor["full_name"] if surveyor else "—"}</b></div>',
            unsafe_allow_html=True,
        )

        if open_obs:
            st.markdown(f"**Open observations ({len(open_obs)})**")
            for o in open_obs:
                st.markdown(
                    f'<div style="display:flex; gap:8px; align-items:center; padding:4px 0; font-size:13px;">'
                    f'{h.severity_badge(o["severity"])} '
                    f'<span class="mono" style="color:var(--ink-400); font-size:11px;">{o["obs_code"]}</span>'
                    f'<span>{o["description"]}</span></div>',
                    unsafe_allow_html=True,
                )
            st.caption("⚠️ Approving with open observations routes to an **Interim Certificate**.")
        else:
            st.success("No open observations — clean survey, eligible for a full Class Certificate.", icon="✅")

        note = st.text_area(
            "Note (required if sending back)", key=f"note_{rfi['id']}", height=68,
            placeholder="e.g. Evidence photos missing for OBS-014-02 — resubmit with photo log.",
        )
        c1, c2 = st.columns(2)
        with c1:
            if st.button("✅ Approve", key=f"approve_{rfi['id']}", type="primary", use_container_width=True):
                q.gm_decide(rfi["id"], "approved", note)
                st.toast(f"{rfi['rfi_code']} approved.", icon="✅")
                st.rerun()
        with c2:
            if st.button("↩ Send Back for Rework", key=f"sendback_{rfi['id']}", use_container_width=True):
                if not note.strip():
                    st.error("Add a note explaining what needs correcting before sending back.")
                else:
                    q.gm_decide(rfi["id"], "sent_back", note)
                    uq.route_gm_return_to_dm(rfi["id"], q.current_gm()["id"], note)
                    st.toast(f"{rfi['rfi_code']} returned to DM with corrective-action task.", icon="↩️")
                    st.rerun()


def _render_ready_to_certify_card(rfi: dict) -> None:
    clean = rfi["status"] == cfg.RFI_APPROVED_CLEAN
    extra = h.badge("Full Certificate Eligible", "success") if clean else h.badge("Interim Certificate Required", "warning")
    with st.container(border=True):
        st.markdown(_row_header_html(rfi, extra_badges=extra), unsafe_allow_html=True)
        if st.button("📜 Issue Certificate →", key=f"cert_{rfi['id']}", type="primary"):
            open_certificate_dialog(rfi["_vessel"]["id"], rfi["project_id"], rfi["id"], rfi["survey_type"])


def _render_readonly_card(rfi: dict, show_dev_advance: bool) -> None:
    with st.container(border=True):
        st.markdown(_row_header_html(rfi), unsafe_allow_html=True)
        st.markdown(h.stage_track_html(rfi["status"]), unsafe_allow_html=True)

        dm, surveyor = rfi["_dm"], rfi["_surveyor"]
        meta_bits = []
        if dm:
            meta_bits.append(f"DM: <b>{dm['full_name']}</b>")
        if surveyor:
            meta_bits.append(f"Surveyor: <b>{surveyor['full_name']}</b>")
        if rfi.get("scheduled_date"):
            meta_bits.append(f"Scheduled: {h.fmt_date(rfi['scheduled_date'])}")
        if meta_bits:
            st.markdown(f'<div class="row-meta">{" · ".join(meta_bits)}</div>', unsafe_allow_html=True)

        if rfi["status"] in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED) and rfi["_vessel"]:
            certs = q.list_certificates(vessel_id=rfi["_vessel"]["id"])
            linked = next((c for c in certs if c.get("rfi_id") == rfi["id"]), None)
            if linked:
                st.caption(f"📜 {cfg.CERT_TYPE_LABELS[linked['cert_type']]} · {linked['cert_number']}")

        if show_dev_advance:
            st.info("This RFI is being progressed by the Department Manager / Surveyor in their own dashboard. No GM stage-simulation control is used in the multi-user workflow.")


def _render_sent_back_card(rfi: dict) -> None:
    with st.container(border=True):
        st.markdown(_row_header_html(rfi), unsafe_allow_html=True)
        decisions = q.list_gm_decisions(rfi["id"])
        last = decisions[0] if decisions else None
        if last and last.get("note"):
            st.markdown(f'<div class="row-meta">🗒️ GM note: "{last["note"]}"</div>', unsafe_allow_html=True)
        st.info("Corrective-action task has been routed to the assigned Department Manager. The DM will coordinate corrective action and create the follow-up RFI.")


# Public re-exports — reused by the Overview page's combined "Needs Your
# Signature" queue, which spans both phases in one place.
render_allocation_card = _render_allocation_card
render_approval_card = _render_approval_card
