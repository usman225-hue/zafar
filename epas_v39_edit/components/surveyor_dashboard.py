"""Surveyor execution dashboard for the DM survey branch."""
from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from database import upgrade_queries as uq


def render() -> None:
    surveyors = q.list_users(role=cfg.ROLE_SURVEYOR)
    if not surveyors:
        st.error("No surveyor accounts are configured.")
        return
    labels = {u["id"]: u["full_name"] for u in surveyors}
    current = st.session_state.get("surveyor_actor_id", surveyors[0]["id"])
    if current not in labels:
        current = surveyors[0]["id"]
    sid = st.selectbox("Active Surveyor", list(labels), index=list(labels).index(current), format_func=lambda x: labels[x])
    st.session_state["surveyor_actor_id"] = sid
    actor = q.get_user(sid)

    st.markdown('<div class="eyebrow">Survey Operations</div><div class="page-title">Surveyor Dashboard</div>', unsafe_allow_html=True)
    st.caption("Execution stage of the DM survey workflow. Production identity comes from Supabase Auth.")

    tasks = [t for t in uq.list_tasks_for_user(sid) if t.get("rfi_id") and t.get("task_type") == "SURVEY_RFI_EXECUTION"]
    c1, c2, c3 = st.columns(3)
    c1.metric("Assigned Surveys", len(tasks))
    c2.metric("In Execution", len([t for t in tasks if t["status"] != uq.TASK_PENDING]))
    c3.metric("Specializations", len(uq.user_disciplines(sid)))

    if not tasks:
        st.success("No survey execution tasks are waiting.")
        return

    for task in tasks:
        rfi = q.get_rfi(task["rfi_id"])
        if not rfi:
            continue
        with st.container(border=True):
            st.markdown(f"**{rfi['rfi_code']}** · {rfi['survey_type']} · {rfi['priority'].title()} priority")
            st.caption(f"Vessel: {rfi['_vessel']['name'] if rfi.get('_vessel') else '—'} · Scheduled: {rfi.get('scheduled_date') or '—'}")
            if task["status"] == uq.TASK_PENDING:
                if st.button("Accept survey assignment", key=f"sv_accept_{task['id']}", type="primary"):
                    uq.accept_task(task["id"], sid)
                    st.rerun()
                continue

            st.markdown("### Controlled Plan Appraisal Drawing Package")
            package = uq.surveyor_drawing_package(rfi["id"])
            if package:
                st.caption("These drawings were approved through Plan Appraisal and explicitly shared with you by the Department Manager for this assigned survey. They are read-only controlled references.")
                for d in package:
                    with st.container(border=True):
                        c1, c2 = st.columns([4, 1])
                        c1.markdown(f"**{d.get('drawing_no','—')} · Rev {d.get('revision','—')}** — {d.get('title','—')}")
                        c1.caption(f"Discipline: {d.get('discipline','—')} · Shared: {d.get('shared_at') or d.get('granted_at') or '—'}")
                        if d.get('file_name'):
                            c1.caption(f"Controlled file: {d['file_name']}")
                        c2.markdown("**APPROVED**")
            else:
                st.warning("No approved Plan Appraisal drawings have been shared with this survey assignment. Contact the Department Manager before proceeding.")

            st.markdown("### Conduct survey & submit report")
            report = st.text_area("Survey report", key=f"sv_report_{task['id']}", placeholder="Enter survey findings, evidence summary and conclusion…")
            count = st.number_input("Number of observations", min_value=0, max_value=10, value=0, step=1, key=f"sv_count_{task['id']}")
            observations = []
            for i in range(int(count)):
                c1, c2 = st.columns([3, 1])
                with c1:
                    desc = st.text_input(f"Observation {i+1}", key=f"sv_obs_desc_{task['id']}_{i}")
                with c2:
                    sev = st.selectbox("Severity", cfg.OBS_SEVERITY, key=f"sv_obs_sev_{task['id']}_{i}")
                if desc.strip():
                    observations.append({"description": desc.strip(), "severity": sev})
            if st.button("Submit Survey Report to DM →", key=f"sv_submit_{task['id']}", type="primary"):
                if not report.strip():
                    st.error("Enter the survey report before submitting.")
                elif int(count) != len(observations):
                    st.error("Complete every observation description or set the count to zero.")
                else:
                    uq.submit_survey_report(rfi["id"], sid, report.strip(), observations)
                    uq.complete_task(task["id"], sid)
                    st.rerun()
