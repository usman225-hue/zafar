"""EPAS Department Manager Dashboard / Inbox.

Implements the DM branch of the controlled workflow supplied by the project:

DM Inbox -> new work item -> Plan Appraisal OR Survey RFI.
Plan appraisal: receive drawing -> review version -> eligibility -> engineer ->
engineering appraisal -> DM review -> changes / amended design / approved ->
feedback/revision/GM.
Survey RFI: review scope -> surveyor eligibility -> assign -> survey execution ->
DM report/observation review -> GM, with a corrective-action loop.
"""
from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from database import upgrade_queries as uq


def render() -> None:
    dms = q.list_users(role=cfg.ROLE_DM)
    if not dms:
        st.error("No Department Manager accounts are configured.")
        return

    labels = {u["id"]: u["full_name"] for u in dms}
    current = st.session_state.get("dm_actor_id", dms[0]["id"])
    if current not in labels:
        current = dms[0]["id"]
    actor_id = st.selectbox(
        "Active Department Manager",
        list(labels),
        index=list(labels).index(current),
        format_func=lambda x: labels[x],
    )
    st.session_state["dm_actor_id"] = actor_id
    actor = q.get_user(actor_id)

    st.markdown('<div class="eyebrow">Department Operations</div><div class="page-title">DM Dashboard / Inbox</div>', unsafe_allow_html=True)
    st.caption("Real role-to-role handover view. In production the active user comes from Supabase Auth + RLS.")

    tasks = uq.list_tasks_for_user(actor_id)
    pa_tasks = [t for t in tasks if t.get("drawing_id")]
    survey_tasks = [t for t in tasks if t.get("rfi_id")]
    _metrics(tasks, pa_tasks, survey_tasks)

    tab1, tab2, tab3 = st.tabs(["📥 Inbox", "📐 Plan Appraisal", "⚓ Survey RFIs"])
    with tab1:
        if not tasks:
            st.success("Inbox is clear. No active workflow tasks are assigned to you.")
        else:
            for task in tasks:
                _render_task(task, actor)
    with tab2:
        pa = [t for t in tasks if t.get("drawing_id")]
        if not pa:
            st.info("No active Plan Appraisal tasks.")
        for task in pa:
            _render_plan_task(task, actor)
    with tab3:
        sv = [t for t in tasks if t.get("rfi_id")]
        if not sv:
            st.info("No active Survey RFI tasks.")
        for task in sv:
            _render_survey_task(task, actor)

    st.markdown('<div class="section-title" style="margin-top:24px;">Project monitoring</div>', unsafe_allow_html=True)
    _monitoring(actor_id)


def _metrics(tasks: list[dict], pa_tasks: list[dict], survey_tasks: list[dict]) -> None:
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Inbox", len(tasks))
    c2.metric("Plan Appraisal", len(pa_tasks))
    c3.metric("Survey RFIs", len(survey_tasks))
    delayed = 0
    for t in tasks:
        if t.get("rfi_id"):
            rfi = q.get_rfi(t["rfi_id"])
            if rfi and rfi.get("priority") == "high":
                delayed += 1
    c4.metric("High Priority", delayed)


def _render_task(task: dict, actor: dict) -> None:
    kind = task["task_type"].replace("_", " ").title()
    with st.container(border=True):
        st.markdown(f"**{kind}**  ·  `{task['status']}`")
        st.caption(task.get("note") or "Workflow action required")
        if task.get("drawing_id"):
            d = uq.get_plan_drawing(task["drawing_id"])
            if d:
                st.write(f"Drawing: **{d['drawing_no']} — {d['title']}** · Rev {d['revision']} · {uq.PA_STATUS_LABELS.get(d['status'], d['status'])}")
                st.info("Open the **Plan Appraisal** tab to process this task.")
        elif task.get("rfi_id"):
            rfi = q.get_rfi(task["rfi_id"])
            if rfi:
                st.write(f"RFI: **{rfi['rfi_code']}** · {rfi['survey_type']} · {cfg.RFI_STAGE_LABELS.get(rfi['status'], rfi['status'])}")
                st.info("Open the **Survey RFIs** tab to process this task.")


def _accept_if_pending(task: dict, actor: dict, label: str) -> bool:
    if task["status"] != uq.TASK_PENDING:
        return True
    if st.button(label, key=f"accept_dm_{task['id']}", type="primary"):
        try:
            uq.accept_task(task["id"], actor["id"])
            st.rerun()
        except ValueError as exc:
            st.error(str(exc))
    return False


def _render_plan_task(task: dict, actor: dict) -> None:
    d = uq.get_plan_drawing(task.get("drawing_id"))
    if not d:
        st.warning("Drawing record is no longer available.")
        return
    st.markdown(f"**{d['drawing_no']} — {d['title']}** · Rev {d['revision']} · {d['discipline']}")
    st.caption(f"Workflow status: {uq.PA_STATUS_LABELS.get(d['status'], d['status'])}")

    if task["task_type"] == "PLAN_APPRAISAL_MANAGER_HANDOVER":
        if not _accept_if_pending(task, actor, "Accept drawing / receive version"):
            return
        st.info("Review the current drawing version and confirm the next resource allocation step.")
        if st.button("Continue to engineer availability check →", key=f"pa_start_{task['id']}", type="primary"):
            uq.manager_start_review(d["id"], actor["id"])
            st.rerun()
        if task["status"] != uq.TASK_PENDING:
            _engineer_assignment(d, actor, task)
        return

    if task["task_type"] == "PLAN_APPRAISAL_ENGINEER_FEEDBACK":
        if not _accept_if_pending(task, actor, "Accept engineer feedback task"):
            return
        feedback = st.text_area("DM feedback to engineer", key=f"eng_feedback_{task['id']}")
        if st.button("Send back to Engineer →", key=f"send_eng_{task['id']}", type="primary"):
            if not feedback.strip():
                st.error("Enter feedback before returning the appraisal.")
            else:
                uq.manager_return_to_engineer(d["id"], actor["id"], feedback)
                st.rerun()
        return

    if task["task_type"] == "PLAN_APPRAISAL_MANAGER_REVIEW":
        if not _accept_if_pending(task, actor, "Accept manager appraisal review"):
            return
        st.markdown("### DM reviews appraisal")
        obs = uq.list_plan_observations(d["id"], open_only=True)
        if obs:
            st.warning(f"{len(obs)} open observation(s) remain from the engineer.")
            for o in obs:
                st.markdown(f"- **{o['obs_code']}** · {o['severity']}: {o['description']}")
        decision = st.radio(
            "DM decision",
            ["Appraisal Approved", "Appraisal Requires Changes", "Design Rejected / Amended"],
            key=f"dm_pa_decision_{task['id']}",
        )
        note = st.text_area("DM review / feedback", key=f"dm_pa_note_{task['id']}")
        if st.button("Apply DM decision →", key=f"dm_pa_apply_{task['id']}", type="primary"):
            if not note.strip():
                st.error("Enter a review note or feedback.")
            else:
                uq.manager_review_decision(d["id"], actor["id"], decision, note)
                uq.complete_task(task["id"], actor["id"])
                st.rerun()
        return

    if task["task_type"] == "PLAN_APPRAISAL_GM_DESIGNER_CORRECTION":
        if not _accept_if_pending(task, actor, "Accept GM correction request"):
            return
        st.info("GM must send the drawing to the Designer for correction. This task is a control-point notification.")
        return

    if task["task_type"] == "PLAN_APPRAISAL_DESIGNER_RESPONSE":
        # Normally handled in Workflow Inbox / Designer portal; visible here for tracking.
        st.info("Waiting for Designer response / revised drawing.")
        return


def _engineer_assignment(d: dict, actor: dict, task: dict) -> None:
    engineers = uq.eligible_engineers(d["discipline"])
    if not engineers:
        st.error("No engineer passes authorization + competency + availability checks.")
        return
    ids = [u["id"] for u in engineers]
    eid = st.selectbox(
        "Authorized + competent + available engineer",
        ids,
        format_func=lambda x: q.get_user(x)["full_name"],
        key=f"dm_engineer_{d['id']}",
    )
    check = uq.engineer_eligibility(eid, d["discipline"])
    st.caption(" · ".join(check["reasons"]))
    if st.button("Assign to specific Authorized Engineer →", key=f"dm_assign_eng_{d['id']}", type="primary"):
        uq.assign_engineer(d["id"], eid, actor["id"])
        st.rerun()


def _render_survey_task(task: dict, actor: dict) -> None:
    rfi = q.get_rfi(task.get("rfi_id"))
    if not rfi:
        st.warning("RFI record is no longer available.")
        return
    st.markdown(f"**{rfi['rfi_code']}** · {rfi['survey_type']} · {rfi['priority'].title()} priority")
    st.caption(f"Vessel: {rfi['_vessel']['name'] if rfi.get('_vessel') else '—'} · Status: {cfg.RFI_STAGE_LABELS.get(rfi['status'], rfi['status'])}")

    if task["task_type"] == "SURVEY_RFI_HANDOVER":
        if not _accept_if_pending(task, actor, "Accept Survey RFI handover"):
            return
        st.markdown("### Review RFI scope & survey type")
        discipline = uq.survey_discipline_for_rfi(rfi)
        st.info(f"Recommended specialization: **{discipline}**")
        surveyors = uq.eligible_surveyors(discipline)
        if not surveyors:
            st.error("No surveyor passes authorization + competency + availability checks for this specialization.")
            return
        sid = st.selectbox("Authorized surveyor", [u["id"] for u in surveyors], format_func=lambda x: q.get_user(x)["full_name"], key=f"dm_surveyor_{rfi['id']}")
        check = uq.surveyor_eligibility(sid, discipline)
        st.caption(" · ".join(check["reasons"]))
        scheduled = st.date_input("Schedule survey", key=f"schedule_{rfi['id']}")

        approved_drawings = uq.list_approved_plan_drawings(rfi["project_id"])
        if approved_drawings:
            st.markdown("### Approved Plan Appraisal drawings to share with Surveyor")
            st.caption("Only Plan Appraisal-approved drawings can be handed over. Select the drawings relevant to this NSC or In-Service survey; they will appear in the Surveyor's controlled survey package after assignment.")
            drawing_options = [d["id"] for d in approved_drawings]
            selected_drawings = st.multiselect(
                "Relevant approved drawings", drawing_options,
                default=[],
                format_func=lambda did: next((f"{d.get('drawing_no','—')} · Rev {d.get('revision','—')} · {d.get('title','')} · {d.get('discipline','')}" for d in approved_drawings if d["id"] == did), did),
                key=f"survey_drawings_{rfi['id']}",
            )
            st.session_state[f"survey_drawings_{rfi['id']}"] = selected_drawings
        else:
            st.info("No Plan Appraisal-approved drawings are available for handover yet. Survey assignment will remain blocked until the approved drawing package is available.")
            st.session_state[f"survey_drawings_{rfi['id']}"] = []

        if st.button("Assign Surveyor + Share Approved Drawing Package →", key=f"dm_assign_surveyor_{rfi['id']}", type="primary"):
            if approved_drawings and not st.session_state.get(f"survey_drawings_{rfi['id']}"):
                st.error("Select at least one approved drawing relevant to this survey.")
            else:
                uq.assign_surveyor(rfi["id"], sid, actor["id"], discipline, scheduled)
                st.rerun()
        return

    if task["task_type"] == "SURVEY_CORRECTIVE_ACTION":
        if not _accept_if_pending(task, actor, "Accept corrective-action instruction"):
            return
        st.info("Coordinate corrective action with the Surveyor / Ship Management and create a follow-up RFI.")
        note = st.text_area("Corrective-action instruction", key=f"corr_{rfi['id']}")
        if st.button("Create Follow-up RFI →", key=f"followup_{rfi['id']}", type="primary"):
            if not note.strip():
                st.error("Enter the corrective-action instruction.")
            else:
                uq.create_followup_rfi(rfi["id"], actor["id"], note)
                uq.complete_task(task["id"], actor["id"])
                st.rerun()
        return

    if task["task_type"] == "SURVEY_RFI_EXECUTION":
        st.info("Surveyor is currently executing the survey. The task is visible for DM monitoring.")
        return

    if task["task_type"] == "SURVEY_DM_REVIEW":
        if not _accept_if_pending(task, actor, "Accept survey report for DM review"):
            return
        report = uq.get_survey_report(rfi["id"])
        if report:
            st.markdown(f"**Survey report:** {report.get('report_note', 'Submitted survey report')}")
        obs = q.list_observations(rfi["id"])
        open_obs = [o for o in obs if o["status"] == cfg.OBS_OPEN]
        if open_obs:
            st.warning(f"Observations exist: {len(open_obs)} open")
            for o in open_obs:
                st.markdown(f"- **{o['obs_code']}** · {o['severity']}: {o['description']}")
            remarks = st.text_area("DM observation remarks", key=f"dm_obs_remarks_{rfi['id']}")
            if st.button("Review observations & forward to GM →", key=f"dm_forward_obs_{rfi['id']}", type="primary"):
                uq.dm_review_and_forward_survey(rfi["id"], actor["id"], remarks)
                uq.complete_task(task["id"], actor["id"])
                st.rerun()
        else:
            remarks = st.text_area("DM review remarks", key=f"dm_clean_remarks_{rfi['id']}")
            if st.button("No observations — forward to GM for final approval & certificate →", key=f"dm_forward_clean_{rfi['id']}", type="primary"):
                uq.dm_review_and_forward_survey(rfi["id"], actor["id"], remarks)
                uq.complete_task(task["id"], actor["id"])
                st.rerun()
        return


def _monitoring(actor_id: str) -> None:
    rfis = [r for r in q.list_rfis() if r.get("assigned_dm_id") == actor_id and r.get("status") not in (cfg.RFI_CERT_ISSUED, cfg.RFI_CLOSED)]
    if not rfis:
        st.info("No active survey workload assigned to this DM.")
        return
    for rfi in rfis:
        priority = rfi.get("priority", "medium")
        label = f"{rfi['rfi_code']} · {rfi['survey_type']} · {priority.title()}"
        with st.expander(label, expanded=False):
            st.write(f"Status: **{cfg.RFI_STAGE_LABELS.get(rfi['status'], rfi['status'])}**")
            st.write(f"Surveyor: **{rfi['_surveyor']['full_name'] if rfi.get('_surveyor') else 'Unassigned'}**")
            st.write(f"Scheduled: **{rfi.get('scheduled_date') or 'Not scheduled'}**")
