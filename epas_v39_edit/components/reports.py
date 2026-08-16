"""
EPAS · Survey Logs & Reports
------------------------------
The flowchart's "Survey Logs & Reports" tab: Audit Trail (chronological
survey activity), Remarks History (master list of all observations /
document remarks), and a Reports Archive export.
"""

from __future__ import annotations

import csv
import io

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h

_ACTION_LABELS = {
    "PROJECT_CREATED": ("🚀", "Project created"),
    "RFI_RECEIVED": ("📥", "RFI received"),
    "RFI_ASSIGNED": ("📨", "RFI assigned to DM"),
    "RFI_APPROVED": ("✅", "RFI approved by GM"),
    "RFI_SENT_BACK": ("↩️", "RFI sent back for rework"),
    "RFI_RESUBMITTED": ("🔁", "RFI resubmitted"),
    "CERTIFICATE_ISSUED": ("📜", "Certificate issued"),
    "DEMO_STAGE_ADVANCED": ("🔧", "Stage advanced (demo)"),
    "DOCUMENT_STATUS_CHANGED": ("📄", "Document status changed"),
}


def render(project_id: str | None = None) -> None:
    if project_id is None:
        st.markdown(
            '<div class="eyebrow">Fleet-Wide</div>'
            '<div class="page-title">Survey Logs &amp; Reports</div>'
            '<div class="page-sub">Audit trail, remarks history, and exportable reports across every project.</div>',
            unsafe_allow_html=True,
        )
        st.write("")

    tab_audit, tab_remarks, tab_archive = st.tabs(["🕐 Audit Trail", "💬 Remarks History", "📦 Reports Archive"])

    with tab_audit:
        _render_audit_trail(project_id)
    with tab_remarks:
        _render_remarks_history(project_id)
    with tab_archive:
        _render_reports_archive(project_id)


def _render_audit_trail(project_id: str | None) -> None:
    entries = q.audit_trail(project_id)
    if not entries:
        st.markdown(
            '<div class="empty-state"><div class="empty-icon">🕐</div>'
            '<div class="empty-title">No activity recorded yet</div></div>',
            unsafe_allow_html=True,
        )
        return
    for e in entries:
        icon, label = _ACTION_LABELS.get(e["action"], ("•", e["action"].replace("_", " ").title()))
        detail = e["details"].get("rfi_code") or e["details"].get("cert_number") or e["details"].get("project_code") or e["details"].get("file_name") or ""
        actor = e.get("_actor")
        st.markdown(
            f'<div style="display:flex; gap:10px; padding:8px 2px; border-bottom:1px solid var(--hairline-warm);">'
            f'<span style="font-size:16px;">{icon}</span>'
            f'<div><div style="font-size:13.5px;"><b>{label}</b> '
            f'<span class="mono" style="color:var(--ink-400); font-size:12px;">{detail}</span></div>'
            f'<div class="section-caption">{actor["full_name"] if actor else "System"} · {h.fmt_datetime(e["created_at"])}</div>'
            f'</div></div>',
            unsafe_allow_html=True,
        )


def _render_remarks_history(project_id: str | None) -> None:
    if project_id:
        docs = q.list_documents(project_id)
    else:
        docs = []
        for p in q.list_projects():
            docs.extend(q.list_documents(p["id"]))

    all_remarks = []
    for d in docs:
        for r in q.list_document_remarks(d["id"]):
            r["_document"] = d
            all_remarks.append(r)
    all_remarks.sort(key=lambda r: r["created_at"], reverse=True)

    if not all_remarks:
        st.markdown(
            '<div class="empty-state"><div class="empty-icon">💬</div>'
            '<div class="empty-title">No remarks logged yet</div>'
            '<div class="empty-sub">Comments left on documents will appear here.</div></div>',
            unsafe_allow_html=True,
        )
        return

    for r in all_remarks:
        author = r.get("_author")
        doc = r["_document"]
        st.markdown(
            f'<div class="row-card">'
            f'<div class="row-title-line"><span style="font-weight:600;">{author["full_name"] if author else "—"}</span>'
            f'<span class="section-caption">on <i>{doc["file_name"]}</i></span></div>'
            f'<div style="font-size:13.5px; margin-top:3px;">{r["body"]}</div>'
            f'<div class="row-meta">{h.relative_age(r["created_at"])}</div>'
            f'</div>',
            unsafe_allow_html=True,
        )


def _render_reports_archive(project_id: str | None) -> None:
    st.caption("Generate a point-in-time export of survey activity for offline records or a flag-state audit.")

    rfis = q.list_rfis(project_id=project_id)
    csv_bytes = _rfi_summary_csv(rfis)
    label = "Project RFI Summary" if project_id else "Fleet-Wide RFI Summary"
    st.download_button(
        f"⬇ Export {label} (CSV)", data=csv_bytes,
        file_name=f"epas_rfi_summary_{project_id or 'all'}.csv",
        mime="text/csv", key=f"archive_export_{project_id}",
    )

    certs = q.list_certificates()
    if not project_id:
        cert_csv = _certificate_summary_csv(certs)
        st.download_button(
            "⬇ Export Certificate Register (CSV)", data=cert_csv,
            file_name="epas_certificate_register.csv", mime="text/csv",
            key="archive_export_certs",
        )


def _rfi_summary_csv(rfis: list[dict]) -> bytes:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["RFI Code", "Vessel", "Phase", "Survey Type", "Status", "Priority", "Requested Date"])
    for r in rfis:
        vessel = r.get("_vessel") or q.get_vessel(r["vessel_id"])
        writer.writerow([
            r["rfi_code"], vessel["name"] if vessel else "—", cfg.PHASE_LABELS.get(r["phase"], r["phase"]),
            r["survey_type"], cfg.RFI_STAGE_LABELS.get(r["status"], r["status"]),
            r["priority"], h.fmt_date(r["requested_date"]),
        ])
    return buf.getvalue().encode("utf-8")


def _certificate_summary_csv(certs: list[dict]) -> bytes:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["Certificate Number", "Vessel", "Type", "Issue Date", "Expiry Date", "Status"])
    for c in certs:
        vessel = q.get_vessel(c["vessel_id"])
        writer.writerow([
            c["cert_number"], vessel["name"] if vessel else "—", cfg.CERT_TYPE_LABELS[c["cert_type"]],
            h.fmt_date(c["issue_date"]), h.fmt_date(c["expiry_date"]), c["status"],
        ])
    return buf.getvalue().encode("utf-8")
