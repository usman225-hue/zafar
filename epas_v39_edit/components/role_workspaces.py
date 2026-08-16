# v2.7/v3.0 compatibility markers retained for cumulative regression coverage:
# start_survey_execution_v27 / acknowledge_survey_drawing_package_v27 historically
# pointed to the same controlled survey path; active UI uses v3.5/v3.3-authoritative wrappers.
"""Authenticated execution workspaces for Engineer, Surveyor, Designer and
Ship Management. These close the role-to-role workflow loops started by GM/DM.
"""
from __future__ import annotations
from datetime import date, timedelta
import streamlit as st
from database import production_queries as pq
from utils.file_validation import validate_uploaded_file, validate_upload_descriptor, MAX_PDF_BYTES, MAX_IMAGE_BYTES
from utils.ui import show_safe_error


def _safe(fn, context="This operation"):
    try: return fn()
    except Exception as exc:
        show_safe_error(context, exc); return None


def _task_header(t):
    st.caption(f"Project {t.get('project_id')} · due {t.get('due_at') or '—'} · {t.get('priority','normal').upper()}")


def _action_start(t):
    if t['status']=='pending':
        if st.button('Accept assignment',key=f"exec_accept_{t['id']}",type='primary'):
            if _safe(lambda:pq.secure_accept_task(t['id'])): st.rerun()
        return False
    if t['status']=='accepted':
        if st.button('Start work',key=f"exec_start_{t['id']}",type='primary'):
            if _safe(lambda:pq.secure_start_task(t['id'])): st.rerun()
    return True


def render_engineer():
    u=pq.profile()
    st.markdown("<div class='eyebrow'>EPAS · Plan Appraisal</div><div class='page-title'>Authorized Engineer Workspace</div>",unsafe_allow_html=True)
    st.caption(f"{u['full_name']} · {u['email']} · authenticated Engineer")
    tasks=pq.tasks(statuses=['pending','accepted','in_progress'],task_types=['PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK'])
    drawing_map=pq.plan_drawings_by_ids([t['entity_id'] for t in tasks])
    obs_map=pq.plan_observations_by_drawing_ids(list(drawing_map))
    st.metric('Technical review assignments',len(tasks))
    if not tasks: st.success('No technical appraisal assignments are currently waiting for you.')
    for t in tasks:
        d=drawing_map.get(str(t['entity_id']))
        if not d: continue
        with st.container(border=True):
            st.markdown(f"### {d['drawing_no']} — {d['title']} · Rev {d.get('current_revision',d.get('revision',1))}")
            _task_header(t)
            st.write(f"**Discipline:** {d['discipline']} · **Status:** {d['status']}")
            with st.container(border=True):
                st.markdown('#### Technical Review Package')
                rc = st.columns(4)
                rc[0].metric('Current revision', d.get('current_revision', d.get('revision', 1)))
                rc[1].metric('Observations', len(obs_map.get(str(d['id']), [])))
                rc[2].metric('Task state', str(t.get('status','—')).replace('_',' ').title())
                rc[3].metric('Due', str(t.get('due_at') or '—')[:10])
                st.caption('Review the controlling drawing revision, rule references, observation history, marked-up drawing and appraisal report before recording the technical decision.')
            obs=obs_map.get(str(d['id']),[])
            if obs:
                with st.expander('Observation history',expanded=False):
                    for o in obs: st.write(f"{o['obs_code']} · {o['status']} · {o['severity']} · {o['description']}")
            if not _action_start(t): continue

            st.markdown('#### 1. Controlled appraisal package')
            st.caption('Both artifacts are retained against the current drawing revision with SHA-256 integrity metadata.')
            c1,c2=st.columns(2)
            marked=c1.file_uploader('Marked-up drawing (PDF)',type=['pdf'],key=f"eng_marked_{t['id']}")
            report_pdf=c2.file_uploader('Technical appraisal report (PDF)',type=['pdf'],key=f"eng_report_{t['id']}")
            ac1,ac2=st.columns(2)
            if ac1.button('Register marked-up drawing',key=f"eng_reg_marked_{t['id']}"):
                ok,msg=validate_upload_descriptor(marked, {'pdf'}, MAX_PDF_BYTES) if marked else (False,'Select the marked-up drawing PDF first.')
                if not ok: st.error(msg)
                else:
                    if _safe(lambda:pq.engineer_register_appraisal_artifact(d['id'],'MARKED_UP_DRAWING',marked)): st.success('Marked-up drawing registered.'); st.rerun()
            if ac2.button('Register appraisal report',key=f"eng_reg_report_{t['id']}"):
                ok,msg=validate_upload_descriptor(report_pdf, {'pdf'}, MAX_PDF_BYTES) if report_pdf else (False,'Select the technical appraisal report PDF first.')
                if not ok: st.error(msg)
                else:
                    if _safe(lambda:pq.engineer_register_appraisal_artifact(d['id'],'APPRAISAL_REPORT',report_pdf)): st.success('Appraisal report registered.'); st.rerun()

            st.markdown('#### 2. Technical decision')
            decision=st.radio('Engineer decision',['APPROVED','APPROVED_AS_AMENDED','INFORMATION','REJECTED'],key=f"eng_dec_{t['id']}",horizontal=True,
                              format_func=lambda x:x.replace('_',' ').title())
            note=st.text_area('Engineer technical conclusion',key=f"eng_note_{t['id']}")
            needs_verification=st.checkbox('Require Surveyor verification before Manager review',key=f"eng_sv_verify_{t['id']}")
            if needs_verification:
                st.info('Workflow branch: Engineer → Surveyor Verification → Manager Review. A controlled verification task will be assigned to an eligible Surveyor.')
            payload=[]
            if decision in ('APPROVED_AS_AMENDED','REJECTED'):
                count=int(st.number_input('Number of technical observations / amendments',min_value=1,max_value=20,value=1,key=f"eng_obs_count_{t['id']}"))
                for i in range(count):
                    with st.expander(f"Observation / Amendment {i+1}",expanded=i==0):
                        code=st.text_input('Observation No. (optional)',key=f"eng_obs_code_{t['id']}_{i}")
                        desc=st.text_area('Technical observation / amendment',key=f"eng_obs_desc_{t['id']}_{i}")
                        sev=st.selectbox('Severity',['Minor','Major','Critical'],key=f"eng_obs_sev_{t['id']}_{i}")
                        clause=st.text_input('Rule / clause reference',key=f"eng_obs_clause_{t['id']}_{i}")
                        drawing_ref=st.text_input('Drawing reference / sheet',key=f"eng_obs_ref_{t['id']}_{i}")
                        payload.append({'obs_code':code,'description':desc,'severity':sev,'clause_reference':clause,'drawing_reference':drawing_ref})
            if st.button('Submit controlled technical appraisal →',key=f"eng_submit_{t['id']}",type='primary'):
                if not note.strip(): st.error('Technical conclusion is required.')
                elif decision=='APPROVED_AS_AMENDED' and any(not x['description'].strip() for x in payload): st.error('Every amendment requires a technical description.')
                elif decision=='REJECTED' and any(not x['description'].strip() for x in payload): st.error('Every rejection observation requires a technical description.')
                else:
                    if _safe(lambda:pq.engineer_submit_review_v36(d['id'],decision,note,payload,needs_verification)): st.rerun()

def render_surveyor():
    u=pq.profile()
    st.markdown("<div class='eyebrow'>EPAS · Survey Operations</div><div class='page-title'>Authorized Surveyor Workspace</div>",unsafe_allow_html=True)
    st.caption(f"{u['full_name']} · {u['email']} · authenticated Surveyor")
    # v2.1: first-class Engineer → Surveyor verification branch.
    try:
        verification_queue=pq.surveyor_plan_verification_queue()
        if verification_queue:
            st.markdown('### Plan Appraisal — Surveyor Verification')
            st.info('These assignments are verification-only: confirm the Engineer’s specified technical point and return a controlled result before Manager review.')
            for vq in verification_queue:
                with st.container(border=True):
                    st.markdown(f"**{vq['drawing_no']} — {vq['title']} · Rev {vq['revision']}**")
                    st.caption(f"Engineer decision: {str(vq['engineer_decision'] or '—').replace('_',' ').title()} · Due: {vq['due_at'] or '—'}")
                    st.write(vq['decision_note'] or 'No Engineer note supplied.')
                    if vq.get('status') == 'pending':
                        if not _action_start({'id':vq['task_id'],'status':'pending','project_id':vq['project_id'],'due_at':vq['due_at'],'priority':'high'}):
                            continue
                    result=st.radio('Verification result',['VERIFIED','NOT_VERIFIED'],key=f"sv_plan_verify_result_{vq['drawing_id']}",horizontal=True)
                    note=st.text_area('Surveyor verification note',key=f"sv_plan_verify_note_{vq['drawing_id']}")
                    if st.button('Submit Surveyor verification →',key=f"sv_plan_verify_submit_{vq['drawing_id']}",type='primary'):
                        if not note.strip(): st.error('Verification note is required.')
                        elif _safe(lambda:pq.surveyor_verify_plan_appraisal(vq['drawing_id'],result,note)): st.rerun()
    except Exception as exc:
        st.warning(f'Plan appraisal verification queue unavailable: {exc}')

    tasks=pq.tasks(statuses=['pending','accepted','in_progress'],task_types=['SURVEY_EXECUTION','CORRECTIVE_ACTION_EXECUTION'])
    rfi_map=pq.rfis_by_ids([t['entity_id'] for t in tasks if t.get('entity_id')])
    c=st.columns(2); c[0].metric('Assigned surveys',sum(t['task_type']=='SURVEY_EXECUTION' for t in tasks)); c[1].metric('Corrective actions',sum(t['task_type']=='CORRECTIVE_ACTION_EXECUTION' for t in tasks))
    for t in tasks:
        with st.container(border=True):
            if t['task_type']=='SURVEY_EXECUTION':
                r=rfi_map.get(str(t['entity_id']))
                if not r: continue
                st.markdown(f"### {r.get('rfi_code','RFI')} — {r.get('survey_type','—')}"); _task_header(t)
                st.write(f"Vessel / project: {r.get('vessel_id')} / {r.get('project_id')} · scheduled {r.get('scheduled_date') or '—'}")
                if not _action_start(t): continue
                # v2.6: formal Surveyor assignment acceptance is separate from the generic task acceptance.
                gate = _safe(lambda: pq.survey_start_gate_v36(r['id'])) or {}
                if not gate.get('assignment_accepted'):
                    st.warning('The workflow task is accepted, but the formal Surveyor assignment still requires explicit acceptance.')
                    accept_note = st.text_input('Assignment acceptance note', key=f'sv_assign_accept_note_{t["id"]}')
                    if st.button('Accept formal survey assignment →', key=f'sv_formal_accept_{t["id"]}', type='primary'):
                        if _safe(lambda: pq.surveyor_accept_assignment_v36(r['id'], accept_note)):
                            st.rerun()
                    continue
                if not gate.get('scope_acknowledged'):
                    st.warning(f'Survey Scope v{gate.get("scope_version", "—")} must be acknowledged before survey execution.')
                    scope_note = st.text_input('Scope acknowledgement note', key=f'sv_scope_ack_note_{t["id"]}')
                    if st.button('Acknowledge current survey scope →', key=f'sv_scope_ack_{t["id"]}', type='primary'):
                        if _safe(lambda: pq.acknowledge_survey_scope(r['id'], scope_note)):
                            st.rerun()
                    continue
                if not gate.get('package_acknowledged'):
                    st.warning(f'Controlled drawing package v{gate.get("package_version", "—")} must be acknowledged.')
                    if st.button('Acknowledge controlled drawing package →', key=f'sv_pkg_ack_{t["id"]}', type='primary'):
                        if _safe(lambda: pq.acknowledge_survey_drawing_package_v36(r['id'])):
                            st.rerun()
                    continue
                # v3.5: make the authoritative readiness chain visible before execution.
                with st.container(border=True):
                    st.markdown('#### Survey Start Readiness')
                    readiness = [
                        ('Assignment accepted', bool(gate.get('assignment_accepted'))),
                        ('Scope acknowledged', bool(gate.get('scope_acknowledged'))),
                        ('Drawing package acknowledged', bool(gate.get('package_acknowledged'))),
                        ('Checklist complete', bool(gate.get('checklist_ready'))),
                        ('Revision impact clear', bool(gate.get('revision_impact_clear'))),
                        ('Execution basis frozen', bool(gate.get('basis_frozen'))),
                    ]
                    for label, ok in readiness:
                        (st.success if ok else st.warning)(('✓ ' if ok else '• ') + label)
                    if all(ok for _, ok in readiness):
                        st.success('READY — all controlled gates are satisfied. The Surveyor may start execution.', icon='✅')
                # v2.1: first-class business branch — NSC and In-Service follow different
                # coordination/checklist paths while sharing the controlled survey engine.
                phase=(r.get('phase') or '').lower()
                if phase=='nsc_survey':
                    st.success('Survey branch: NSC (Newbuilding / New Ship in Class)')
                    st.markdown('**NSC pre-survey path:** Shipyard coordination → approved design package → access/schedule confirmation → survey execution.')
                elif phase=='in_service':
                    st.info('Survey branch: In-Service')
                    st.markdown('**In-Service pre-survey path:** Owner / Ship Management coordination → previous survey / certificate review → maintenance/change-of-class checks → survey execution.')
                else:
                    st.warning('Survey phase is not recognized; DM must correct the RFI before survey execution.')
                    continue
                # v1.9: mandatory pre-survey checklist. NSC and In-Service use the
                # same controlled checklist engine, with In-Service-specific items.
                try:
                    checklist=pq.survey_checklist(r['id'])
                    st.markdown('#### Pre-Survey Checklist')
                    for item in checklist:
                        if item['status']=='complete':
                            st.success(f"{item['item_code']} · {item['requirement']}", icon='✓')
                        elif item['status']=='not_applicable':
                            st.info(f"{item['item_code']} · N/A · {item['requirement']}")
                        else:
                            with st.expander(f"{item['item_code']} · {item['requirement']}", expanded=item['mandatory']):
                                response=st.text_input('Response / confirmation',key=f"sv_chk_resp_{item['id']}")
                                remarks=st.text_area('Checklist remarks',key=f"sv_chk_rem_{item['id']}")
                                c1,c2=st.columns(2)
                                if c1.button('Mark complete',key=f"sv_chk_ok_{item['id']}"):
                                    if _safe(lambda:pq.complete_survey_checklist_item(item['id'],'complete',response,remarks)): st.rerun()
                                if not item['mandatory'] and c2.button('Not applicable',key=f"sv_chk_na_{item['id']}"):
                                    if _safe(lambda:pq.complete_survey_checklist_item(item['id'],'not_applicable',response,remarks)): st.rerun()
                    gate=pq.survey_start_gate_v36(r['id'])
                    if not gate.get('checklist_ready'):
                        st.warning('Mandatory pre-survey checklist items remain incomplete. The controlled survey cannot start yet.')
                    if not gate.get('revision_impact_clear'):
                        st.error('An approved Plan Appraisal drawing revision changed after handover. DM must decide NO_IMPACT or reissue the drawing package before the survey can start.')
                        impacts=_safe(lambda: pq.drawing_revision_impact(r['id'])) or []
                        for imp in impacts:
                            if imp.get('impact') != 'NO_CHANGE':
                                st.caption(f"{imp.get('drawing_no','Drawing')} · shared Rev {imp.get('shared_revision')} → current Rev {imp.get('current_revision')} · {imp.get('recommendation','DM decision required.')}")
                    if gate.get('checklist_ready') and gate.get('revision_impact_clear'):
                        if st.button('Start controlled survey execution →', key=f'sv_start_{t["id"]}', type='primary'):
                            if _safe(lambda: pq.start_survey_execution_v36(r['id'])):
                                st.rerun()
                except Exception as exc:
                    st.error(f'Pre-survey checklist unavailable: {exc}')
                    continue
                report=st.text_area('Survey report / technical findings',key=f"sv_report_{t['id']}")
                loc=st.text_input('Survey location',key=f"sv_loc_{t['id']}")
                attendance=st.text_area('Attendance / representatives present',key=f"sv_att_{t['id']}")
                evidence=st.file_uploader('Controlled survey report / evidence (PDF)',type=['pdf'],key=f"sv_evid_{t['id']}")
                count=int(st.number_input('Number of observations',min_value=0,max_value=30,value=0,key=f"sv_count_{t['id']}"))
                payload=[]
                for i in range(count):
                    with st.expander(f"Survey Observation {i+1}",expanded=i==0):
                        code=st.text_input('Observation No. (optional)',key=f"sv_code_{t['id']}_{i}")
                        desc=st.text_area('Observation / deficiency',key=f"sv_desc_{t['id']}_{i}")
                        sev=st.selectbox('Severity',['Minor','Major','Critical'],key=f"sv_sev_{t['id']}_{i}")
                        rule=st.text_input('Applicable rule / clause',key=f"sv_rule_{t['id']}_{i}")
                        location=st.text_input('Location / equipment / item',key=f"sv_obsloc_{t['id']}_{i}")
                        category=st.text_input('Deficiency category',key=f"sv_cat_{t['id']}_{i}")
                        responsible=st.text_input('Responsible party',key=f"sv_resp_{t['id']}_{i}")
                        target=st.date_input('Target date',value=date.today()+timedelta(days=7),key=f"sv_target_{t['id']}_{i}")
                        corrective=st.text_area('Corrective action required',key=f"sv_ca_{t['id']}_{i}")
                        payload.append({'obs_code':code,'description':desc,'severity':sev,'rule_reference':rule,
                                        'location':location,'deficiency_category':category,'responsible_party':responsible,
                                        'target_date':target.isoformat(),'corrective_action':corrective})
                st.markdown('#### Professional Surveyor Declaration')
                scope_confirmed=st.checkbox('I confirm the survey was performed against the acknowledged scope version.',key=f'sv_decl_scope_{t["id"]}')
                drawings_confirmed=st.checkbox('I confirm the controlled drawing package used is the acknowledged package version.',key=f'sv_decl_drawings_{t["id"]}')
                attendance_confirmed=st.checkbox('I confirm attendance / representatives have been accurately recorded.',key=f'sv_decl_att_{t["id"]}')
                safety_confirmed=st.checkbox('I confirm the applicable safety arrangements were in place.',key=f'sv_decl_safety_{t["id"]}')
                report_complete=st.checkbox('I confirm the report and findings are complete and accurate.',key=f'sv_decl_complete_{t["id"]}')
                declaration=st.text_area('Professional declaration',value='I certify that this report accurately records the survey performed, the scope covered, the drawings reviewed, the attendance and the findings.',key=f"sv_dec_{t['id']}")
                if st.button('Submit controlled survey report →',key=f"sv_submit_{t['id']}",type='primary'):
                    gate=pq.survey_submission_gate_v36(r['id']) or {}
                    if not gate.get('assignment_accepted'): st.error('Formal Surveyor assignment acceptance is required.')
                    elif not gate.get('scope_acknowledged'): st.error('Acknowledge the current scope version first.')
                    elif not gate.get('package_acknowledged'): st.error('Acknowledge the controlled drawing package first.')
                    elif not gate.get('checklist_ready'): st.error('Complete all mandatory pre-survey checklist items first.')
                    elif not gate.get('basis_frozen'): st.error('Start the controlled survey execution before submitting a report.')
                    elif not all([scope_confirmed,drawings_confirmed,attendance_confirmed,safety_confirmed,report_complete]): st.error('Complete all professional Surveyor declarations first.')
                    elif not report.strip(): st.error('Survey report is required.')
                    elif not declaration.strip(): st.error('Professional declaration text is required.')
                    elif not evidence: st.error('Controlled survey report PDF is required.')
                    elif not validate_uploaded_file(evidence, {'pdf'}, MAX_PDF_BYTES)[0]: st.error(validate_uploaded_file(evidence, {'pdf'}, MAX_PDF_BYTES)[1])
                    elif any(not x['description'].strip() for x in payload): st.error('Every survey observation needs a description.')
                    else:
                        def _submit():
                            pq.confirm_survey_execution_declaration(r['id'],declaration,scope_confirmed,drawings_confirmed,attendance_confirmed,safety_confirmed,report_complete)
                            return pq.submit_survey_report_v36(r['id'],report,payload,evidence,loc,attendance,date.today(),declaration)
                        if _safe(_submit): st.rerun()
            else:
                action=next((a for a in pq.corrective_actions() if a['id']==t['entity_id']),None)
                if not action: continue
                st.markdown(f"### Corrective Action · {action['id']}"); _task_header(t); st.write(action['instruction'])
                if not _action_start(t): continue
                evidence=st.file_uploader('Evidence / corrective-action record',type=['pdf','jpg','jpeg','png'],key=f"ca_file_{t['id']}")
                note=st.text_area('Completion note',key=f"ca_note_{t['id']}")
                if st.button('Submit corrective action →',key=f"ca_submit_{t['id']}",type='primary'):
                    ok,msg=validate_upload_descriptor(evidence, {'pdf','jpg','jpeg','png'}, max(MAX_PDF_BYTES,MAX_IMAGE_BYTES)) if evidence else (False,'Evidence file is required.')
                    if not ok: st.error(msg)
                    else:
                        if _safe(lambda:pq.assignee_submit_corrective_v36(action['id'],evidence,note)): st.rerun()


def render_designer():
    u=pq.profile()
    st.markdown("<div class='eyebrow'>EPAS · Design Submissions</div><div class='page-title'>Designer Revision Workspace</div>",unsafe_allow_html=True)
    st.caption(f"{u['full_name']} · {u['email']} · authenticated Designer")
    # v1.9: submission tracker mirrors the Designer workflow diagram.
    try:
        queue=pq.designer_submission_queue()
        with st.expander('Submission tracker', expanded=True):
            if not queue:
                st.info('No drawings are currently associated with this Designer.')
            else:
                for row in queue:
                    st.markdown(f"**{row['drawing_no']} · Rev {row['current_revision']}** — {row['title']}")
                    st.caption(f"Status: {str(row['status']).replace('_',' ').title()} · Latest revision: {str(row['latest_revision_status'] or '—').replace('_',' ').title()} · Action: {row['action_required']}")
    except Exception as exc:
        st.warning(f'Submission tracker unavailable: {exc}')
    projects=pq.authorized_projects_v36()
    with st.expander('Submit new drawing for GM intake',expanded=not projects):
        if not projects:
            st.info('No active project membership is linked to this Designer account.')
        else:
            labels={p['id']:f"{p['project_code']} · {p['name']}" for p in projects}
            if labels:
                pid=st.selectbox('Project',list(labels),format_func=lambda x:labels[x],key='des_initial_project')
                c1,c2=st.columns(2)
                drawing_no=c1.text_input('Drawing number',key='des_initial_no')
                title=c2.text_input('Drawing title',key='des_initial_title')
                discipline=st.selectbox('Discipline',['Hull & Structure','Machinery','Electrical','Stability','Safety Equipment','Fire & LSA'],key='des_initial_disc')
                f=st.file_uploader('Initial drawing PDF',type=['pdf'],key='des_initial_file')
                note=st.text_area('Submission note',key='des_initial_note')
                if st.button('Submit drawing to GM →',key='des_initial_submit',type='primary'):
                    if not drawing_no.strip() or not title.strip() or not f:
                        st.error('Drawing number, title and PDF are required.')
                    elif _safe(lambda:pq.designer_submit_initial_drawing(pid,drawing_no,title,discipline,f,note)):
                        st.rerun()
            else:
                st.info('No active Designer project membership is linked to your account.')
    tasks=pq.tasks(statuses=['pending','accepted','in_progress'],task_types=['PLAN_APPRAISAL_DESIGNER_RESPONSE'])
    if not tasks: st.success('No Designer correction requests are currently waiting.'); return
    for t in tasks:
        d=pq.plan_drawing(t['entity_id'])
        if not d: continue
        with st.container(border=True):
            st.markdown(f"### {d['drawing_no']} — {d['title']} · Rev {d.get('current_revision',d.get('revision',1))}")
            _task_header(t)
            st.warning('GM/DM correction instruction: '+(t.get('note') or 'See workflow record.'))
            st.markdown('**Revision history**')
            revisions = pq.plan_revisions(d['id'])
            if revisions:
                for r in revisions:
                    state = str(r['status']).replace('_',' ').title()
                    st.markdown(f"**Rev {r['revision_no']}** · {state} · {r['file_name']}")
                    st.caption(f"Submitted: {r.get('submitted_at','—')}")
            else:
                st.caption('No previous revision history is available yet.')
            if not _action_start(t): continue
            f=st.file_uploader('Upload corrected drawing PDF',type=['pdf'],key=f"des_file_{t['id']}")
            note=st.text_area('Designer revision / response note',key=f"des_note_{t['id']}")
            if st.button('Submit new revision → DM',key=f"des_submit_{t['id']}",type='primary'):
                ok,msg=validate_upload_descriptor(f, {'pdf'}, MAX_PDF_BYTES) if f else (False,'Corrected PDF and revision note are required.')
                if not ok or not note.strip(): st.error(msg if not ok else 'Corrected PDF and revision note are required.')
                elif _safe(lambda:pq.designer_submit_revision(d['id'],f,note)): st.rerun()



def _render_stakeholder_fleet_summary(stakeholder_role: str):
    if stakeholder_role not in ('owner','ship_management','shipyard'):
        return
    try:
        bundle = pq.stakeholder_fleet_bundle_v36() or {}
        if stakeholder_role == 'shipyard':
            title = 'NSC Fleet / Project Snapshot'
        else:
            title = 'In-Service Fleet Snapshot'
        st.markdown(f'### {title}')
        c = st.columns(4)
        c[0].metric('Visible vessels', bundle.get('visible_vessels', bundle.get('vessel_count', 0)))
        c[1].metric('Due', bundle.get('due_count', 0))
        c[2].metric('Overdue', bundle.get('overdue_count', 0))
        c[3].metric('Active RFIs', bundle.get('active_rfi_count', 0))
    except Exception:
        pass


def _render_stakeholder_rfi_request(projects, user_id: str, key_prefix: str, stakeholder_role: str):
    if not projects:
        return
    phase_by_role={
        'shipyard': ('nsc_survey','NSC Survey'),
        'owner': ('in_service','In-Service Survey'),
        'ship_management': ('in_service','In-Service Survey'),
    }
    phase, phase_label = phase_by_role.get(stakeholder_role, (None,None))
    if not phase:
        return
    _render_stakeholder_fleet_summary(stakeholder_role)
    if stakeholder_role in ('owner','ship_management'):
        with st.expander('Due / Upcoming In-Service Survey Cycles', expanded=True):
            try:
                schedule_rows=[x for x in pq.schedule_bundle_v36(None) if x.get('phase')=='in_service']
                if not schedule_rows:
                    st.info('No active In-Service survey schedule is currently available.')
                for sr in schedule_rows[:30]:
                    state=sr.get('status','SCHEDULED')
                    st.markdown(f"**{sr.get('vessel_name','Vessel')}** · Cycle {sr.get('cycle_number',1)} · Due {sr.get('next_due_date')} · {state}")
                    st.caption(f"Basis: {sr.get('due_basis','—')} · Ref: {sr.get('due_basis_reference','—')} · Window: {sr.get('window_start')} → {sr.get('window_end')}")
                    if sr.get('schedule_config_status')=='CONFIGURATION_REQUIRED':
                        st.error('Schedule basis/interval requires DM/GM configuration before a new cycle can be initiated.')
                    elif not sr.get('rfi_id') and state in ('DUE_SOON','DUE','OVERDUE','SCHEDULED'):
                        with st.container(border=True):
                            st.caption('Guided action: this schedule will pre-bind the new RFI to the correct In-Service survey cycle.')
                            stype=st.text_input('Survey type',value=sr.get('survey_type') or 'In-Service Survey',key=f"{key_prefix}_guided_type_{sr['schedule_id']}")
                            rdate=st.date_input('Requested date',value=sr.get('next_due_date') or date.today(),key=f"{key_prefix}_guided_date_{sr['schedule_id']}")
                            pri=st.selectbox('Priority',['low','medium','high'],index=1,key=f"{key_prefix}_guided_pri_{sr['schedule_id']}")
                            sc=st.text_area('Scope / survey request',key=f"{key_prefix}_guided_scope_{sr['schedule_id']}")
                            if st.button('Initiate this In-Service survey cycle →',key=f"{key_prefix}_guided_submit_{sr['schedule_id']}",type='primary'):
                                if not sc.strip():
                                    st.error('Survey scope is required.')
                                elif _safe(lambda:pq.create_scheduled_in_service_rfi(sr['schedule_id'],stype,rdate,pri,sc)):
                                    st.success('In-Service RFI created and linked to the active survey cycle.'); st.rerun()
            except Exception as exc:
                st.warning(f'In-Service schedule control unavailable: {exc}')

    with st.expander(f'Initiate {phase_label} RFI', expanded=False):
        labels={p['id']:f"{p.get('project_code','—')} · {p.get('name','—')}" for p in projects}
        pid=st.selectbox('Project',list(labels),format_func=lambda x:labels[x],key=f'{key_prefix}_project')
        vessel=pq.vessel(pid)
        if not vessel:
            st.error('No vessel is linked to the selected project.')
            return
        st.info(f'{stakeholder_role.replace("_"," ").title()} may initiate {phase_label} RFIs only.')
        survey_type=st.text_input('Survey type',key=f'{key_prefix}_type',placeholder='Annual Survey / Initial Survey / HAT / Special Survey')
        requested_date=st.date_input('Requested survey date',value=date.today(),key=f'{key_prefix}_date')
        priority=st.selectbox('Priority',['low','medium','high'],index=1,key=f'{key_prefix}_priority')
        scope=st.text_area('Survey scope / request details',key=f'{key_prefix}_scope')
        if st.button('Submit RFI to GM Intake →',key=f'{key_prefix}_submit',type='primary'):
            if not survey_type.strip() or not scope.strip():
                st.error('Survey type and scope are required.')
            elif _safe(lambda:pq.stakeholder_create_rfi(pid,vessel['id'],phase,survey_type,requested_date,priority,scope)):
                st.success('RFI submitted to GM Intake. The stakeholder can track its controlled status from the RFI status list.')
                st.rerun()


def _render_stakeholder_rfi_status(projects, key_prefix: str):
    if not projects:
        return
    with st.expander('My initiated RFIs', expanded=False):
        try:
            requester = pq.profile()['id']
            rows = [r for r in pq.rfis(project_id=None) if r.get('requested_by') == requester]
        except Exception:
            rows = []
        if not rows:
            st.info('No RFIs initiated by this stakeholder.')
            return
        for r in rows[:50]:
            st.write(f"**{r.get('rfi_code','RFI')}** · {r.get('phase','—').replace('_',' ').title()} · {r.get('survey_type','—')} · **{r.get('status','—').replace('_',' ').title()}**")
            if r.get('scope_note'): st.caption(r['scope_note'])

def render_ship_management():
    u=pq.profile()
    st.markdown("<div class='eyebrow'>EPAS · Corrective Action</div><div class='page-title'>Ship Management Corrective Action Workspace</div>",unsafe_allow_html=True)
    st.caption(f"{u['full_name']} · {u['email']} · authenticated Ship Management")
    active_projects=pq.projects('active')
    _render_stakeholder_rfi_request(active_projects,u['id'],'sm_rfi','ship_management')
    _render_stakeholder_rfi_status(active_projects,'sm_rfi_status')
    try:
        actions=pq.ship_management_action_queue()
        with st.expander('My corrective-action queue', expanded=True):
            if not actions: st.info('No corrective actions are currently assigned to Ship Management.')
            for a in actions:
                st.markdown(f"**{a['rfi_code']} · {a['action_id']}** · {a['obs_count']} observation(s) · {str(a['status']).replace('_',' ').title()}")
                st.caption(f"Due: {a['due_at'] or '—'} · Evidence: {'Submitted' if a['evidence_path'] else 'Required'}")
    except Exception as exc:
        st.warning(f'Corrective-action queue unavailable: {exc}')
    tasks=pq.tasks(statuses=['pending','accepted','in_progress'],task_types=['CORRECTIVE_ACTION_EXECUTION'])
    if not tasks: st.success('No corrective actions assigned.'); return
    for t in tasks:
        action=next((a for a in pq.corrective_actions() if a['id']==t['entity_id']),None)
        if not action: continue
        with st.container(border=True):
            st.markdown(f"### Corrective Action · {action['id']}"); _task_header(t)
            st.write(action['instruction'])
            if not _action_start(t): continue
            evidence=st.file_uploader('Corrective evidence',type=['pdf','jpg','jpeg','png'],key=f"sm_file_{t['id']}")
            note=st.text_area('Completion statement',key=f"sm_note_{t['id']}")
            if st.button('Submit corrective action →',key=f"sm_submit_{t['id']}",type='primary'):
                if not evidence:
                    st.error('Evidence is required.')
                elif _safe(lambda:pq.assignee_submit_corrective_v36(action['id'],evidence,note)):
                    st.rerun()


def render_readonly_stakeholder():
    """Read-only external stakeholder workspace for Owner and Shipyard.
    Stakeholders see only projects they are explicitly linked to and the
    controlled project information intended for external visibility.
    """
    u = pq.profile()
    stakeholder_role = u.get("role")
    title = "Owner Stakeholder Workspace" if stakeholder_role == "owner" else "Shipyard Stakeholder Workspace"
    st.markdown(
        f"<div class='eyebrow'>EPAS · External Stakeholder</div>"
        f"<div class='page-title'>{title}</div>",
        unsafe_allow_html=True,
    )
    st.caption(
        f"{u['full_name']} · {u['email']} · authenticated external stakeholder · "
        "released project data plus controlled RFI initiation"
    )

    # RLS must be the final authorization boundary. The application additionally
    # filters the visible projects by explicit stakeholder membership.
    visible = pq.authorized_projects_v36()

    if not visible:
        st.info("No active projects are linked to this stakeholder account.")
        return

    _render_stakeholder_rfi_request(visible,u['id'],f"{stakeholder_role}_rfi",stakeholder_role)
    _render_stakeholder_rfi_status(visible,f"{stakeholder_role}_rfi_status")

    labels = {p["id"]: f"{p.get('project_code','—')} · {p.get('name','—')}" for p in visible}
    pid = st.selectbox("Project", list(labels), format_func=lambda x: labels[x], key="stakeholder_project")
    project = pq.project(pid)
    vessel = pq.vessel(pid)

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Project status", (project or {}).get("status", "—").replace("_", " ").title())
    c2.metric("Vessel", (project or {}).get("name", "—"))
    c3.metric("Vessel type", (project or {}).get("vessel_type", "—"))
    c4.metric("Flag", (project or {}).get("flag_state", "—"))

    if vessel:
        with st.expander("Vessel particulars", expanded=True):
            st.write({
                "IMO / Registration": vessel.get("imo_number"),
                "Owner": vessel.get("owner_company"),
                "LOA (m)": vessel.get("loa_m"),
                "Beam (m)": vessel.get("beam_m"),
                "Draft (m)": vessel.get("draft_m"),
                "Power (kW)": vessel.get("power_kw"),
                "Speed (knots)": vessel.get("speed_knots"),
            })

    st.markdown("### Stakeholder-visible project information")
    # v1.9 fleet/vessel view: Owner, Ship Management and Shipyard get a
    # controlled vessel-centric view. Shipyard still initiates NSC only.
    try:
        fleet=pq.stakeholder_fleet_bundle_v36()
        if fleet:
            mc=st.columns(6)
            mc[0].metric('Total vessels', fleet.get('total_vessels',0))
            mc[1].metric('In Class', fleet.get('in_class',0))
            mc[2].metric('Interim', fleet.get('interim',0))
            mc[3].metric('Out of Class', fleet.get('out_of_class',0))
            mc[4].metric('Certs expiring', fleet.get('expiring_certificates',0))
            mc[5].metric('Open observations', fleet.get('open_observations',0))
        if vessel:
            vd=pq.stakeholder_vessel_bundle_v36(vessel['id'])
            if vd:
                st.markdown('#### Vessel Status Overview')
                a,b,c,d=st.columns(4)
                vm=vd.get('vessel',{})
                a.metric('Class status',vm.get('class_status','—'))
                b.metric('Certificates',vd.get('certificate_count',0))
                c.metric('Open observations',vd.get('open_observations',0))
                d.metric('Next survey',vd.get('next_survey_date') or '—')
                upcoming=vd.get('upcoming_surveys') or []
                with st.expander('Upcoming surveys', expanded=False):
                    if not upcoming: st.info('No upcoming surveys recorded.')
                    for r in upcoming[:20]:
                        st.write(f"**{r.get('rfi_code','RFI')}** · {str(r.get('phase','—')).replace('_',' ').title()} · {r.get('survey_type','—')} · {str(r.get('status','—')).replace('_',' ').title()} · {r.get('scheduled_date') or 'Not scheduled'}")
    except Exception as exc:
        st.warning(f'Fleet/vessel dashboard unavailable: {exc}')

    tabs = st.tabs(["Milestones", "Approved / Released Documents", "Certificates", "Survey History", "Notifications"])

    with tabs[0]:
        try:
            milestones = [m for m in pq.milestones(pid) if m.get("stakeholder_visible")]
            if not milestones:
                st.info("No milestones have been released for stakeholder viewing.")
            for m in milestones:
                title=m.get('title') or m.get('name') or m.get('code') or 'Milestone'
                st.write(
                    f"**{title}** · {m.get('status','—').replace('_',' ').title()} · "
                    f"due {m.get('due_date') or '—'}"
                )
                if m.get("release_note"):
                    st.caption(m["release_note"])
        except Exception as exc:
            st.error(str(exc))

    with tabs[1]:
        docs=pq.released_documents(pid, stakeholder_only=True)
        if not docs:
            st.info('No released documents are currently available to this stakeholder.')
        for d in docs:
            with st.container(border=True):
                st.write(f"**{d['file_name']}** · {d.get('category','—')} · Rev/Version {d.get('version',1)}")
                st.caption(f"Released status: {d.get('release_status','—')} · Uploaded {d.get('uploaded_at','—')}")
                if st.button('View / Download controlled copy',key=f"stake_doc_{d['id']}"):
                    try:
                        url=pq.project_document_signed_url(d['id'],expires_in=600)
                        st.link_button('Open controlled document',url)
                    except Exception as exc:
                        st.error(str(exc))
        st.caption('Internal appraisal working papers, draft observations and confidential audit records remain inaccessible.')

    with tabs[2]:
        try:
            certs = [c for c in pq.certificates(pid) if c.get("status") in ("active","superseded")]
            if not certs:
                st.info("No released certificates are currently available.")
            for c in certs:
                with st.container(border=True):
                    st.write(
                        f"**{c.get('cert_number') or c.get('certificate_no') or 'Certificate'}** · "
                        f"{c.get('cert_type','—').replace('_',' ').title()} · {c.get('status','—').title()}"
                    )
                    st.caption(f"Issued: {c.get('issue_date') or '—'} · Valid to: {c.get('expiry_date') or '—'}")
                    if c.get("pdf_storage_path") and st.button("Open controlled certificate copy", key=f"stake_cert_{c['id']}"):
                        try:
                            url=pq.certificate_pdf_signed_url(c["id"],expires_in=600)
                            st.link_button("Open certificate PDF",url)
                        except Exception as exc:
                            st.error(str(exc))
        except Exception as exc:
            st.error(str(exc))

    with tabs[3]:
        try:
            rfis=pq.rfis(project_id=pid)
            visible_rfis=[r for r in rfis if r.get('requested_by')==u['id']]
            if not visible_rfis:
                st.info('No survey history is available for this stakeholder.')
            for r in visible_rfis[:50]:
                with st.container(border=True):
                    st.write(f"**{r.get('rfi_code','RFI')}** · {r.get('phase','—').replace('_',' ').title()} · {r.get('survey_type','—')} · {r.get('status','—').replace('_',' ').title()}")
                    obs=pq.stakeholder_observation_summary(r['id'])
                    if obs:
                        st.caption(f"{len(obs)} observation(s) recorded")
                        for o in obs:
                            st.write(f"{o['obs_code']} · {o['severity']} · {o['status']} · {o.get('location') or 'Location not stated'}")
        except Exception as exc:
            st.warning(f'Survey history unavailable: {exc}')

    with tabs[4]:
        notes = pq.notifications()
        if not notes:
            st.info("No notifications.")
        for n in notes[:30]:
            st.write(f"**{n.get('title','Notification')}** · {n.get('body','')}")
