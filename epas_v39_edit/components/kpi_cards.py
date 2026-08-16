"""
EPAS · KPI Row
---------------
The four numbers a GM checks first each morning. "Needs Your Signature"
uses the reserved rust accent — the same colour used nowhere else in
the app — so it's unmistakable even at a glance from across the room.
"""

from __future__ import annotations

import streamlit as st

from database import production_queries as q


def render() -> dict:
    kpis = q.kpi_summary()

    cols = st.columns(4)
    tiles = [
        (cols[0], "blue", "Active Projects", kpis["active_projects"],
         f"{kpis['total_projects']} total on record"),
        (cols[1], "rust", "Needs Your Signature", kpis["needs_gm_action"],
         f"{kpis['pending_allocation']} to allocate · {kpis['pending_approval']} to approve"),
        (cols[2], "blue", "Surveys In Progress", kpis["rfis_in_progress"],
         "allocated, on-site, or under DM review"),
        (cols[3], "amber", "Certificates Expiring", kpis["certs_expiring_soon"],
         "within the next 60 days"),
    ]

    for col, tone, label, value, foot in tiles:
        with col:
            foot_class = "kpi-foot kpi-foot--rust" if tone == "rust" and value else "kpi-foot"
            st.markdown(
                f"""
                <div class="kpi-tile kpi-tile--{tone}">
                    <div class="kpi-label">{label}</div>
                    <div class="kpi-value">{value}</div>
                    <div class="{foot_class}">{foot}</div>
                </div>
                """,
                unsafe_allow_html=True,
            )
    return kpis
