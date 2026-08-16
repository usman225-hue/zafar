"""
EPAS · Ship Register
----------------------
The flowchart's "Global Ship Register — visible after certificate
issued" node. Every vessel that has ever had a certificate issued
carries a permanent bio, its full survey history, a certificate
ledger, and an auto-calculated next-due date read straight off the
most recent certificate's expiry.
"""

from __future__ import annotations

import csv
import io

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h
from components.certificates import _seal_card  # reuse the seal card renderer


def render() -> None:
    st.markdown(
        '<div class="eyebrow">Global Ship Register</div>'
        '<div class="page-title">Ship Register</div>'
        '<div class="page-sub">Every classed vessel — bio, complete survey history, and certificate ledger.</div>',
        unsafe_allow_html=True,
    )
    st.write("")

    rows = q.ship_register_rows()
    search = st.text_input("Search vessels", placeholder="Vessel name, IMO, flag…", label_visibility="collapsed")
    if search:
        needle = search.lower()
        rows = [r for r in rows if needle in r["vessel"]["name"].lower()
                or needle in str(r["vessel"].get("imo_number", "")).lower()
                or needle in r["vessel"]["flag_state"].lower()]

    if not rows:
        st.markdown(
            '<div class="empty-state"><div class="empty-icon">🧭</div>'
            '<div class="empty-title">No vessels match</div></div>',
            unsafe_allow_html=True,
        )
        return

    header = st.columns([2.3, 1.1, 1.1, 1.6, 1.5, 1.6, 1])
    for col, label in zip(header, ["Vessel", "Flag", "Class", "Survey Status", "Latest Certificate", "Next Due", ""]):
        col.markdown(f'<span class="section-caption" style="font-weight:700;">{label}</span>', unsafe_allow_html=True)
    st.markdown('<hr class="divider-hr" style="margin:6px 0 4px;">', unsafe_allow_html=True)

    for row in rows:
        vessel, cert = row["vessel"], row["latest_cert"]
        c = st.columns([2.3, 1.1, 1.1, 1.6, 1.5, 1.6, 1])
        survey = q.vessel_survey_status(vessel["id"])
        c[0].markdown(
            f'<b style="font-family:var(--font-display);">{vessel["name"]}</b><br>'
            f'<span class="mono" style="font-size:11.5px; color:var(--ink-400);">{vessel.get("imo_number") or "—"}</span>',
            unsafe_allow_html=True,
        )
        c[1].markdown(vessel["flag_state"])
        c[2].markdown(f'<span style="font-size:12.5px;">{vessel.get("current_class") or "—"}</span>', unsafe_allow_html=True)
        c[3].markdown(h.badge(str(survey.get("survey_status", "NOT_STARTED")).replace("_", " ").title(), "success" if survey.get("survey_status") in ("CLASS_ACTIVE","IN_SERVICE_COMPLETE","PROJECT_CLOSED") else "info"), unsafe_allow_html=True)
        if cert:
            c[4].markdown(
                f'<span class="mono" style="font-size:12px;">{cert["cert_number"]}</span><br>'
                f'<span class="section-caption">{cfg.CERT_TYPE_LABELS[cert["cert_type"]]}</span>',
                unsafe_allow_html=True,
            )
            c[5].markdown(h.days_remaining_badge(cert["expiry_date"]), unsafe_allow_html=True)
        else:
            c[4].markdown('<span class="section-caption">No certificate yet</span>', unsafe_allow_html=True)
            c[5].markdown("—")
        if c[6].button("View →", key=f"reg_view_{vessel['id']}", use_container_width=True):
            open_vessel_dialog(vessel["id"])
        st.markdown('<hr class="divider-hr" style="margin:4px 0;">', unsafe_allow_html=True)


@h.modal("Vessel Record", width="large")
def open_vessel_dialog(vessel_id: str) -> None:
    vessel = q.get_vessel(vessel_id)
    if not vessel:
        st.error("Vessel not found.")
        return

    certs = q.list_certificates(vessel_id=vessel_id)
    history = [r for r in q.list_rfis() if r["vessel_id"] == vessel_id]
    history.sort(key=lambda r: r["created_at"], reverse=True)

    st.markdown(
        f'<div class="eyebrow">{vessel["flag_state"]} · {vessel.get("current_class") or "Unclassed"}</div>'
        f'<div class="section-title" style="font-size:22px;">{vessel["name"]}</div>',
        unsafe_allow_html=True,
    )
    if certs:
        st.markdown(
            f'<div class="section-caption">Next survey due '
            f'{h.fmt_date(certs[0]["expiry_date"])} &nbsp; {h.days_remaining_badge(certs[0]["expiry_date"])}</div>',
            unsafe_allow_html=True,
        )
    st.write("")

    tab_bio, tab_history, tab_certs, tab_export = st.tabs(
        ["🧾 Vessel Bio", "🕐 Survey History", "📜 Certificate Ledger", "⬇ Export"]
    )

    with tab_bio:
        bio_rows = [
            ("IMO / Reg. No.", vessel.get("imo_number") or "—"),
            ("Flag State", vessel["flag_state"]),
            ("Owner", vessel.get("owner_company") or "—"),
            ("Length Overall", f'{vessel["loa_m"]} m' if vessel.get("loa_m") else "—"),
            ("Beam", f'{vessel["beam_m"]} m' if vessel.get("beam_m") else "—"),
            ("Draft", f'{vessel["draft_m"]} m' if vessel.get("draft_m") else "—"),
            ("Power", f'{vessel["power_kw"]:,.0f} kW' if vessel.get("power_kw") else "—"),
            ("Speed", f'{vessel["speed_knots"]} knots' if vessel.get("speed_knots") else "—"),
            ("Build Year", vessel.get("build_year") or "—"),
        ]
        for label, value in bio_rows:
            c1, c2 = st.columns([1, 2])
            c1.markdown(f'<span class="section-caption">{label}</span>', unsafe_allow_html=True)
            c2.markdown(f"**{value}**")

        project = q.get_project(vessel["project_id"])
        if project and st.button("↗ View in Project Workspace", key=f"gotoproj_{vessel_id}"):
            st.session_state["page"] = "workspace"
            st.session_state["selected_project_id"] = project["id"]
            st.rerun()

    with tab_history:
        if not history:
            st.caption("No surveys on record yet.")
        for rfi in history:
            st.markdown(
                f'<div class="row-card row-card--priority-{rfi["priority"]}">'
                f'<div class="row-title-line"><span class="row-code">{rfi["rfi_code"]}</span>'
                f'<span style="font-weight:600;">{rfi["survey_type"]}</span>'
                f'{h.rfi_status_badge(rfi["status"])}</div>'
                f'<div class="row-meta">{h.phase_icon_label(rfi["phase"])} · requested {h.relative_age(rfi["requested_date"])}</div>'
                f'</div>',
                unsafe_allow_html=True,
            )

    with tab_certs:
        if not certs:
            st.caption("No certificates issued yet.")
        for cert in certs:
            _seal_card(cert)

    with tab_export:
        st.caption("Export this vessel's certificate ledger for offline records or a flag-state audit.")
        csv_bytes = _certificate_ledger_csv(vessel, certs)
        st.download_button(
            "⬇ Download Certificate Ledger (CSV)", data=csv_bytes,
            file_name=f"{vessel['name'].replace(' ', '_')}_certificate_ledger.csv",
            mime="text/csv", key=f"export_csv_{vessel_id}",
        )


def _certificate_ledger_csv(vessel: dict, certs: list[dict]) -> bytes:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["Vessel", "IMO", "Flag", "Certificate Number", "Type", "Issue Date", "Expiry Date", "Status"])
    for c in certs:
        writer.writerow([
            vessel["name"], vessel.get("imo_number", ""), vessel["flag_state"],
            c["cert_number"], cfg.CERT_TYPE_LABELS[c["cert_type"]],
            h.fmt_date(c["issue_date"]), h.fmt_date(c["expiry_date"]), c["status"],
        ])
    return buf.getvalue().encode("utf-8")
