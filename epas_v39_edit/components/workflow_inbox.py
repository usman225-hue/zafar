"""Multi-user workflow inbox for testing real handovers in demo mode.

Production replaces the role selector with Supabase Auth. Every action below
mutates a workflow task/state record rather than using the old demo stage
advancer.
"""
from __future__ import annotations
import streamlit as st
from config import settings as cfg
from database import production_queries as q
from database import upgrade_queries as uq


def render() -> None:
    users = q.list_users()
    labels = {u["id"]: f'{u["full_name"]} · {cfg.ROLE_LABELS.get(u["role"], u["role"])}' for u in users}
    current = st.session_state.get("workflow_actor_id") or q.current_gm()["id"]
    ids = list(labels)
    if current not in ids:
        current = ids[0]
    actor_id = st.selectbox("Demo login / active workflow actor", ids, index=ids.index(current), format_func=lambda x: labels[x])
    st.session_state["workflow_actor_id"] = actor_id
    actor = q.get_user(actor_id)
    st.markdown(f'<div class="eyebrow">Multi-user inbox</div><div class="page-title">{actor["full_name"]}</div>', unsafe_allow_html=True)
    st.caption("Demo role switcher only. Production uses Supabase Auth and server-side RLS.")

    tasks = uq.list_tasks_for_user(actor_id)
    if not tasks:
        st.info("No workflow tasks assigned to this user.")
        return

    for task in tasks:
        with st.container(border=True):
            st.markdown(f'**{task["task_type"].replace("_", " ").title()}** · {task["status"].replace("_", " ").title()}')
            st.caption(task.get("note") or "")
            _task_actions(task, actor)


def _task_actions(task: dict, actor: dict) -> None:
    role = actor["role"]
    if role == cfg.ROLE_DM and task["task_type"] == "PLAN_APPRAISAL_MANAGER_HANDOVER":
        drawing = uq.get_plan_drawing(task["drawing_id"])
        if task["status"] == uq.TASK_PENDING:
            if st.button("Accept plan appraisal", key=f"accept_{task['id']}", type="primary"):
                uq.accept_task(task["id"], actor["id"]); st.rerun()
        else:
            st.success("Accepted. Select an eligible engineer below.")
            engineers = uq.eligible_engineers(drawing["discipline"])
            if not engineers:
                st.error("No engineer passes authorization + competency + availability checks.")
                return
            eid = st.selectbox("Eligible engineer", [e["id"] for e in engineers], format_func=lambda x: q.get_user(x)["full_name"], key=f"eng_{task['id']}")
            if st.button("Assign engineer", key=f"assign_eng_{task['id']}", type="primary"):
                uq.assign_engineer(drawing["id"], eid, actor["id"]); st.rerun()

    elif role == cfg.ROLE_ENGINEER and task["task_type"] == "PLAN_APPRAISAL_ENGINEER_FEEDBACK":
        drawing = uq.get_plan_drawing(task["drawing_id"])
        if task["status"] == uq.TASK_PENDING:
            if st.button("Accept DM feedback", key=f"accept_eng_feedback_{task['id']}", type="primary"):
                uq.accept_task(task["id"], actor["id"]); st.rerun()
        else:
            st.warning(f'DM feedback: {task.get("note") or "Review and correct the appraisal."}')
            note = st.text_area("Engineer response", key=f"eng_feedback_resp_{task['id']}")
            if st.button("Complete re-appraisal →", key=f"complete_feedback_{task['id']}", type="primary"):
                uq.engineer_complete_review(drawing["id"], actor["id"], True, note)
                uq.complete_task(task["id"], actor["id"])
                st.rerun()

    elif role == cfg.ROLE_ENGINEER and task["task_type"] == "PLAN_APPRAISAL_ENGINEERING":
        drawing = uq.get_plan_drawing(task["drawing_id"])
        if task["status"] == uq.TASK_PENDING:
            if st.button("Accept engineering assignment", key=f"accept_eng_{task['id']}", type="primary"):
                uq.accept_task(task["id"], actor["id"]); uq.start_engineer_review(drawing["id"], actor["id"]); st.rerun()
        else:
            st.info(f'Reviewing {drawing["drawing_no"]} Rev {drawing["revision"]}.')
            decision = st.radio("Technical review", ["Accept", "Raise Observation"], key=f"eng_dec_{task['id']}", horizontal=True)
            if decision == "Raise Observation":
                desc = st.text_area("Observation", key=f"obs_{task['id']}")
                severity = st.selectbox("Severity", cfg.OBS_SEVERITY, key=f"sev_{task['id']}")
                if st.button("Submit observation", key=f"raise_{task['id']}", type="primary"):
                    if desc.strip():
                        uq.raise_plan_observation(drawing["id"], actor["id"], desc.strip(), severity)
                        uq.complete_task(task["id"], actor["id"])
                        st.rerun()
            else:
                note = st.text_area("Review note", key=f"eng_note_{task['id']}")
                if st.button("Complete engineering review", key=f"complete_{task['id']}", type="primary"):
                    uq.engineer_complete_review(drawing["id"], actor["id"], True, note)
                    uq.complete_task(task["id"], actor["id"])
                    st.rerun()

    elif role == cfg.ROLE_DESIGNER and task["task_type"] == "PLAN_APPRAISAL_DESIGNER_RESPONSE":
        drawing = uq.get_plan_drawing(task["drawing_id"])
        if task["status"] == uq.TASK_PENDING:
            if st.button("Accept response task", key=f"accept_des_{task['id']}", type="primary"):
                uq.accept_task(task["id"], actor["id"]); st.rerun()
        else:
            response = st.text_area("Designer response / corrective action", key=f"resp_{task['id']}")
            revised_file = st.file_uploader("Upload revised drawing (PDF)", type=["pdf"], key=f"rev_file_{task['id']}")
            if st.button("Submit response & revised drawing", key=f"resp_submit_{task['id']}", type="primary"):
                if not response.strip():
                    st.error("Enter the corrective action / response.")
                elif revised_file is None:
                    st.error("Upload the revised drawing PDF to create the next controlled revision.")
                else:
                    open_obs = uq.list_plan_observations(drawing["id"], open_only=True)
                    if open_obs:
                        uq.designer_respond(drawing["id"], actor["id"], response)
                    else:
                        uq.designer_amendment_response(drawing["id"], actor["id"], response)
                    uq.resubmit_for_engineer_review(drawing["id"], actor["id"], revised_file)
                    uq.complete_task(task["id"], actor["id"])
                    st.rerun()

    elif role == cfg.ROLE_DM and task["task_type"] == "PLAN_APPRAISAL_MANAGER_REVIEW":
        drawing = uq.get_plan_drawing(task["drawing_id"])
        if task["status"] == uq.TASK_PENDING:
            if st.button("Accept manager review", key=f"mgr_review_accept_{task['id']}", type="primary"):
                uq.accept_task(task["id"], actor["id"]); st.rerun()
        else:
            note = st.text_area("Manager review note", key=f"mgr_note_{task['id']}")
            if st.button("Forward to GM", key=f"forward_gm_{task['id']}", type="primary"):
                uq.manager_forward_to_gm(drawing["id"], actor["id"], note); st.rerun()

    elif role == cfg.ROLE_DM and task["task_type"] == "SURVEY_RFI_HANDOVER":
        if task["status"] == uq.TASK_PENDING:
            if st.button("Accept RFI handover", key=f"rfi_accept_{task['id']}", type="primary"):
                uq.accept_task(task["id"], actor["id"]); st.rerun()
        else:
            st.success("RFI is now owned by this Department Manager. Surveyor execution can proceed in the Survey Operations module.")
