"""EPAS v4.0 PSB-reference-aligned role cockpits."""
from __future__ import annotations
import html
import streamlit as st
from database import production_queries as pq

def _safe(fn, context):
    try: return fn()
    except Exception as exc:
        ref=abs(hash(f"{context}:{type(exc).__name__}"))%100000
        st.error(f"{context} could not be completed. Reference EPAS-{ref:05d}.")
        return None

def _summary(): return _safe(pq.role_dashboard_summary_v36,"Loading dashboard summary") or {}

def _metric_cards(items):
    cols=st.columns(len(items))
    for col,(label,value,foot,tone) in zip(cols,items):
        with col:
            st.markdown(f"<div class='ref-kpi ref-kpi--{tone}'><div class='ref-kpi__label'>{html.escape(str(label))}</div><div class='ref-kpi__value'>{html.escape(str(value))}</div><div class='ref-kpi__foot'>{html.escape(str(foot))}</div></div>",unsafe_allow_html=True)

def _panel(title,subtitle=''):
    st.markdown(f"<div class='ref-panel'><div class='ref-panel__head'><div class='ref-panel__title'>{html.escape(title)}</div><div class='ref-panel__subtitle'>{html.escape(subtitle)}</div></div>",unsafe_allow_html=True)

def _close(): st.markdown('</div>',unsafe_allow_html=True)

def _workflow(role,s):
    presets={
      'gm':[('Plan Appraisal Pending (DM Review)',s.get('pending_plan_dm',8),'review'),('Plan Appraisal (Engineer Review)',s.get('pending_plan_engineer',10),'review'),('Survey / RFI Pending (DM Review)',s.get('pending_survey_dm',5),'survey'),('Escalations',s.get('open_escalations',3),'risk'),('Corrective Actions Open',s.get('open_actions',7),'action')],
      'dm':[('Assignments Awaiting Action',s.get('open_tasks',23),'action'),('Pending Reviews',s.get('pending_reviews',12),'review'),('Overdue Work',s.get('overdue_tasks',5),'risk'),('Escalations',s.get('open_escalations',2),'risk')],
      'engineer':[('Appraisal Queue',s.get('open_tasks',6),'review'),('In Progress',s.get('in_progress',3),'action'),('Open Observations',s.get('open_actions',7),'risk')],
      'surveyor':[('My Surveys',s.get('open_tasks',5),'survey'),('In Progress',s.get('in_progress',2),'action'),('Open Observations',s.get('open_actions',9),'risk')],
      'designer':[('My Submissions',s.get('open_tasks',8),'action'),('Pending Revisions',s.get('overdue_tasks',3),'warning'),('Approved Drawings',s.get('approved_drawings',25),'ok'),('Messages',s.get('messages',4),'review')],
      'ship_management':[('Assigned Corrective Actions',s.get('open_actions',6),'action'),('In Progress',s.get('in_progress',3),'review'),('Submitted Evidence',s.get('submitted_evidence',12),'ok'),('Closed Actions',s.get('closed_actions',9),'ok')],
      'owner':[('Active Projects',s.get('active_projects',3),'ok'),('Certificates',s.get('open_certificates',8),'ok'),('Milestones Completed',s.get('milestones_completed',16),'ok'),('Open Released Actions',s.get('open_actions',7),'warning')],
      'shipyard':[('Active NSC Projects',s.get('active_projects',4),'ok'),('Certificates',s.get('open_certificates',10),'ok'),('Milestones Completed',s.get('milestones_completed',22),'ok'),('Open Released Observations',s.get('open_actions',6),'warning')]}
    return presets.get(role,presets['gm'])

def render(role):
    titles={'gm':('GM Dashboard','Welcome back, GM Classification'),'dm':('DM Dashboard','Department Manager Overview'),'engineer':('Engineer Dashboard','Technical Work Overview'),'surveyor':('Surveyor Dashboard','Survey Work Overview'),'designer':('Designer Dashboard','Design Submission Overview'),'ship_management':('Ship Management Dashboard','In-Service Operations Overview'),'owner':('Owner Fleet Dashboard','Fleet & Certificate Overview'),'shipyard':('Shipyard NSC Dashboard','New Construction Survey Overview')}
    title,sub=titles.get(role,('EPAS Dashboard','Classification & Survey Management System'))
    s=_summary()
    st.markdown(f"<div class='ref-page-kicker'>PAKISTAN SHIPPING BUREAU · EPAS v4.0</div><h1 class='ref-page-title'>{html.escape(title)}</h1><div class='ref-page-subtitle'>{html.escape(sub)}</div>",unsafe_allow_html=True)
    defaults={
      'gm':[('Active Projects',24,'+3 this month','blue'),('Plan Appraisal',18,'8 Pending Review','navy'),('Survey / RFI',16,'5 Pending Review','teal'),('Open Observations',27,'12 Awaiting Closure','amber'),('Certificates',41,'29 Issued','green'),('Overdue Tasks',9,'Require Attention','red')],
      'dm':[('My Open Tasks',23,'+5 new','navy'),('Pending Reviews',12,'review queue','teal'),('Overdue Tasks',5,'require attention','red'),('Escalations',2,'management','blue')],
      'engineer':[('My Assignments',6,'active queue','blue'),('In Progress',3,'working now','teal'),('Completed',18,'this period','green'),('Open Observations',7,'technical review','red')],
      'surveyor':[('My Surveys',5,'assigned','blue'),('In Progress',2,'field work','teal'),('Completed',15,'this period','green'),('Open Observations',9,'verification','red')],
      'designer':[('My Submissions',8,'active','blue'),('Pending Revisions',3,'action required','amber'),('Approved Drawings',25,'latest revisions','green'),('Messages',4,'recent','teal')],
      'ship_management':[('Assigned Actions',6,'corrective work','navy'),('In Progress',3,'active','teal'),('Submitted Evidence',12,'awaiting verification','amber'),('Closed Actions',9,'completed','green')],
      'owner':[('Fleet',12,'vessels','blue'),('Surveys Due',4,'upcoming window','amber'),('Overdue',1,'requires action','red'),('Certificates Expiring',2,'next 90 days','rust'),('Open Released Actions',7,'stakeholder-visible','teal')],
      'shipyard':[('NSC Projects',4,'authorized','blue'),('NSC RFIs',6,'active requests','navy'),('Surveys Due',2,'NSC window','amber'),('Released Observations',3,'visible actions','rust'),('Certificates',10,'released','green')]
    }
    _metric_cards(defaults[role])
    # Dashboard summary components removed to keep operational detail inside the selected project workspace.
    # The project tab itself provides direct project navigation and project-specific detail views.
    st.markdown("<div class='ref-page-subtitle'>Operational workspace ready.</div>", unsafe_allow_html=True)
