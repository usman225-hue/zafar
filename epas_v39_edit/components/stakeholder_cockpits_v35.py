"""EPAS v3.5 role-native stakeholder operations surfaces.
These views are deliberately summary-first and use consolidated RPC bundles.
"""
from __future__ import annotations
import streamlit as st
from database import production_queries as pq


def _safe(fn, context: str):
    try:
        return fn()
    except Exception as exc:
        st.error(f"{context} failed. Reference EPAS-{abs(hash((context, type(exc).__name__))) % 100000:05d}.")
        return None


def _fleet_card(title: str, value, foot: str, tone: str = "neutral"):
    st.markdown(f"<div class='fleet-card fleet-card--{tone}'><div class='fleet-card__label'>{title}</div><div class='fleet-card__value'>{value}</div><div class='fleet-card__foot'>{foot}</div></div>", unsafe_allow_html=True)


def owner_fleet():
    data = _safe(pq.owner_fleet_bundle_v36, "Owner fleet dashboard") or {}
    st.markdown("### Owner Fleet Control")
    st.caption("One operational view of vessel health, surveys, certificates and released actions.")
    cols = st.columns(5)
    vals = [
        ("Fleet", data.get("total_vessels", 0), "vessels", "neutral"),
        ("Surveys due", data.get("surveys_due", 0), "upcoming window", "amber"),
        ("Overdue", data.get("surveys_overdue", 0), "requires action", "red"),
        ("Certificates expiring", data.get("certificates_expiring", 0), "next 90 days", "rust"),
        ("Open released actions", data.get("open_released_actions", 0), "stakeholder-visible", "blue"),
    ]
    for c, item in zip(cols, vals):
        with c:
            _fleet_card(*item)
    rows = _safe(pq.owner_fleet_vessels_v36, "Owner vessel list") or []
    if rows:
        st.markdown("#### Fleet Status")
        filt = st.selectbox("Fleet focus", ["All vessels", "Survey due", "Overdue", "Certificates expiring", "Open released actions"], key='owner_fleet_focus_v36')
        if filt == 'Survey due': rows = [r for r in rows if str(r.get('survey_status','')).upper() in ('IN_SERVICE_DUE','NSC_IN_PROGRESS') or str(r.get('next_survey_due',''))]
        elif filt == 'Overdue': rows = [r for r in rows if 'OVERDUE' in str(r.get('survey_status','')).upper()]
        elif filt == 'Certificates expiring': rows = [r for r in rows if r.get('certificate_expiry')]
        elif filt == 'Open released actions': rows = [r for r in rows if int(r.get('open_released_actions',0) or 0) > 0]
        st.dataframe(rows, use_container_width=True, hide_index=True)
    else:
        st.info("No authorized vessels are currently available.")


def ship_management_operations():
    data = _safe(pq.ship_management_bundle_v36, "Ship Management operations") or {}
    st.markdown("### Ship Management Operations")
    st.caption("In-Service survey readiness and corrective-action execution in one place.")
    cols = st.columns(5)
    vals = [
        ("Surveys due", data.get("surveys_due", 0), "in-service", "amber"),
        ("Overdue", data.get("surveys_overdue", 0), "requires escalation", "red"),
        ("Open corrective", data.get("open_corrective_actions", 0), "assigned to you", "rust"),
        ("Evidence pending", data.get("evidence_pending", 0), "awaiting verification", "blue"),
        ("Next survey", data.get("next_survey", "—"), "nearest due date", "neutral"),
    ]
    for c, item in zip(cols, vals):
        with c:
            _fleet_card(*item)
    actions = _safe(pq.ship_management_actions_v36, "Corrective action queue") or []
    if not actions:
        st.success("No outstanding corrective actions are assigned to you.")
        return
    st.markdown("#### Corrective Action Queue")
    for a in actions[:60]:
        with st.container(border=True):
            st.markdown(f"**{a.get('action_code','Corrective Action')}** · {a.get('status','—')}")
            c = st.columns(4)
            c[0].write(f"**Requirement**\n{a.get('requirement') or '—'}")
            c[1].write(f"**Deficiency**\n{a.get('deficiency') or '—'}")
            c[2].write(f"**Responsible party**\n{a.get('responsible_party') or '—'}")
            c[3].write(f"**Due**\n{a.get('target_date') or '—'}")
            st.write(f"**Action:** {a.get('corrective_action') or '—'}")
            st.caption(f"Evidence: {a.get('evidence_status','—')} · Verification: {a.get('verification_status','—')} · Vessel: {a.get('vessel_name','—')}")


def shipyard_nsc_operations():
    data = _safe(pq.shipyard_nsc_bundle_v36, "Shipyard NSC dashboard") or {}
    st.markdown("### Shipyard NSC Operations")
    st.caption("NSC-only request, survey, drawing release and certificate visibility. In-Service remains outside Shipyard scope.")
    cols = st.columns(5)
    vals = [
        ("NSC projects", data.get("nsc_projects", 0), "authorized", "blue"),
        ("NSC RFIs", data.get("nsc_rfis", 0), "active requests", "neutral"),
        ("Surveys due", data.get("surveys_due", 0), "NSC window", "amber"),
        ("Open released observations", data.get("open_released_observations", 0), "stakeholder-visible", "rust"),
        ("Certificates", data.get("certificates", 0), "released", "green"),
    ]
    for c, item in zip(cols, vals):
        with c:
            _fleet_card(*item)
    rows = _safe(pq.shipyard_nsc_projects_v36, "Shipyard project list") or []
    if rows:
        st.markdown('#### NSC Journey')
        st.markdown("**RFI → GM Intake → DM Assignment → Surveyor → Survey → Observation / Clearance → Certificate**")
        st.dataframe(rows, use_container_width=True, hide_index=True)
    else:
        st.info("No authorized NSC projects are currently available.")
