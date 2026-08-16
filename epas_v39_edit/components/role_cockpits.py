"""EPAS v3.5 role-native decision cockpits.
Each role sees its own operational priorities rather than a generic admin summary.
"""
from __future__ import annotations
from datetime import date
import streamlit as st
from database import production_queries as pq
from components.stakeholder_cockpits_v36 import owner_fleet, ship_management_operations, shipyard_nsc_operations
# Detailed Survey Control pages use the cached pq.schedule_bundle_v36 compatibility binding.


def _safe(fn, context: str):
    try:
        return fn()
    except Exception as exc:
        ref = abs(hash(f"{context}:{type(exc).__name__}")) % 100000
        st.error(f"{context} could not be completed. Reference EPAS-{ref:05d}.")
        return None


def _summary() -> dict:
    return _safe(pq.role_dashboard_summary_v36, "Loading dashboard summary") or {}


def _metric_row(items: list[tuple[str, object, str]]):
    cols = st.columns(len(items))
    for col, (label, value, foot) in zip(cols, items):
        with col:
            st.markdown(f"<div class='kpi-card'><div class='kpi-label'>{label}</div><div class='kpi-value'>{value}</div><div class='kpi-foot'>{foot}</div></div>", unsafe_allow_html=True)


def _state_cards(current: str, blocker: str, next_action: str):
    a, b, c = st.columns(3)
    with a:
        st.markdown(f"<div class='epas-state-card epas-state-card--current'><div class='epas-state-label'>CURRENT STATE</div><div class='epas-state-title'>{current}</div><div class='epas-state-copy'>Authoritative workflow state for this role.</div></div>", unsafe_allow_html=True)
    with b:
        st.markdown(f"<div class='epas-state-card epas-state-card--warning'><div class='epas-state-label'>BLOCKER</div><div class='epas-state-title'>{blocker}</div><div class='epas-state-copy'>Resolve the dependency before the next controlled transition.</div></div>", unsafe_allow_html=True)
    with c:
        st.markdown(f"<div class='epas-state-card epas-state-card--action'><div class='epas-state-label'>NEXT ACTION</div><div class='epas-state-title'>{next_action}</div><div class='epas-state-copy'>Use the role workspace to execute the authorized action.</div></div>", unsafe_allow_html=True)


def _search(role: str):
    with st.expander('Authorized global search', expanded=False):
        q = st.text_input('Search project, vessel, RFI or certificate', placeholder='Enter at least 2 characters', key=f'v35_search_{role}')
        if q.strip():
            results = _safe(lambda: pq.global_search_v36(q, 25), 'Search') or []
            if not results:
                st.info('No authorized matches found.')
            for row in results:
                st.markdown(f"**{row.get('result_type','').title()}** · {row.get('title','—')}")
                st.caption(f"{row.get('subtitle','')} · {str(row.get('phase') or '').replace('_',' ').title()}")


def render(role: str):
    labels = {
        'gm': ('GM Command Center', 'Decisions · project health · governance · certificate gates'),
        'dm': ('DM Operations Center', 'Allocation · technical review · survey readiness · verification'),
        'engineer': ('Engineer Technical Cockpit', 'Appraisal package · technical decision · verification'),
        'surveyor': ('Surveyor Field Cockpit', 'Assignment · handover · readiness · execution · report'),
        'designer': ('Designer Submission Cockpit', 'Submission · revision · correction · release status'),
        'owner': ('Owner Fleet Cockpit', 'Fleet health · in-service cycles · certificates · next survey'),
        'ship_management': ('Ship Management Operations', 'In-service surveys · corrective action · evidence · due dates'),
        'shipyard': ('Shipyard NSC Cockpit', 'NSC requests · survey status · drawing/release tracking'),
    }
    title, subtitle = labels.get(role, ('EPAS Operations', 'Role-controlled workflow cockpit'))
    s = _summary()
    st.markdown(f"<div class='eyebrow'>PSB · EPAS v3.6.1</div><div class='page-title'>{title}</div>", unsafe_allow_html=True)
    st.caption(subtitle)

    if role == 'gm':
        _metric_row([
            ('Decisions awaiting me', s.get('pending_decisions', s.get('open_tasks', 0)), 'approval queue'),
            ('Overdue', s.get('overdue_tasks', 0), 'requires intervention'),
            ('Open certificates', s.get('open_certificates', 0), 'certificate gates'),
            ('Active projects', s.get('active_projects', 0), 'portfolio'),
        ])
        current='Command / Decision Focus'
        blocker='Overdue decisions require attention.' if s.get('overdue_tasks', 0) else 'No critical GM blocker detected.'
        next_action='Resolve the highest-priority approval, escalation or certificate gate.'
    elif role == 'dm':
        _metric_row([
            ('Assignments', s.get('open_tasks', 0), 'allocation / review'),
            ('Overdue', s.get('overdue_tasks', 0), 'allocation pressure'),
            ('Open actions', s.get('open_actions', 0), 'verification queue'),
            ('Active projects', s.get('active_projects', 0), 'portfolio'),
        ])
        current='Operations / Allocation Focus'
        blocker='Overdue work requires reallocation or escalation.' if s.get('overdue_tasks', 0) else 'No critical DM blocker detected.'
        next_action='Clear the highest-priority assignment, scope amendment, reissue or verification queue.'
    elif role == 'engineer':
        tasks = _safe(lambda: pq.tasks(statuses=['pending','accepted','in_progress'], task_types=['PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK']), 'Loading Engineer queue') or []
        _metric_row([('Appraisals', len(tasks), 'assigned'), ('Due soon', sum(1 for t in tasks if 'due' in str(t.get('priority','')).lower()), 'check queue'), ('Actions', s.get('open_actions', 0), 'technical observations'), ('Projects', s.get('active_projects', 0), 'active')])
        current='Technical appraisal queue'
        blocker='No assigned appraisal task.' if not tasks else 'A technical appraisal or feedback item is awaiting action.'
        next_action='Open the oldest assigned appraisal and complete the controlled review package.'
    elif role == 'surveyor':
        tasks = _safe(lambda: pq.tasks(statuses=['pending','accepted','in_progress'], task_types=['SURVEY_EXECUTION','CORRECTIVE_ACTION_EXECUTION']), 'Loading Surveyor queue') or []
        _metric_row([('Surveys', sum(1 for t in tasks if t.get('task_type')=='SURVEY_EXECUTION'), 'assigned'), ('Readiness', 'Gate' if tasks else '—', 'scope / drawing / checklist'), ('Actions', sum(1 for t in tasks if t.get('task_type')=='CORRECTIVE_ACTION_EXECUTION'), 'assigned'), ('Overdue', s.get('overdue_tasks',0), 'field queue')])
        current='Survey readiness / execution'
        blocker='No accepted survey assignment.' if not tasks else 'Clear the next survey readiness gate.'
        next_action='Accept the assignment, acknowledge the scope/drawing package, complete the checklist, then start the survey.'
    elif role == 'designer':
        _metric_row([('Open tasks', s.get('open_tasks', 0), 'submission actions'), ('Overdue', s.get('overdue_tasks', 0), 'correction due'), ('Revisions', s.get('open_actions', 0), 'action required'), ('Projects', s.get('active_projects',0), 'active')])
        current='Submission / Revision queue'
        blocker='A correction or revision may be awaiting action.' if s.get('open_tasks',0) else 'No active correction blocker detected.'
        next_action='Open the submission tracker and address the oldest action required.'
    elif role == 'owner':
        due = int(s.get('schedule_due', 0))
        overdue = int(s.get('schedule_overdue', 0))
        _metric_row([('Fleet', s.get('active_projects',0), 'active projects'), ('Due', due, 'action required'), ('Overdue', overdue, 'urgent'), ('Open tasks', s.get('open_tasks',0), 'stakeholder actions')])
        current='Fleet / In-Service readiness'
        blocker='One or more survey cycles are due/overdue.' if due else 'No immediate In-Service blocker.'
        next_action='Open the due cycle and initiate the prefilled In-Service RFI when the schedule is configured.' if due else 'Monitor upcoming windows and certificate status.'
    elif role == 'ship_management':
        due = int(s.get('schedule_due', 0))
        _metric_row([('In-Service due', due, 'action required'), ('Open actions', s.get('open_actions',0), 'corrective action'), ('Overdue', s.get('overdue_tasks',0), 'urgent'), ('Fleet', s.get('active_projects',0), 'active projects')])
        current='In-Service operations'
        blocker='Corrective actions or survey cycles require attention.' if (due or s.get('open_actions',0)) else 'No immediate operational blocker.'
        next_action='Open the due cycle or highest-priority corrective action and submit controlled evidence.'
    elif role == 'shipyard':
        due = int(s.get('schedule_due', 0))
        _metric_row([('NSC projects', s.get('active_projects',0), 'visible portfolio'), ('Due', due, 'survey action'), ('Open actions', s.get('open_actions',0), 'released action'), ('Overdue', s.get('overdue_tasks',0), 'urgent')])
        current='NSC coordination'
        blocker='NSC survey action is due/overdue.' if due else 'No active NSC blocker.'
        next_action='Initiate an NSC Survey RFI only when the project phase is eligible.'
    else:
        current='Operations'; blocker='No major blocker detected.'; next_action='Review the highest-priority authorized queue.'

    _state_cards(current, blocker, next_action)
    _search(role)

    if role == 'owner':
        owner_fleet()
    elif role == 'ship_management':
        ship_management_operations()
    elif role == 'shipyard':
        shipyard_nsc_operations()

    if role == 'gm':
        with st.expander('GM decision discipline', expanded=False):
            st.write('Prioritize approvals, escalations, certificate gates and closure readiness before routine monitoring.')
    elif role == 'dm':
        with st.expander('DM orchestration discipline', expanded=False):
            st.write('Keep assignment, scope, drawing-package, survey-readiness and verification dependencies visible as one chain.')
    elif role == 'surveyor':
        with st.expander('Survey readiness chain', expanded=False):
            st.write('Assignment accepted → scope acknowledged → drawing package acknowledged → checklist complete → revision impact clear → execute.')
    elif role == 'owner':
        with st.expander('Owner boundary', expanded=False):
            st.write('Owner initiates In-Service surveys only and sees stakeholder-safe fleet, certificate and survey status.')
    elif role == 'ship_management':
        with st.expander('Ship Management boundary', expanded=False):
            st.write('Ship Management initiates In-Service surveys and manages only its assigned corrective actions/evidence.')
    elif role == 'shipyard':
        with st.expander('Shipyard boundary', expanded=False):
            st.write('Shipyard initiates NSC Survey RFIs only. In-Service schedules and internal appraisal detail remain outside the Shipyard boundary.')
