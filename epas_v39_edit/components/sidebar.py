"""
EPAS · Sidebar
---------------
Renders the navy "ledger spine" — brand mark, the logged-in GM's
identity card, live/demo connection status, primary navigation (with
a rust badge showing how many items need the GM's signature right
now), and a compact activity rail at the foot showing the last few
audit-log entries — a quiet nod to the ledger motif that keeps the
GM oriented without leaving the current screen.
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from config.supabase_client import connection_badge
from database import production_queries as q
from utils import helpers as h


def _nav_badge_count(page_key: str, kpis: dict) -> int:
    if page_key == "rfi_nsc":
        return len([r for r in q.gm_actionable_rfis() if r["phase"] == cfg.PHASE_NSC_SURVEY])
    if page_key == "rfi_in_service":
        return len([r for r in q.gm_actionable_rfis() if r["phase"] == cfg.PHASE_IN_SERVICE])
    if page_key == "certificates":
        return kpis["certs_expiring_soon"]
    if page_key == "overview":
        return kpis["needs_gm_action"]
    return 0


def render() -> None:
    gm = q.current_gm()
    current_page = st.session_state.get("page", "overview")
    if current_page == "dm_dashboard":
        actor_id = st.session_state.get("dm_actor_id")
        actor = q.get_user(actor_id) if actor_id else None
        if actor:
            gm = actor
    elif current_page == "surveyor_dashboard":
        actor_id = st.session_state.get("surveyor_actor_id")
        actor = q.get_user(actor_id) if actor_id else None
        if actor:
            gm = actor
    kpis = q.kpi_summary()
    conn_label, conn_class = connection_badge()

    with st.sidebar:
        st.markdown(
            f"""
            <div class="brand-row">
                <img src="assets/psb_logo_master.png" class="brand-image" alt="Pakistan Shipping Bureau logo">
                <div>
                    <div class="brand-name">PAKISTAN SHIPPING BUREAU</div>
                    <div class="brand-tagline">Classification · Survey · Maritime Safety</div>
                </div>
            </div>
            <span class="{conn_class}">{conn_label}</span>
            <div class="gm-card">
                <div class="gm-avatar">{h.initials(gm['full_name'])}</div>
                <div>
                    <div class="gm-name">{gm['full_name']}</div>
                    <div class="gm-role">{cfg.ROLE_LABELS[gm['role']]}</div>
                </div>
            </div>
            """,
            unsafe_allow_html=True,
        )

        st.markdown('<div class="nav-section-label">Workspace</div>', unsafe_allow_html=True)

        for key, label, icon in cfg.NAV_ITEMS:
            badge_count = _nav_badge_count(key, kpis)
            if key == current_page:
                badge_html = f'<span class="nav-badge">{badge_count}</span>' if badge_count else ""
                st.markdown(
                    f'<div class="nav-item-active"><span class="nav-icon">{icon}</span>'
                    f"<span>{label}</span>{badge_html}</div>",
                    unsafe_allow_html=True,
                )
            else:
                label_with_count = f"{icon}  {label}" + (f"   ·  {badge_count}" if badge_count else "")
                if st.button(label_with_count, key=f"nav_{key}", use_container_width=True):
                    st.session_state["page"] = key
                    if key == "projects":
                        st.session_state.pop("selected_project_id", None)
                    st.rerun()

        st.markdown('<div class="nav-section-label">Recent Activity</div>', unsafe_allow_html=True)
        _render_ledger_rail()

        st.markdown(
            f'<div style="margin-top:20px; font-size:10.5px; color:#5C6C87;">'
            f"{cfg.APP_NAME} v{cfg.APP_VERSION} · {cfg.ORG_NAME}</div>",
            unsafe_allow_html=True,
        )


_DOT_COLOR_BY_ACTION = {
    "PROJECT_CREATED": "#2B63B3",
    "RFI_RECEIVED": "#8891A0",
    "RFI_ASSIGNED": "#2B63B3",
    "RFI_APPROVED": "#1E6E4C",
    "RFI_SENT_BACK": "#B23A2E",
    "RFI_RESUBMITTED": "#B9791E",
    "CERTIFICATE_ISSUED": "#1E6E4C",
    "DEMO_STAGE_ADVANCED": "#8891A0",
}

_LABEL_BY_ACTION = {
    "PROJECT_CREATED": "created project",
    "RFI_RECEIVED": "received",
    "RFI_ASSIGNED": "assigned",
    "RFI_APPROVED": "approved",
    "RFI_SENT_BACK": "sent back",
    "RFI_RESUBMITTED": "resubmitted",
    "CERTIFICATE_ISSUED": "issued certificate",
    "DEMO_STAGE_ADVANCED": "stage advanced",
}


def _render_ledger_rail(limit: int = 6) -> None:
    entries = q.audit_trail()[:limit]
    if not entries:
        st.markdown(
            '<div style="font-size:11.5px; color:#6F7F9C; padding:4px 2px;">No activity yet.</div>',
            unsafe_allow_html=True,
        )
        return

    rows = []
    for e in entries:
        dot = _DOT_COLOR_BY_ACTION.get(e["action"], "#8891A0")
        verb = _LABEL_BY_ACTION.get(e["action"], e["action"].replace("_", " ").lower())
        detail = e["details"].get("rfi_code") or e["details"].get("cert_number") or e["details"].get("project_code") or ""
        rows.append(
            f'<div class="ledger-item"><span class="ledger-dot" style="background:{dot};"></span>'
            f'<div><div class="ledger-text">GM {verb} <b>{detail}</b></div>'
            f'<div class="ledger-time">{h.relative_age(e["created_at"])}</div></div></div>'
        )
    st.markdown(f'<div class="ledger-rail">{"".join(rows)}</div>', unsafe_allow_html=True)
