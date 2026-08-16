"""EPAS v1.4 Department Manager production workspace.

DM is the operational control point for both Plan Appraisal and Survey RFI
branches. It includes authorization/competency/availability allocation,
resource workload, SLA/overdue monitoring, corrective actions, escalation and
observation closure. No actor switching or client-side state mutation.
"""
from __future__ import annotations
from datetime import date, timedelta
import streamlit as st
from database import production_queries as pq
from components import governance_v15


def _safe(fn):
    try: return fn()
    except Exception as exc:
        st.error(str(exc)); return None


def render() -> None:
    user=pq.profile()
    st.markdown("<div class='eyebrow'>EPAS · Department Operations</div><div class='page-title'>DM Dashboard / Inbox</div>",unsafe_allow_html=True)
    st.caption(f"Authenticated as {user['full_name']} · {user['email']} · Department Manager")
    # v3.5 Point 16: queue-first summary so the DM sees the highest-value work first.
    summary = pq.role_dashboard_summary_v36() or {}
    q = st.columns(5)
    q[0].metric('Assignments', summary.get('open_tasks', 0))
    q[1].metric('Overdue', summary.get('overdue_tasks', 0))
    q[2].metric('Open actions', summary.get('open_actions', 0))
    q[3].metric('Survey due', summary.get('schedule_due', 0))
    q[4].metric('Certificates', summary.get('open_certificates', 0))
    st.caption('Recommended order: assignment → scope/drawing package → survey readiness → verification → certificate acknowledgement.')
    tasks=pq.tasks(statuses=['pending','accepted','in_progress'])
    projects=pq.projects('active')
    c=st.columns(6)
    c[0].metric('Inbox',len(tasks)); c[1].metric('Plan',sum(t.get('entity_type')=='plan_drawing' for t in tasks)); c[2].metric('Survey',sum(t.get('entity_type')=='rfi' for t in tasks)); c[3].metric('Corrective',sum(t.get('task_type')=='DM_CORRECTIVE_ACTION' for t in tasks)); c[4].metric('Overdue',sum(_is_overdue(t) for t in tasks)); c[5].metric('Projects',len(projects))
    sections=['Inbox','Plan Appraisal','Survey RFI','Resource & SLA','Escalations','Project Control','Governance','Notifications']
    section=st.radio('DM WORKSPACE',sections,horizontal=True,key='dm_workspace_v36')
    if section=='Inbox': _inbox(tasks)
    elif section=='Plan Appraisal': _plan(tasks)
    elif section=='Survey RFI': _survey(tasks)
    elif section=='Resource & SLA': _resources(projects)
    elif section=='Escalations': _escalations()
    elif section=='Project Control': _project_control(projects)
    elif section=='Governance': governance_v15.render_dm()
    elif section=='Notifications': _notifications()


def _is_overdue(t):
    due=t.get('due_at')
    if not due or t.get('status') in ('completed','returned'): return False
    try:
        from datetime import datetime
        return datetime.fromisoformat(due.replace('Z','+00:00')).replace(tzinfo=None) < datetime.utcnow()
    except Exception: return False


def _task_action(task):
    if task['status']=='pending':
        if st.button('Accept task',key=f"dm_accept_{task['id']}",type='primary'):
            if _safe(lambda:pq.secure_accept_task(task['id'])): st.rerun()
        return False
    if task['status']=='accepted':
        if st.button('Start task',key=f"dm_start_{task['id']}",type='primary'):
            if _safe(lambda:pq.secure_start_task(task['id'])): st.rerun()
    return True


def _inbox(tasks):
    if not tasks: st.success('No pending DM workflow tasks.'); return
    for t in tasks:
        with st.container(border=True):
            overdue=' · OVERDUE' if _is_overdue(t) else ''
            task_label=t.get('task_type','').replace('_',' ').title()
            branch='Plan Appraisal' if t.get('entity_type')=='plan_drawing' else (
                'Survey RFI' if t.get('entity_type')=='rfi' else 'Corrective Action'
            )
            st.markdown(f"**{task_label}** · `{branch}`{overdue}")
            st.caption(
                f"Project {t.get('project_id')} · created {t.get('created_at')} · "
                f"due {t.get('due_at') or '—'}"
            )
            st.write(t.get('note') or 'No task note.')
            _task_action(t)


def _plan(tasks):
    plan_tasks=[t for t in tasks if t.get('entity_type')=='plan_drawing']
    if not plan_tasks: st.info('No Plan Appraisal tasks in the DM inbox.'); return
    drawing_map=pq.plan_drawings_by_ids([t['entity_id'] for t in plan_tasks])
    obs_map=pq.plan_observations_by_drawing_ids(list(drawing_map))
    for task in plan_tasks:
        d=drawing_map.get(str(task['entity_id']))
        if not d: continue
        with st.container(border=True):
            st.markdown(f"### {d['drawing_no']} — {d['title']} · Rev {d.get('current_revision',d.get('revision',1))}")
            st.caption(f"{d['discipline']} · status {d['status']} · project {d['project_id']}")
            obs=obs_map.get(str(d['id']),[]); open_obs=[o for o in obs if o['status']=='open']
            if open_obs:
                st.warning(f"{len(open_obs)} open plan observation(s)")
                for o in open_obs:
                    st.write(f"• **{o['obs_code']}** · {o['severity']} — {o['description']} · response {o.get('response') or 'pending'}")

            if task['task_type'] in ('PLAN_APPRAISAL_MANAGER_HANDOVER','PLAN_APPRAISAL_REVISION_DM_REVIEW'):
                if not _task_action(task): continue
                assign_date=st.date_input('Target engineer completion date',value=date.today()+timedelta(days=5),key=f"dm_eng_date_{task['id']}")
                engineers=pq.project_eligible_v36(d['project_id'],'engineer',d['discipline'],date.today(),assign_date)
                if not engineers:
                    st.error('No engineer currently passes authorization + competency + availability/workload/conflict checks.'); continue
                eid=st.selectbox('Authorized engineer',[x['user_id'] for x in engineers],format_func=lambda x:next(e['full_name'] for e in engineers if e['user_id']==x),key=f"dm_eng_{task['id']}")
                e=next(x for x in engineers if x['user_id']==eid)
                st.caption(f"Authorization: {e['authorization_level']} · Workload: {e['workload_pct']}% · Open: {e.get('open_tasks',0)} · Overdue: {e.get('overdue_tasks',0)} · Overlaps: {e.get('overlapping_tasks',0)}")
                if st.button('Assign to Engineer →',key=f"dm_assign_eng_{task['id']}",type='primary'):
                    if _safe(lambda:pq.dm_assign_engineer_v36(d['id'],eid,assign_date)): st.rerun()

            elif task['task_type']=='PLAN_APPRAISAL_MANAGER_REVIEW':
                if not _task_action(task): continue
                decision=st.radio('DM technical review decision',['approved','changes_required','rejected_amended'],format_func=lambda x:{'approved':'Appraisal Approved','changes_required':'Appraisal Requires Changes','rejected_amended':'Design Rejected / Amended'}[x],key=f"dm_dec_{task['id']}")
                note=st.text_area('DM technical review / recommendation',key=f"dm_note_{task['id']}")
                if st.button('Apply DM decision →',key=f"dm_apply_{task['id']}",type='primary'):
                    if not note.strip(): st.error('A documented DM review note is required.')
                    elif _safe(lambda:pq.dm_review_plan(d['id'],decision,note)): st.rerun()

            elif task['task_type']=='PLAN_APPRAISAL_ENGINEER_FEEDBACK':
                st.info('Engineer feedback/rework task is visible for traceability. The Engineer must complete the technical re-review in the authenticated Engineer workspace.')

            elif task['task_type']=='PLAN_APPRAISAL_DESIGNER_RESPONSE':
                st.info('Designer correction is expected. The next revision must return to DM before engineer reallocation.')

            with st.expander('Revision register',expanded=False):
                for r in pq.plan_revisions(d['id']): st.write(f"Rev {r['revision_no']} · {r['status']} · {r['file_name']} · {r['submitted_at']}")


def _survey(tasks):
    survey_tasks=[t for t in tasks if t.get('entity_type')=='rfi']
    if not survey_tasks: st.info('No Survey RFI tasks in the DM inbox.'); return
    # v2.6: active survey drawing-revision impact control.
    try:
        active_rfis=pq.rfis(project_id=None)
        active_rfis=[r for r in active_rfis if r.get('assigned_dm_id')==pq.profile()['id'] and r.get('phase') in ('nsc_survey','in_service') and r.get('status') not in ('certificate_issued','closed')]
        if active_rfis:
            with st.expander('Drawing Revision Impact Monitor', expanded=True):
                for ar in active_rfis[:30]:
                    impacts=pq.drawing_revision_impact(ar['id'])
                    changed=[x for x in impacts if x.get('impact')=='REVISION_CHANGED']
                    if not changed: continue
                    st.error(f"{ar.get('rfi_code','RFI')} has {len(changed)} approved drawing revision change(s) requiring DM decision.")
                    for x in changed:
                        st.caption(f"{x.get('drawing_no','Drawing')} · shared Rev {x.get('shared_revision')} → current Rev {x.get('current_revision')} · {x.get('recommendation','Decision required')}")
    except Exception as exc:
        st.warning(f'Drawing revision impact monitor unavailable: {exc}')
    rfi_map=pq.rfis_by_ids([t['entity_id'] for t in survey_tasks])
    for task in survey_tasks:
        r=rfi_map.get(str(task['entity_id']))
        if not r: continue
        with st.container(border=True):
            st.markdown(f"### {r['rfi_code']} — {r['survey_type']}")
            st.caption(f"{r['priority'].upper()} priority · {r['status']} · scheduled {r.get('scheduled_date') or '—'}")
            if task['task_type'] in ('SURVEY_RFI_HANDOVER','FOLLOW_UP_RFI_DM_SCOPE_REVIEW'):
                if not _task_action(task): continue
                discipline='Machinery' if 'machinery' in r['survey_type'].lower() else ('Electrical' if 'electrical' in r['survey_type'].lower() else 'Hull & Structure')
                st.markdown(f"**Required specialization:** {discipline}")
                scheduled=st.date_input('Survey date',value=date.today()+timedelta(days=1),key=f"dm_date_{task['id']}")
                surveyors=pq.project_eligible_v36(r['project_id'],'surveyor',discipline,scheduled,scheduled)
                if not surveyors: st.error('No surveyor passes specialization + authorization + competency + availability/workload/conflict checks.'); continue
                sid=st.selectbox('Authorized surveyor',[x['user_id'] for x in surveyors],format_func=lambda x:next(s['full_name'] for s in surveyors if s['user_id']==x),key=f"dm_s_{task['id']}")
                s=next(x for x in surveyors if x['user_id']==sid)
                st.caption(f"Authorization: {s['authorization_level']} · Workload: {s['workload_pct']}% · Open: {s.get('open_tasks',0)} · Overdue: {s.get('overdue_tasks',0)} · Overlaps: {s.get('overlapping_tasks',0)}")
                if st.button('Assign to Authorized Surveyor →',key=f"dm_assign_s_{task['id']}",type='primary'):
                    if _safe(lambda:pq.dm_assign_surveyor_v36(r['id'],sid,scheduled)): st.rerun()

            elif task['task_type']=='SURVEY_DM_REVIEW':
                if not _task_action(task): continue
                reports=pq.survey_reports(r['id'])
                if reports: st.markdown(f"**Latest survey report:** {reports[0]['report_note']}")
                obs=pq.observations(r['id']); open_obs=[o for o in obs if o['status']=='open']
                if open_obs:
                    st.warning(
                        f"{len(open_obs)} open survey observation(s). "
                        "These remain OPEN during DM review and can only be verified after "
                        "GM send-back and controlled corrective action."
                    )
                    for o in open_obs:
                        st.write(
                            f"• **{o['obs_code']}** · {o['severity']} — {o['description']} · "
                            f"Rule: {o.get('rule_reference') or '—'} · "
                            f"Location: {o.get('location') or '—'}"
                        )
                    st.caption(
                        "DM review is a recommendation/forwarding step only. "
                        "Observation closure is deliberately unavailable here."
                    )
                remarks=st.text_area(
                    'DM survey review / recommendation',
                    key=f"dm_sr_{task['id']}",
                    help='Record the DM review conclusion. Do not close observations at this stage.'
                )
                if st.button('Forward survey report to GM →',key=f"dm_forward_{task['id']}",type='primary'):
                    if not remarks.strip(): st.error('DM review remarks are required.')
                    elif _safe(lambda:pq.dm_forward_survey(r['id'],remarks)): st.rerun()

            elif task['task_type']=='DM_CORRECTIVE_ACTION':
                if not _task_action(task): continue
                st.warning('GM returned this RFI for controlled corrective action.')
                assignees=[m.get('profiles') for m in pq.members(r['project_id']) if m.get('role') in ('surveyor','ship_management') and m.get('profiles')]
                if not assignees: st.error('No active Surveyor / Ship Management project members are available.'); continue
                actions=pq.corrective_actions(rfi_id=r['id'])
                action=next((a for a in actions if a['id']==task['entity_id']),None)
                observations=[o for o in pq.observations(r['id']) if o.get('status')=='open' and not o.get('corrective_action_id')]
                if not observations:
                    st.error('No unassigned open observations are available for this corrective action.')
                    continue
                obs_labels={o['id']:f"{o.get('obs_code','OBS')} · {o.get('severity','—')} · {o.get('description','')[:90]}" for o in observations}
                selected_obs=st.multiselect('Exact observations resolved by this corrective action',list(obs_labels),format_func=lambda x:obs_labels[x],key=f"ca_obs_{task['id']}")
                aid=st.selectbox('Corrective-action assignee',[u['id'] for u in assignees],format_func=lambda x:next(u['full_name'] for u in assignees if u['id']==x),key=f"ca_a_{task['id']}")
                instruction=st.text_area('Corrective action instruction',value=task.get('note') or '',key=f"ca_i_{task['id']}")
                due=st.date_input('Due date',value=date.today()+timedelta(days=3),key=f"ca_d_{task['id']}")
                st.caption('Only the observations explicitly selected above will be linked. Other open observations remain independent.')
                if st.button('Issue corrective-action task →',key=f"ca_issue_{task['id']}",type='primary'):
                    if not selected_obs:
                        st.error('Select at least one exact observation.')
                    elif action and _safe(lambda:pq.dm_issue_corrective(action['id'],aid,instruction,due,selected_obs)): st.rerun()

            elif task['task_type']=='DM_CORRECTIVE_ACTION_VERIFY':
                if not _task_action(task): continue
                actions=pq.corrective_actions(rfi_id=r['id'])
                action=next((a for a in actions if a['status']=='submitted'),None)
                if action:
                    linked=[o for o in pq.observations(r['id']) if o.get('corrective_action_id')==action['id'] and o.get('status')=='open']
                    st.success(
                        f"Controlled evidence submitted. {len(linked)} linked observation(s) "
                        "will be cleared by the verification transaction."
                    )
                    st.write(f"Evidence: {action.get('evidence_path') or '—'}")
                    verify_note=st.text_area(
                        'DM verification note',
                        value='Corrective action evidence verified; linked observations cleared; follow-up RFI created.',
                        key=f"dm_verify_note_{task['id']}"
                    )
                    if st.button(
                        'Verify corrective action, clear linked observations & create Follow-up RFI →',
                        key=f"verify_ca_{task['id']}",
                        type='primary'
                    ):
                        if not verify_note.strip():
                            st.error('Verification note is required.')
                        elif _safe(lambda:pq.dm_verify_corrective(action['id'],verify_note)):
                            st.rerun()

            elif task['task_type']=='DM_GM_FINAL_APPROVAL_ACK':
                if not _task_action(task): continue
                note=st.text_area('DM acknowledgement',key=f"dm_ack_note_{task['id']}")
                if st.button('Acknowledge GM final approval',key=f"ack_{task['id']}"):
                    if _safe(lambda:pq.secure_complete_task(task['id'],note or 'GM final approval acknowledged by DM.')): st.rerun()


def _resources(projects):
    st.markdown('### Resource Capacity, Assignment Load & SLA')
    if not projects: st.info('No active projects.'); return
    labels={p['id']:f"{p['project_code']} — {p['name']}" for p in projects}
    pid=st.selectbox('Project',list(labels),format_func=lambda x:labels[x],key='dm_resource_project')
    p=next(x for x in projects if x['id']==pid)
    rows=pq.resource_workload(pid)
    with st.container(border=True):
        st.markdown(f"**{p['project_code']} — {p['name']}**")
        if not rows: st.caption('No internal resources are assigned.'); return
        for r in rows:
            cols=st.columns(7)
            cols[0].markdown(f"**{r['full_name']}**")
            cols[1].write(r['role'])
            cols[2].write(r.get('discipline') or '—')
            cols[3].metric('Workload',f"{r['workload_pct']}%")
            cols[4].metric('Capacity',f"{r['capacity_pct']}%")
            cols[5].metric('Open / overdue',f"{r['assigned_tasks']} / {r['overdue_tasks']}")
            cols[6].metric('Due 7d / conflicts',f"{r['due_7d']} / {r['same_due_date_conflicts']}")
        snap=pq.task_sla_snapshot(pid)
        st.caption(f"SLA snapshot: {len(snap['open'])} open · {len(snap['overdue'])} overdue · {len(snap['due_7d'])} due within 7 days")
        if snap['overdue']:
            st.error('Overdue workflow tasks detected. Escalate management attention with a documented recommendation.')
            reason=st.text_area('Delay / issue reason',key=f"dm_sla_reason_{pid}")
            rec=st.text_area('DM recommendation',key=f"dm_sla_rec_{pid}")
            severity=st.selectbox('Severity',['medium','high','critical'],index=1,key=f"dm_sla_sev_{pid}")
            if st.button('Escalate SLA breach to GM →',key=f"dm_sla_esc_{pid}",type='primary'):
                if not reason.strip() or not rec.strip():
                    st.error('Reason and recommendation are required.')
                elif _safe(lambda:pq.dm_escalate(p['id'],'project',p['id'],reason,rec,severity)):
                    st.rerun()


def _escalations():
    rows=pq.escalations(open_only=True)
    if not rows: st.success('No open escalations.'); return
    for e in rows:
        with st.container(border=True):
            st.markdown(f"**{e['severity'].upper()}** · {e['reason']}")
            st.write(f"Recommendation: {e['recommendation']}")
            st.caption(f"Status: {e['status']} · created {e['created_at']}")


def _project_control(projects):
    if not projects: st.info('No active projects.'); return
    labels={p['id']:f"{p['project_code']} · {p['name']}" for p in projects}
    pid=st.selectbox('Project control view',list(labels),format_func=lambda x:labels[x],key='dm_project_control')
    h=pq.project_health(pid)
    if h:
        c=st.columns(6); c[0].metric('Completion',f"{h['completion_pct']}%"); c[1].metric('Open tasks',h['open_tasks']); c[2].metric('Overdue',h['overdue_tasks']); c[3].metric('Plan obs',h['plan_open_observations']); c[4].metric('Survey obs',h['survey_open_observations']); c[5].metric('Escalations',h['open_escalations'])
    st.markdown('### Current project milestones')
    for m in pq.milestones(pid):
        cols=st.columns([3,1,1])
        cols[0].write(f"**{m['code']} — {m['title']}** · {m['status']} · due {m.get('due_date') or '—'}")
        if m.get('status') not in ('completed','cancelled') and (m.get('owner_id') == pq.profile()['id']):
            if cols[2].button('Complete',key=f"dm_ms_{m['id']}"):
                if _safe(lambda:pq.complete_milestone(m['id'],'Completed by DM from project control.')): st.rerun()


def _notifications():
    rows=pq.notifications()
    if st.button('Mark all as read',key='dm_mark_all'):
        _safe(pq.mark_all_notifications_read); st.rerun()
    for n in rows:
        with st.container(border=True):
            st.markdown(f"**{n['title']}**")
            st.write(n['body'])
            st.caption(f"{n.get('created_at')} · {n.get('severity','info').upper()}")
            if not n.get('read_at') and st.button('Mark read',key=f"dm_n_{n['id']}"):
                _safe(lambda:pq.mark_notification_read(n['id'])); st.rerun()
