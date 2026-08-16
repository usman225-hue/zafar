"""EPAS v1.4 GM Classification Control Center.

The GM workspace is a real authenticated command center: project health,
plan appraisal decisions, survey approvals, escalation decisions, governance
registers, notifications and audit history. All mutations use trusted RPCs.
"""
from __future__ import annotations
from datetime import date, timedelta
import streamlit as st

from database import production_queries as pq
from components.production_certificate import upload_certificate_pdf
from components import governance_v15


def _safe(fn):
    try:
        return fn()
    except Exception as exc:
        st.error(str(exc))
        return None


def _project_label(p):
    return f"{p['project_code']} · {p['name']}"


def render() -> None:
    user = pq.profile()
    st.markdown("<div class='eyebrow'>EPAS · GM Classification</div><div class='page-title'>Classification Control Center</div>", unsafe_allow_html=True)
    st.caption(f"Authenticated as {user['full_name']} · {user['email']} · GM Classification")

    # v3.5 Point 15: decision-first GM control strip.
    summary = pq.role_dashboard_summary_v36() or {}
    st.markdown("### Needs My Decision")
    dcols = st.columns(4)
    dcols[0].metric("Plan approvals", summary.get("plan_pending_gm", 0))
    dcols[1].metric("Survey decisions", summary.get("pending_decisions", 0))
    dcols[2].metric("Overdue", summary.get("overdue_tasks", 0))
    dcols[3].metric("Open escalations", summary.get("open_escalations", 0))
    st.caption("Prioritize approvals, survey decisions, escalations and certificate gates before routine monitoring.")
    focus = st.selectbox('Decision focus', ['All decisions','Plan approvals','Survey decisions','Overdue work','Escalations'], key='gm_decision_focus_v36')
    if focus != 'All decisions':
        st.info(f'Focus queue selected: {focus}. Use the corresponding operational surface below to act on these items.')

    m = pq.metrics()
    tasks = pq.tasks(statuses=['pending','accepted','in_progress'])
    c1,c2,c3,c4,c5 = st.columns(5)
    c1.metric("Active Projects", m['active_projects'])
    c2.metric("My Workflow Inbox", len(tasks))
    c3.metric("Plan Decisions", m['plan_pending_gm'])
    c4.metric("Survey Decisions", m['pending_gm_rfi'])
    c5.metric("Open Escalations", m['open_escalations'])

    sections = ["Command Center", "Projects & Health", "Plan Appraisal", "Survey RFIs", "Escalations", "Governance", "Notifications", "Governance & Closure"]
    section = st.radio("GM WORKSPACE", sections, horizontal=True, key="gm_workspace_v36")
    if section == "Command Center": _command_center()
    elif section == "Projects & Health": _projects_health()
    elif section == "Plan Appraisal": _plan_appraisal()
    elif section == "Survey RFIs": _survey_rfis()
    elif section == "Escalations": _escalations()
    elif section == "Governance": _governance()
    elif section == "Notifications": _notifications()
    elif section == "Governance & Closure": governance_v15.render_gm()



def render_create_project() -> None:
    """GM-only project creation surface. The active UI exposes this only from the Projects register."""
    _create_project()


def _create_project():
    st.markdown("### Project Creation & Activation")
    st.caption("The GM creates the project once. PostgreSQL atomically activates it, creates the vessel/team/stakeholder records, milestones and workflow notifications.")
    with st.form("gm_create_project_v14"):
        c1,c2,c3=st.columns(3)
        name=c1.text_input("Project / Vessel name *", key="gm_project_name")
        vessel_type=c2.text_input("Vessel type *", key="gm_vessel_type")
        flag=c3.text_input("Flag state *", key="gm_flag_state")
        c1,c2,c3=st.columns(3)
        project_code=c1.text_input("Project code (optional)", key="gm_project_code")
        classification_no=c2.text_input("Classification number", key="gm_classification_number")
        register_no=c3.text_input("Register number", key="gm_register_number")
        c1,c2,c3=st.columns(3)
        contract_no=c1.text_input("Contract number", key="gm_contract_number")
        request=c2.text_input("Classification request", key="gm_classification_request")
        scope=c3.text_input("Classification scope", key="gm_classification_scope")
        c1,c2,c3=st.columns(3)
        start=c1.date_input("Project start", value=date.today(), key="gm_project_start")
        completion=c2.date_input("Target completion", value=date.today()+timedelta(days=180), key="gm_project_completion")
        build_stage=c3.selectbox("Build stage", ["New Building","In-Service","Change of Class","Class Renewal"], key="gm_build_stage")
        phases=st.multiselect("Workflow phases", ["plan_appraisal","nsc_survey","in_service"], default=["plan_appraisal","nsc_survey"], key="gm_workflow_phases")
        rules=st.text_input("Applicable rules (semicolon separated)", key="gm_applicable_rules")
        remarks=st.text_area("GM project remarks", key="gm_project_remarks")

        st.markdown("**Vessel particulars**")
        v1,v2,v3,v4=st.columns(4)
        imo=v1.text_input("IMO number", key="gm_imo_number")
        loa=v2.number_input("LOA (m)", min_value=0.0, value=0.0, key="gm_loa")
        beam=v3.number_input("Beam (m)", min_value=0.0, value=0.0, key="gm_beam")
        draft=v4.number_input("Draft (m)", min_value=0.0, value=0.0, key="gm_draft")
        v1,v2,v3,v4=st.columns(4)
        power=v1.number_input("Power (kW)", min_value=0.0, value=0.0, key="gm_power_kw")
        speed=v2.number_input("Speed (kn)", min_value=0.0, value=0.0, key="gm_speed_kn")
        build_year=v3.number_input("Build year", min_value=1900, max_value=2100, value=date.today().year, key="gm_build_year")
        owner=v4.text_input("Owner company", key="gm_owner_company_text")

        st.markdown("**Project team**")
        dms=pq.users('dm') or []
        all_dm_ids=[u['id'] for u in dms]
        selected_dms=st.multiselect("Department managers", options=all_dm_ids, default=[], format_func=lambda x: next(u['full_name'] for u in dms if u['id']==x), key='gm_project_dms')
        dm_department_map={}
        for dm_id in selected_dms:
            dm_name=next(u['full_name'] for u in dms if u['id']==dm_id)
            dm_department_map[dm_id]=st.text_input(f"Department for {dm_name}", value=dm_department_map.get(dm_id,''), key=f'gm_dm_department_{dm_id}')

        engineers=pq.users('engineer') or []
        selected_engineers=st.multiselect("Plan appraisal engineers", options=[u['id'] for u in engineers], format_func=lambda x: next(u['full_name'] for u in engineers if u['id']==x), key='gm_project_engineers')
        engineer_phase_map={}
        for eid in selected_engineers:
            eng_name=next(u['full_name'] for u in engineers if u['id']==eid)
            engineer_phase_map[eid]=st.selectbox(f"Primary phase for {eng_name}", ["plan_appraisal","nsc_survey","in_service"], index=0, key=f'gm_engineer_phase_{eid}')

        surveyors=pq.users('surveyor') or []
        selected_surveyors=st.multiselect("Surveyors", options=[u['id'] for u in surveyors], format_func=lambda x: next(u['full_name'] for u in surveyors if u['id']==x), key='gm_project_surveyors')
        surveyor_phase_map={}
        for sid in selected_surveyors:
            surv_name=next(u['full_name'] for u in surveyors if u['id']==sid)
            surveyor_phase_map[sid]=st.selectbox(f"Primary phase for {surv_name}", ["nsc_survey","in_service"], index=0, key=f'gm_surveyor_phase_{sid}')

        st.markdown("**Stakeholders / linked contacts**")
        owner_company=st.text_input("Owner company", value=owner, key="gm_owner_company")
        designer_company=st.text_input("Designer company", key="gm_designer_company")
        shipyard_company=st.text_input("Shipyard company", key="gm_shipyard_company")
        shipmgmt_company=st.text_input("Ship Management company", key="gm_shipmgmt_company")

        designers=pq.users('designer') or []
        designer_user=st.selectbox("Linked Designer account", ['none'] + [u['id'] for u in designers], format_func=lambda x: 'Not linked' if x=='none' else next(u['full_name'] for u in designers if u['id']==x), index=0 if not designers else 1 if 'none' in ['none'] else 0, key='gm_linked_designer_account') if designers else 'none'
        shipm_users=pq.users('ship_management') or []
        shipm_user=st.selectbox("Linked Ship Management account", ['none'] + [u['id'] for u in shipm_users], format_func=lambda x: 'Not linked' if x=='none' else next(u['full_name'] for u in shipm_users if u['id']==x), index=0 if not shipm_users else 1 if 'none' in ['none'] else 0, key='gm_linked_ship_management_account') if shipm_users else 'none'
        owner_user=st.selectbox("Linked Owner account", ['none'] + [u['id'] for u in pq.users('owner') or []], format_func=lambda x: 'Not linked' if x=='none' else next(u['full_name'] for u in pq.users('owner') or [] if u['id']==x), index=0, key='gm_linked_owner_account') if (pq.users('owner') or []) else 'none'
        shipyard_user=st.selectbox("Linked Shipyard account", ['none'] + [u['id'] for u in pq.users('shipyard') or []], format_func=lambda x: 'Not linked' if x=='none' else next(u['full_name'] for u in pq.users('shipyard') or [] if u['id']==x), index=0, key='gm_linked_shipyard_account') if (pq.users('shipyard') or []) else 'none'

        contract_file=st.file_uploader("Contract / agreement",type=['pdf'],key='gm_v14_contract')
        rules_file=st.file_uploader("Applicable class rules",type=['pdf'],key='gm_v14_rules')
        timeline_file=st.file_uploader("Approved project timeline",type=['pdf','xlsx','csv'],key='gm_v14_timeline')
        submit=st.form_submit_button("Create & Activate Project →",type='primary',use_container_width=True)
    if submit:
        if not name.strip() or not vessel_type.strip() or not flag.strip() or not phases:
            st.error("Project/Vessel name, vessel type, flag and at least one workflow phase are required.")
            return
        team=[]
        for dm_id in selected_dms:
            team.append({'user_id':dm_id,'role':'dm','discipline':'','department':dm_department_map.get(dm_id, '').strip() or 'General Management'})
        for eid in selected_engineers:
            team.append({'user_id':eid,'role':'engineer','discipline':None,'phase':engineer_phase_map.get(eid, 'plan_appraisal')})
        for sid in selected_surveyors:
            team.append({'user_id':sid,'role':'surveyor','discipline':None,'phase':surveyor_phase_map.get(sid, 'nsc_survey')})

        stakeholders=[]
        for company,typ,linked in [(owner_company,'owner',owner_user),(designer_company,'designer',designer_user),(shipyard_company,'shipyard',shipyard_user),(shipmgmt_company,'ship_management',shipm_user)]:
            if company.strip():
                stakeholders.append({'company_name':company.strip(),'stakeholder_type':typ,'contact_name':'','contact_email':'','user_id':None if linked=='none' else linked})
        payload={'project_code':project_code or None,'name':name.strip(),'vessel_type':vessel_type.strip(),'flag_state':flag.strip(),'phases':phases,'classification_number':classification_no,'register_number':register_no,'contract_number':contract_no,'classification_request':request,'classification_scope':scope,'applicable_rules':[x.strip() for x in rules.split(';') if x.strip()],'start_date':start.isoformat(),'target_completion_date':completion.isoformat(),'survey_type':'','build_stage':build_stage,'remarks':remarks,'vessel':{'name':name.strip(),'imo_number':imo,'loa_m':loa or None,'beam_m':beam or None,'draft_m':draft or None,'power_kw':power or None,'speed_knots':speed or None,'build_year':build_year,'owner_company':owner_company or owner},'team':team,'stakeholders':stakeholders}
        result=_safe(lambda:pq.create_project(payload))
        if result:
            pid=result['project']['id']; errors=[]
            st.session_state['selected_project_id'] = pid
            st.session_state['project_nav_key'] = 'overview'
            for category,f in [('contract',contract_file),('class_rules',rules_file),('timeline',timeline_file)]:
                if f:
                    try: pq.register_project_document(pid,category,f)
                    except Exception as exc: errors.append(f"{category}: {exc}")
            if errors: st.warning('Project activated, but document registration failed: '+ ' | '.join(errors))
            else: st.success(f"Project {result['project']['project_code']} created and activated.")
            st.rerun()

def _command_center():
    projects = pq.projects('active')
    st.markdown("### Needs Your Attention")
    tasks = pq.tasks(statuses=['pending','accepted','in_progress'])
    plan = [t for t in tasks if t.get('task_type') in ('GM_PLAN_FINAL_APPROVAL','PLAN_APPRAISAL_GM_DESIGN_DECISION')]
    survey = [t for t in tasks if t.get('task_type') == 'GM_SURVEY_FINAL_APPROVAL']
    esc = [t for t in tasks if t.get('task_type') == 'GM_ESCALATION_REVIEW']
    c1,c2,c3 = st.columns(3)
    c1.metric("Plan Appraisal", len(plan)); c2.metric("Survey RFI", len(survey)); c3.metric("Escalations", len(esc))

    if not projects:
        st.info("No active projects are currently visible to GM Classification.")
        return
    health_map = pq.dashboard_project_health_bundle([p['id'] for p in projects])
    for p in projects:
        h = health_map.get(p['id'])
        if not h: continue
        with st.container(border=True):
            c1,c2,c3,c4 = st.columns([2.5,1,1,1])
            c1.markdown(f"**{_project_label(p)}**")
            c2.metric("Completion", f"{h['completion_pct']}%")
            c3.metric("Overdue", h['overdue_tasks'])
            c4.metric("Health", str(h['health_status']).title())
            if h['health_status'] == 'attention': st.error("Management attention required: overdue work, open escalation or open risk.")
            elif h['health_status'] == 'watch': st.warning("Watch: open technical observations or delayed milestones are present.")
            else: st.success("Healthy execution status.")


def _projects_health():
    projects = pq.projects('active')
    if not projects:
        st.info("No active projects."); return
    labels = {p['id']:_project_label(p) for p in projects}
    selected = st.selectbox("Project workspace", list(labels), format_func=lambda x: labels[x], key="gm_project_workspace")
    p = pq.project(selected)
    h = pq.project_health(selected)
    if not p or not h: return

    st.markdown(f"### {labels[selected]}")
    c = st.columns(6)
    c[0].metric("Completion", f"{h['completion_pct']}%")
    c[1].metric("Milestones", f"{h['completed_milestones']}/{h['total_milestones']}")
    c[2].metric("Drawings", f"{h['approved_drawings']}/{h['plan_drawings']}")
    c[3].metric("RFIs", f"{h['rfis_approved']}/{h['rfis']}")
    c[4].metric("Overdue Tasks", h['overdue_tasks'])
    c[5].metric("Open Risks", h['open_risks'])

    st.markdown("#### Project Control Package")
    project_section = st.radio("PROJECT CONTROL", ["Project Information","Team","Milestones","Risks & Decisions","Audit Trail"], horizontal=True, key=f"gm_project_control_v36_{selected}")
    if project_section == "Project Information":
        vessel = pq.vessel(selected)
        if vessel:
            a,b = st.columns(2)
            with a:
                st.write(f"**Classification No.:** {p.get('classification_number') or '—'}")
                st.write(f"**Register No.:** {p.get('register_number') or '—'}")
                st.write(f"**Contract No.:** {p.get('contract_number') or '—'}")
                st.write(f"**Classification Scope:** {p.get('classification_scope') or '—'}")
            with b:
                st.write(f"**IMO:** {vessel.get('imo_number') or '—'}")
                st.write(f"**LOA:** {vessel.get('loa_m') or '—'} m")
                st.write(f"**Beam:** {vessel.get('beam_m') or '—'} m")
                st.write(f"**Draft:** {vessel.get('draft_m') or '—'} m")
    if project_section == "Team":
        for m in pq.members(selected):
            prof = m.get('profiles') or {}
            st.write(f"**{prof.get('full_name','—')}** · {m.get('role')} · {m.get('discipline') or '—'}")
        for s in pq.stakeholders(selected):
            st.caption(f"{s.get('stakeholder_type')}: {s.get('company_name')} · {s.get('contact_email') or 'no linked account'}")
    if project_section == "Milestones":
        for m in pq.milestones(selected):
            status = m.get('status','pending')
            st.write(f"**{m.get('code')} — {m.get('title')}** · {status} · due {m.get('due_date') or '—'}")
    if project_section == "Risks & Decisions":
        _risk_decision_register(selected)
    if project_section == "Audit Trail":
        rows = pq.audit_events(selected, 100)
        for a in rows:
            st.caption(f"{a.get('created_at')} · {a.get('action')} · {a.get('entity_type')} · {a.get('from_status') or '—'} → {a.get('to_status') or '—'} · {a.get('reason') or ''}")


def _risk_decision_register(project_id: str):
    risks = pq.risks(project_id, open_only=False)
    decisions = pq.decisions(project_id)
    st.markdown("**Risk Register**")
    for r in risks:
        st.write(f"**{r['risk_code']} · {r['title']}** · {r['severity'].upper()} · {r['status']} — {r['mitigation'] or 'No mitigation recorded'}")
    if not risks: st.caption("No risks registered.")
    st.markdown("**Decision Register**")
    for d in decisions:
        st.write(f"**{d['decision_code']} · {d['subject']}** — {d['decision']} · {d.get('reason') or ''}")
    if not decisions: st.caption("No management decisions recorded yet.")

    with st.expander("+ Add management risk", expanded=False):
        title = st.text_input("Risk title", key=f"risk_title_{project_id}")
        desc = st.text_area("Description", key=f"risk_desc_{project_id}")
        c1,c2,c3 = st.columns(3)
        probability = c1.selectbox("Probability", ['low','medium','high'], key=f"risk_p_{project_id}")
        impact = c2.selectbox("Impact", ['low','medium','high'], key=f"risk_i_{project_id}")
        severity = c3.selectbox("Severity", ['low','medium','high','critical'], key=f"risk_s_{project_id}")
        mitigation = st.text_area("Mitigation", key=f"risk_m_{project_id}")
        target = st.date_input("Target date", value=date.today()+timedelta(days=14), key=f"risk_d_{project_id}")
        if st.button("Register risk", key=f"risk_add_{project_id}", type='primary'):
            if not title.strip() or not desc.strip(): st.error("Risk title and description are required.")
            elif _safe(lambda: pq.gm_add_risk(project_id,title,desc,probability,impact,severity,mitigation,None,target)):
                st.rerun()

    with st.expander("+ Record management decision", expanded=False):
        subject = st.text_input("Decision subject", key=f"dec_subject_{project_id}")
        decision = st.text_area("Decision", key=f"dec_decision_{project_id}")
        reason = st.text_area("Reason / basis", key=f"dec_reason_{project_id}")
        if st.button("Record decision", key=f"dec_add_{project_id}", type='primary'):
            if not subject.strip() or not decision.strip(): st.error("Subject and decision are required.")
            elif _safe(lambda: pq.gm_record_decision(project_id,subject,decision,reason)):
                st.rerun()


def _plan_appraisal():
    drawings = pq.plan_drawings()
    st.markdown("### Plan Appraisal Decision Queue")
    if not drawings:
        st.info("No plan appraisal drawings are currently visible."); return
    for d in drawings:
        with st.container(border=True):
            rev = d.get('current_revision', d.get('revision',1))
            st.markdown(f"**{d['drawing_no']} — {d['title']}** · Rev {rev} · {d['discipline']}")
            st.caption(f"Project: {d['project_id']} · Status: {d['status']}")
            obs = pq.plan_observations(d['id'], open_only=False)
            open_obs = [o for o in obs if o.get('status') == 'open']
            if open_obs:
                st.warning(f"{len(open_obs)} open plan appraisal observation(s)")
                for o in open_obs:
                    st.write(f"• **{o['obs_code']}** · {o['severity']} · {o['description']} · response: {o.get('response') or 'pending'}")

            if d['status'] == 'submitted':
                dms = [m.get('profiles') for m in pq.members(d['project_id']) if m.get('role')=='dm' and m.get('profiles')]
                if dms:
                    mid = st.selectbox("Department Manager", [u['id'] for u in dms], format_func=lambda x: next(u['full_name'] for u in dms if u['id']==x), key=f"gm_dm_pa_{d['id']}")
                    if st.button("Forward drawing to DM →", key=f"gm_forward_pa_{d['id']}", type='primary'):
                        if _safe(lambda:pq.gm_assign_plan_manager(d['id'],mid)): st.rerun()
            elif d['status'] == 'pending_gm_approval':
                note = st.text_area("GM decision note", key=f"gm_pa_note_{d['id']}")
                c1,c2 = st.columns(2)
                if c1.button("Approve drawing", key=f"gm_pa_approve_{d['id']}", type='primary'):
                    if _safe(lambda:pq.gm_plan_decision(d['id'],'approved',note)): st.rerun()
                if c2.button("Send to Designer for correction", key=f"gm_pa_des_{d['id']}"):
                    if not note.strip(): st.error("Correction instruction is required.")
                    elif _safe(lambda:pq.gm_plan_decision(d['id'],'send_to_designer',note)): st.rerun()
            elif d['status'] == 'rejected':
                st.warning("DM marked the design as Rejected / Amended. GM must make the management decision before the loop can continue.")
                note = st.text_area("GM amended-design decision", key=f"gm_amend_note_{d['id']}")
                c1,c2 = st.columns(2)
                if c1.button("Send to Designer for correction →", key=f"gm_amend_des_{d['id']}", type='primary'):
                    if not note.strip(): st.error("Correction instruction is required.")
                    elif _safe(lambda:pq.gm_amended_design_decision(d['id'],'send_to_designer',note)): st.rerun()
                if c2.button("Return to DM for clarification →", key=f"gm_amend_dm_{d['id']}"):
                    if not note.strip(): st.error("Return reason is required.")
                    elif _safe(lambda:pq.gm_amended_design_decision(d['id'],'return_to_dm',note)): st.rerun()
            elif d['status'] == 'approved':
                st.success("Approved drawing. Current revision is the controlling approved revision.")

            with st.expander("Revision / observation history", expanded=False):
                for r in pq.plan_revisions(d['id']):
                    st.write(f"Rev {r['revision_no']} · {r['status']} · {r['file_name']} · {r['submitted_at']}")
                for o in obs:
                    st.caption(f"{o['obs_code']} · {o['status']} · {o['raised_at']} · {o.get('response') or ''}")


def _survey_rfis():
    rfis = pq.rfis()
    st.markdown("### Survey RFI Decision Queue")
    for r in rfis:
        with st.container(border=True):
            st.markdown(f"**{r['rfi_code']}** · {r['survey_type']} · {r['priority'].upper()}")
            st.caption(f"Status: {r['status']} · Project: {r['project_id']} · Scheduled: {r.get('scheduled_date') or '—'}")
            obs = pq.observations(r['id']); open_obs=[o for o in obs if o['status']=='open']
            if r['status'] == 'pending_allocation':
                dms = [m.get('profiles') for m in pq.members(r['project_id']) if m.get('role')=='dm' and m.get('profiles')]
                if dms:
                    did=st.selectbox("Department Manager",[u['id'] for u in dms],format_func=lambda x:next(u['full_name'] for u in dms if u['id']==x),key=f"gm_dm_rfi_{r['id']}")
                    if st.button("Forward Survey RFI to DM →",key=f"gm_rfi_{r['id']}",type='primary'):
                        if _safe(lambda:pq.gm_handover_rfi(r['id'],did)): st.rerun()
            elif r['status']=='pending_gm_approval':
                task_rows=pq.all_project_tasks(r['project_id'])
                latest_dm_review=next(
                    (
                        t for t in task_rows
                        if t.get('entity_type')=='rfi'
                        and t.get('entity_id')==r['id']
                        and t.get('task_type')=='SURVEY_DM_REVIEW'
                    ),
                    None
                )
                if latest_dm_review:
                    st.markdown("#### DM Review Package")
                    st.info(latest_dm_review.get('note') or 'DM review note not available.')
                if open_obs:
                    st.warning(
                        f"{len(open_obs)} open observation(s). "
                        "GM approval will require an Interim Certificate and controlled corrective-action loop."
                    )
                    for o in open_obs:
                        st.write(
                            f"• **{o['obs_code']}** · {o['severity']} — {o['description']} · "
                            f"Rule: {o.get('rule_reference') or '—'} · "
                            f"Location: {o.get('location') or '—'}"
                        )
                else:
                    st.success("No open survey observations — full certificate gate.")
                note=st.text_area("GM survey decision note",key=f"gm_rfi_note_{r['id']}")
                c1,c2=st.columns(2)
                if c1.button("Approve survey",key=f"gm_approve_rfi_{r['id']}",type='primary'):
                    if _safe(lambda:pq.gm_decide_rfi(r['id'],'approved',note)): st.rerun()
                if c2.button("Send back to DM for rework",key=f"gm_return_rfi_{r['id']}"):
                    if not note.strip(): st.error("A reason is mandatory for send-back.")
                    elif _safe(lambda:pq.gm_decide_rfi(r['id'],'sent_back',note)): st.rerun()
            elif r['status'] in ('approved_no_observations','approved_with_observations'):
                cert_type='interim_certificate' if open_obs else 'class_certificate'
                validity=6 if open_obs else 12
                ack_tasks=[
                    t for t in pq.all_project_tasks(r['project_id'])
                    if t.get('entity_type')=='rfi'
                    and t.get('entity_id')==r['id']
                    and t.get('task_type')=='DM_GM_FINAL_APPROVAL_ACK'
                ]
                acked=any(t.get('status')=='completed' for t in ack_tasks)
                if not acked:
                    st.warning(
                        "DM final-approval acknowledgement is still pending. "
                        "The certificate issue action is locked until DM acknowledges GM's decision."
                    )
                else:
                    st.success("DM final-approval acknowledgement received. Certificate issuance is unlocked.")
                st.info(f"Certificate gate: {cert_type.replace('_',' ').title()}")
                validity=st.number_input("Validity (months)",min_value=1,max_value=60,value=validity,key=f"valid_{r['id']}")
                if st.button("Issue Certificate",key=f"cert_{r['id']}",type='primary',disabled=not acked):
                    cert=_safe(lambda:pq.issue_certificate(r['id'],cert_type,validity))
                    if cert:
                        try:
                            path=upload_certificate_pdf(cert,pq.project(r['project_id']),pq.vessel(r['project_id']))
                            st.success(f"Certificate {cert['cert_number']} issued and PDF registered at {path}.")
                        except Exception as exc:
                            st.warning(f"Certificate {cert['cert_number']} is issued, but PDF registration failed: {exc}")

            if open_obs:
                with st.expander("Observation register — controlled status",expanded=False):
                    for o in open_obs:
                        st.write(
                            f"**{o['obs_code']}** · {o['severity']} · OPEN — {o['description']}"
                        )
                    st.caption(
                        "GM cannot manually clear survey observations. The controlled path is "
                        "GM send-back → DM corrective-action assignment → Surveyor/Ship Management "
                        "evidence → DM verification → Follow-up RFI."
                    )


def _escalations():
    rows=pq.escalations(open_only=True)
    if not rows:
        st.success("No open escalations."); return
    for e in rows:
        with st.container(border=True):
            st.markdown(f"**{e['severity'].upper()} · {e['reason']}**")
            st.write(f"Recommendation: {e['recommendation']}")
            st.caption(f"Status: {e['status']} · Raised: {e['created_at']}")
            note=st.text_area("GM decision / action note",key=f"gm_esc_note_{e['id']}")
            c1,c2,c3,c4=st.columns(4)
            if c1.button("Acknowledge",key=f"esc_ack_{e['id']}"):
                if _safe(lambda:pq.gm_escalation_decide(e['id'],'acknowledge',note)): st.rerun()
            if c2.button("Return to DM",key=f"esc_return_{e['id']}"):
                if not note.strip(): st.error("Action note required.")
                elif _safe(lambda:pq.gm_escalation_decide(e['id'],'return_to_dm',note)): st.rerun()
            if c3.button("Resolve",key=f"esc_res_{e['id']}",type='primary'):
                if not note.strip(): st.error("Resolution note required.")
                elif _safe(lambda:pq.gm_escalation_decide(e['id'],'resolve',note)): st.rerun()
            if c4.button("Reject",key=f"esc_rej_{e['id']}"):
                if not note.strip(): st.error("Decision note required.")
                elif _safe(lambda:pq.gm_escalation_decide(e['id'],'reject',note)): st.rerun()


def _governance():
    projects=pq.projects('active')
    if not projects: st.info("No active projects."); return
    labels={p['id']:_project_label(p) for p in projects}
    pid=st.selectbox("Governance project",list(labels),format_func=lambda x:labels[x],key='gm_gov_project')
    _risk_decision_register(pid)
    st.markdown("### Immutable audit view")
    for a in pq.audit_events(pid,200):
        st.write(f"{a.get('created_at')} · **{a.get('action')}** · {a.get('entity_type')} · {a.get('reason') or ''}")


def _notifications():
    rows=pq.notifications()
    c1,c2=st.columns([1,4])
    with c1:
        if st.button("Mark all as read",key='gm_mark_all'):
            _safe(pq.mark_all_notifications_read); st.rerun()
    for n in rows:
        with st.container(border=True):
            st.markdown(f"**{n['title']}**")
            st.write(n['body'])
            st.caption(f"{n.get('created_at')} · {n.get('severity','info').upper()} · {n.get('notification_type','workflow')}")
            if not n.get('read_at') and st.button("Mark read",key=f"gm_n_{n['id']}"):
                _safe(lambda:pq.mark_notification_read(n['id'])); st.rerun()
