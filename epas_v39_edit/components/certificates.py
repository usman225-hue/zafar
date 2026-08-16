"""
EPAS · Certificates
---------------------
Implements the flowchart's "+ Generate New Certificate" node exactly:

    Check observations for this vessel
        No open observations   → ISSUE CLASS CERTIFICATE enabled
        Open observations exist → ISSUE INTERIM CERTIFICATE enabled,
                                    Full Class Certificate disabled
    → PDF Generated & Archived

The dialog is shared by two callers: the RFI queue (pre-scoped to one
RFI, so the observation check is exact) and the Certificates page's
manual "+ Generate" flow (vessel picked by hand, so the check
aggregates every open observation across that vessel's RFI history).
"""

from __future__ import annotations

from datetime import date

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h
from components.pdf_certificate import generate_certificate_pdf


# =========================================================================
# The dialog — triggered from rfi_queue.py or the manual picker below
# =========================================================================

@h.modal("Issue Certificate", width="large")
def open_certificate_dialog(vessel_id: str, project_id: str, rfi_id: str | None,
                             survey_type: str | None = None) -> None:
    vessel = q.get_vessel(vessel_id)
    project = q.get_project(project_id)

    if rfi_id:
        open_obs = q.open_observations(rfi_id)
    else:
        # Manual flow — aggregate every open observation across the vessel's RFIs
        open_obs = []
        for r in q.list_rfis(project_id=project_id):
            if r["vessel_id"] == vessel_id:
                open_obs.extend(q.open_observations(r["id"]))

    st.markdown(
        f'<div class="eyebrow">{project["project_code"] if project else ""}</div>'
        f'<div class="section-title">{vessel["name"]}</div>'
        f'<div class="section-caption">{survey_type or "Certificate basis not tied to a single survey"}</div>',
        unsafe_allow_html=True,
    )
    st.write("")

    st.markdown("**Check observations for this vessel**")
    if open_obs:
        st.warning(f"{len(open_obs)} open observation(s) found — full Class Certificate is disabled.", icon="⚠️")
        for o in open_obs:
            st.markdown(
                f'<div style="display:flex; gap:8px; align-items:center; padding:3px 0; font-size:13px;">'
                f'{h.severity_badge(o["severity"])} <span class="mono" style="color:var(--ink-400); font-size:11px;">{o["obs_code"]}</span>'
                f'<span>{o["description"]}</span></div>',
                unsafe_allow_html=True,
            )
    else:
        st.success("No open observations — this vessel is eligible for a full Class Certificate.", icon="✅")

    st.markdown('<hr class="divider-hr" style="margin:16px 0;">', unsafe_allow_html=True)

    if open_obs:
        _interim_certificate_form(vessel, project, rfi_id, open_obs)
    else:
        _class_certificate_form(vessel, project, rfi_id, survey_type)


def _class_certificate_form(vessel, project, rfi_id, survey_type):
    st.markdown("**Issue Class Certificate**")
    default_months = cfg.CERT_VALIDITY_DEFAULT_MONTHS.get(survey_type, 12)
    months = st.selectbox(
        "Validity period", options=[12, 24, 60],
        index=[12, 24, 60].index(default_months) if default_months in (12, 24, 60) else 0,
        format_func=lambda m: f"{m} months",
        key=f"class_validity_{vessel['id']}_{rfi_id}",
    )
    if st.button("✅ Issue Class Certificate", type="primary", key=f"issue_class_{vessel['id']}_{rfi_id}"):
        cert = q.issue_certificate(vessel["id"], project["id"], rfi_id, cfg.CERT_TYPE_CLASS, months)
        _after_issue(cert, vessel)


def _interim_certificate_form(vessel, project, rfi_id, open_obs):
    st.markdown("**Issue Interim Certificate of Class**")
    st.caption("Validity is set by the GM and lists every pending observation on the certificate face.")
    months = st.selectbox(
        "Validity period (set by GM)", options=cfg.INTERIM_VALIDITY_OPTIONS_MONTHS,
        index=2, format_func=lambda m: f"{m} month{'s' if m != 1 else ''}",
        key=f"interim_validity_{vessel['id']}_{rfi_id}",
    )
    st.button(
        "🚫 Issue Class Certificate (disabled)", disabled=True,
        key=f"disabled_class_{vessel['id']}_{rfi_id}",
        help="Not available while observations remain open.",
    )
    if st.button("⚠️ Issue Interim Certificate", type="primary", key=f"issue_interim_{vessel['id']}_{rfi_id}"):
        descriptions = [f"{o['obs_code']} — {o['description']} ({o['severity']})" for o in open_obs]
        cert = q.issue_certificate(vessel["id"], project["id"], rfi_id, cfg.CERT_TYPE_INTERIM, months, descriptions)
        _after_issue(cert, vessel)


def _after_issue(cert: dict, vessel: dict) -> None:
    st.success(f"{cfg.CERT_TYPE_LABELS[cert['cert_type']]} **{cert['cert_number']}** issued and archived.", icon="📜")
    pdf_bytes = generate_certificate_pdf(cert, vessel, q.current_gm()["full_name"])
    st.download_button(
        "⬇ Download certificate PDF", data=pdf_bytes,
        file_name=f"{cert['cert_number']}.pdf", mime="application/pdf",
        key=f"dl_{cert['id']}",
    )
    st.caption("Sent to Shipyard & Owner · vessel record updated in the Ship Register.")
    if st.button("Done", key=f"done_{cert['id']}"):
        st.rerun()


# =========================================================================
# Seal card — the signature visual element, used on every issued certificate
# =========================================================================

_SEAL_TONE = {
    cfg.CERT_TYPE_CLASS: ("var(--green-700)", "success"),
    cfg.CERT_TYPE_INTERIM: ("var(--amber-700)", "warning"),
    cfg.CERT_TYPE_NSC: ("var(--blue-600)", "info"),
}


def _seal_card(cert: dict, scope: str = "default") -> None:
    vessel = cert.get("_vessel") or q.get_vessel(cert["vessel_id"])
    color, badge_kind = _SEAL_TONE.get(cert["cert_type"], ("var(--blue-600)", "neutral"))
    notation = {"class_certificate": "CLASS", "interim_certificate": "INTERIM", "nsc_certificate": "NEW BUILD"}[cert["cert_type"]]

    col_seal, col_body, col_action = st.columns([0.7, 3.6, 1.1])
    with col_seal:
        st.markdown(
            f'<div class="seal" style="--seal-color:{color};"><span class="seal-code">{notation}</span></div>',
            unsafe_allow_html=True,
        )
    with col_body:
        st.markdown(
            f'<div class="seal-cert-number">{cert["cert_number"]}</div>'
            f'<div class="seal-cert-type">{cfg.CERT_TYPE_LABELS[cert["cert_type"]]}</div>'
            f'<div class="seal-meta">{vessel["name"] if vessel else "—"} · issued {h.fmt_date(cert["issue_date"])} '
            f'· expires {h.fmt_date(cert["expiry_date"])} &nbsp; {h.days_remaining_badge(cert["expiry_date"])}</div>',
            unsafe_allow_html=True,
        )
        if cert.get("pending_observations"):
            with st.expander(f"{len(cert['pending_observations'])} outstanding observation(s) on this certificate"):
                for item in cert["pending_observations"]:
                    st.markdown(f"– {item}")
    with col_action:
        pdf_bytes = generate_certificate_pdf(cert, vessel, q.current_gm()["full_name"]) if vessel else None
        if pdf_bytes:
            st.download_button("⬇ PDF", data=pdf_bytes, file_name=f"{cert['cert_number']}.pdf",
                                mime="application/pdf", key=f"seal_dl_{scope}_{cert['id']}", use_container_width=True)
    st.markdown('<hr class="divider-hr" style="margin:10px 0 16px;">', unsafe_allow_html=True)


# =========================================================================
# Page renderers
# =========================================================================

def _expiring_soon_widget() -> None:
    expiring = q.expiring_soon_certificates()
    if not expiring:
        return
    st.markdown(
        f'<div class="card" style="border-left:3px solid var(--amber-700);">'
        f'<div class="section-title">⚠️ Expiring Soon</div>'
        f'<div class="section-caption">Active certificates due within {cfg.CERT_EXPIRING_SOON_DAYS} days</div>'
        f"</div>",
        unsafe_allow_html=True,
    )
    for cert in expiring:
        vessel = q.get_vessel(cert["vessel_id"])
        c1, c2, c3 = st.columns([2.4, 1.2, 1])
        with c1:
            st.markdown(f"**{vessel['name'] if vessel else '—'}** &nbsp; <span class='mono' style='color:var(--ink-400); font-size:12px;'>{cert['cert_number']}</span>", unsafe_allow_html=True)
        with c2:
            st.markdown(h.days_remaining_badge(cert["expiry_date"]), unsafe_allow_html=True)
        with c3:
            if st.button("Renew →", key=f"renew_{cert['id']}", use_container_width=True):
                open_certificate_dialog(cert["vessel_id"], cert["project_id"], None)
    st.write("")


def _generate_new_certificate_picker(project_id: str | None) -> None:
    with st.expander("➕ Generate New Certificate", expanded=False):
        vessels = q.list_vessels()
        if project_id:
            vessels = [v for v in vessels if v["project_id"] == project_id]
        if not vessels:
            st.caption("No vessels available.")
            return
        vessel_id = st.selectbox(
            "Vessel", options=[v["id"] for v in vessels],
            format_func=lambda vid: next(v["name"] for v in vessels if v["id"] == vid),
            key=f"gen_cert_vessel_{project_id}",
        )
        if st.button("Check observations & continue →", key=f"gen_cert_go_{project_id}"):
            v = next(v for v in vessels if v["id"] == vessel_id)
            open_certificate_dialog(vessel_id, v["project_id"], None)


def render_global() -> None:
    st.markdown(
        '<div class="eyebrow">Certificate Registry</div>'
        '<div class="page-title">Certificates</div>'
        '<div class="page-sub">Every certificate issued across the fleet — active, interim, and historical.</div>',
        unsafe_allow_html=True,
    )
    st.write("")
    _expiring_soon_widget()
    _generate_new_certificate_picker(project_id=None)
    st.write("")

    all_certs = q.list_certificates()
    tab_active, tab_interim, tab_all = st.tabs([
        f"Active ({len([c for c in all_certs if c['status']=='active'])})",
        f"Interim ({len([c for c in all_certs if c['cert_type']=='interim_certificate'])})",
        f"All ({len(all_certs)})",
    ])
    with tab_active:
        _render_cert_list([c for c in all_certs if c["status"] == cfg.CERT_STATUS_ACTIVE], scope="active")
    with tab_interim:
        _render_cert_list([c for c in all_certs if c["cert_type"] == cfg.CERT_TYPE_INTERIM], scope="interim")
    with tab_all:
        _render_cert_list(all_certs, scope="all")


def render_for_project(project_id: str) -> None:
    vessel = q.get_vessel_for_project(project_id)
    if not vessel:
        st.info("No vessel record on this project yet.")
        return

    certs = q.list_certificates(vessel_id=vessel["id"])
    expiring_ids = {c["id"] for c in q.expiring_soon_certificates()}
    expiring = [c for c in certs if c["id"] in expiring_ids]
    if expiring:
        st.warning(f"{len(expiring)} certificate(s) on this vessel expiring within "
                   f"{cfg.CERT_EXPIRING_SOON_DAYS} days.", icon="⚠️")

    _generate_new_certificate_picker(project_id=project_id)
    st.write("")
    _render_cert_list(certs)


def _render_cert_list(certs: list[dict], scope: str = "default") -> None:
    if not certs:
        st.markdown(
            '<div class="empty-state"><div class="empty-icon">📜</div>'
            '<div class="empty-title">No certificates yet</div>'
            '<div class="empty-sub">Issued certificates will appear here as seal cards.</div></div>',
            unsafe_allow_html=True,
        )
        return
    for cert in certs:
        _seal_card(cert, scope)


# Public re-export — reused by the Overview page.
expiring_soon_widget = _expiring_soon_widget
