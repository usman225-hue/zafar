"""EPAS v3.6 professional operations center: SLA, work queue, governance and security assurance."""
from __future__ import annotations
import streamlit as st
from datetime import date
from database import production_queries as pq


def _safe(fn, context: str = "Workflow operation"):
    try:
        return fn()
    except Exception as exc:
        ref = abs(hash(f"{context}:{type(exc).__name__}")) % 100000
        st.error(f"{context} could not be completed. Reference EPAS-{ref:05d}.")
        return None


def render_role_header():
    s = _safe(pq.role_dashboard_summary_v36) or {}
    c = st.columns(6)
    c[0].metric('Open Tasks', s.get('open_tasks', 0))
    c[1].metric('Overdue', s.get('overdue_tasks', 0))
    c[2].metric('Unread', s.get('unread_notifications', 0))
    c[3].metric('Active Projects', s.get('active_projects', 0))
    c[4].metric('Open Actions', s.get('open_actions', 0))
    c[5].metric('My RFIs', s.get('initiated_rfis', 0))


def render_work_queue():
    st.markdown('#### My professional work queue')
    rows = _safe(pq.my_work_queue) or []
    if not rows:
        st.success('No outstanding workflow tasks.')
        return
    for r in rows[:100]:
        state = str(r.get('sla_state') or 'ON_TRACK')
        badge = '🔴' if state in ('BREACHED','OVERDUE') else ('🟠' if state=='DUE_SOON' else '🟢')
        st.markdown(f"{badge} **{r.get('task_type','Task')}** · {str(r.get('status','')).replace('_',' ').title()} · {state}")
        st.caption(f"Project {r.get('project_id')} · due {r.get('sla_due_at') or r.get('due_at') or '—'} · {r.get('note') or ''}")


def render_sla(project_id: str | None = None):
    st.markdown('#### SLA control tower')
    _safe(pq.refresh_task_sla)
    rows = _safe(lambda: pq.sla_dashboard(project_id)) or []
    if not rows:
        st.success('No open SLA-controlled tasks.')
        return
    counts = {k: sum(1 for r in rows if r.get('sla_state')==k) for k in ['ON_TRACK','DUE_SOON','OVERDUE','BREACHED']}
    c=st.columns(4)
    for col,k in zip(c,counts): col.metric(k.replace('_',' ').title(),counts[k])
    for r in rows[:100]:
        st.write(f"**{r.get('task_type')}** · {r.get('assignee_name') or 'Unassigned'} · {r.get('sla_state')} · due {r.get('sla_due_at') or r.get('due_at') or '—'}")


def render_governance(project_id: str):
    st.markdown('#### Integrated risk / decision register')
    rows = _safe(lambda: pq.governance_register(project_id)) or []
    if not rows:
        st.info('No risk/decision records are currently linked.')
        return
    for r in rows[:100]:
        st.write(f"**{r.get('risk_code') or 'Risk'}** · {r.get('risk_title') or '—'} · {r.get('risk_status') or '—'} · decision {r.get('decision_code') or '—'}")


def render_lifecycle(project_id: str | None = None):
    st.markdown('#### Survey lifecycle & Ship Register control tower')
    st.caption('State → blocker → next action. In-Service is a persistent phase; cycles repeat without closing the project phase.')
    try:
        role=pq.profile().get('role')
    except Exception:
        role=None
    if role in ('gm','dm'):
        st.caption('Survey schedules and due notifications are synchronized by the service-role lifecycle scheduler; this page is read/control scoped.')
    if project_id:
        rows = _safe(lambda: pq.schedule_bundle_v36(project_id)) or []
    else:
        rows = _safe(lambda: pq.schedule_bundle_v36(None)) or []
    if rows:
        for r in rows[:50]:
            state = r.get('status','SCHEDULED')
            icon = '🔴' if state=='OVERDUE' else ('🟠' if state in ('DUE','DUE_SOON') else '🟢')
            st.write(f"{icon} **{r.get('vessel_name','Vessel')}** · {str(r.get('phase','')).replace('_',' ').title()} · {r.get('survey_type','Survey')} · due {r.get('next_due_date')} · {state}")
    else:
        st.info('No active recurring survey schedules are currently available.')
    if project_id:
        with st.expander('Project lifecycle timeline', expanded=False):
            events = _safe(lambda: pq.coordination_timeline_v36(project_id, 100)) or []
            for e in events:
                st.caption(f"{e.get('created_at','')} · {e.get('event_type','')} · {e.get('entity_type','')} · {e.get('note') or ''}")



def render_survey_control(project_id: str | None = None):
    st.markdown('#### Survey Control — Assignment / Handover / Recurring Cycle')
    rows = _safe(lambda: pq.schedule_bundle_v36(project_id)) or []
    if not rows:
        st.info('No active survey schedules are currently available.')
        return
    for r in rows[:100]:
        state = r.get('status', 'SCHEDULED')
        icon = '🔴' if state == 'OVERDUE' else ('🟠' if state in ('DUE','DUE_SOON') else '🟢')
        st.markdown(f"{icon} **{r.get('vessel_name','Vessel')}** · {str(r.get('phase','')).replace('_',' ').title()} · {r.get('survey_type','Survey')} · cycle {r.get('cycle_number',1)}")
        st.caption(f"Due {r.get('next_due_date')} · window {r.get('window_start')} → {r.get('window_end')} · {state} · RFI {r.get('rfi_code') or '—'} · Surveyor {r.get('surveyor_name') or '—'}")
        try:
            role=pq.profile().get('role')
            if role in ('gm','dm') and r.get('phase')=='in_service':
                with st.expander('Configure In-Service survey schedule basis', expanded=False):
                    interval=st.number_input('Survey interval (months)', min_value=1, max_value=120, value=int(r.get('survey_interval_months') or 1), key=f"sched_int_{r['schedule_id']}")
                    basis=st.selectbox('Schedule basis',['CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED'], index=['CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED'].index(r.get('due_basis') or 'CERTIFICATE_EXPIRY'), key=f"sched_basis_{r['schedule_id']}")
                    reference=st.text_input('Basis reference',value=r.get('due_basis_reference') or '',key=f"sched_ref_{r['schedule_id']}")
                    basis_date=st.date_input('Schedule basis date',value=(r.get('due_basis_date') or date.today()),key=f"sched_basis_date_{r['schedule_id']}")
                    before=st.number_input('Window before due (days)',min_value=1,max_value=365,value=90,key=f"sched_before_{r['schedule_id']}")
                    after=st.number_input('Window after due (days)',min_value=1,max_value=365,value=30,key=f"sched_after_{r['schedule_id']}")
                    if st.button('Save controlled schedule basis →',key=f"sched_save_{r['schedule_id']}",type='primary'):
                        if not reference.strip():
                            st.error('Schedule basis reference is mandatory.')
                        elif _safe(lambda:pq.set_in_service_schedule_basis_v36(str(r['vessel_id']),int(interval),basis,reference,basis_date,int(before),int(after))):
                            st.success('Schedule basis updated and audit recorded.'); st.rerun()
        except Exception as exc:
            st.warning(f'Schedule configuration unavailable: {exc}')

def render_phase_and_coordination(project_id: str | None = None):
    st.markdown("#### Project phase & coordination")
    if not project_id:
        st.info("Select a project to view Plan → NSC → In-Service phase status and role handoffs.")
        return
    state = _safe(lambda: pq.project_phase_workflow_v36(project_id), "Project phase workflow") or {}
    c=st.columns(3)
    c[0].metric("Plan", str(state.get("plan","—")).replace("_"," ").title())
    c[1].metric("NSC", str(state.get("nsc","—")).replace("_"," ").title())
    c[2].metric("In-Service", str(state.get("in_service","—")).replace("_"," ").title())
    ev = _safe(lambda: pq.coordination_timeline_v36(project_id, 100), "Coordination timeline") or []
    if ev:
        st.markdown("##### Cross-role handoffs")
        for e in ev[:50]:
            st.markdown(f"**{e.get('occurred_at','')}** · {e.get('actor_role','system').replace('_',' ').title()} → {e.get('event_type','').replace('_',' ').title()} · {e.get('summary','—')}")
            st.caption(f"Phase: {str(e.get('phase','—')).replace('_',' ').title()} · visibility: {e.get('visibility','—')}")
    else:
        st.info("No authorized workflow events are available for this project.")


def render_security():
    st.markdown('#### Security assurance preflight')
    rows = _safe(pq.security_preflight) or []
    if not rows:
        st.warning('Security preflight unavailable until the v2.0 migration is applied.')
        return
    for r in rows:
        if r.get('passed'): st.success(f"{r.get('check_code')}: {r.get('details')}")
        else: st.error(f"{r.get('check_code')}: {r.get('details')}")


def render(project_id: str | None = None, include_security: bool = False):
    with st.expander('Professional Operations Center', expanded=False):
        render_role_header()
        tab_names = ['Work Queue','SLA','Governance','Lifecycle','Phase & Coordination','Survey Control']
        if include_security: tab_names.append('Security')
        selected = st.radio('OPERATIONS CENTER', tab_names, horizontal=True, key='professional_center_v36')
        if selected == 'Work Queue': render_work_queue()
        elif selected == 'SLA': render_sla(project_id)
        elif selected == 'Governance':
            if project_id: render_governance(project_id)
            else: st.info('Select a project to view integrated governance records.')
        elif selected == 'Lifecycle': render_lifecycle(project_id)
        elif selected == 'Phase & Coordination': render_phase_and_coordination(project_id)
        elif selected == 'Survey Control': render_survey_control(project_id)
        elif selected == 'Security': render_security()
