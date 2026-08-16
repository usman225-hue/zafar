"""EPAS v1.5 governance and closure controls.
High-assurance GM/DM controls for document release, certificate lifecycle,
project closure, SLA/resource review, and audit evidence.
"""
from __future__ import annotations
from datetime import date, timedelta
import streamlit as st
from database import production_queries as pq

STAKEHOLDER_AUDIENCES = [
    ("designer", "Designer"),
    ("owner", "Owner"),
    ("ship_management", "Ship Management"),
    ("shipyard", "Shipyard"),
]

def _safe(fn):
    try:
        return fn()
    except Exception as exc:
        st.error(str(exc))
        return None

def render_gm():
    projects = pq.projects("active")
    st.markdown("### Governance & Closure Control")
    if not projects:
        st.info("No active projects under GM control.")
        return
    labels = {p["id"]: f"{p['project_code']} · {p['name']}" for p in projects}
    pid = st.selectbox("Project", list(labels), format_func=lambda x: labels[x], key="v15_gm_project")
    p = pq.project(pid)
    health = pq.project_health_v36(pid)
    if health:
        c=st.columns(7)
        c[0].metric("Completion", f"{health['completion_pct']}%")
        c[1].metric("Plan", f"{health['plan_completion_pct']}%")
        c[2].metric("Survey", f"{health['survey_completion_pct']}%")
        c[3].metric("Open tasks", health["open_tasks"])
        c[4].metric("Overdue", health["overdue_tasks"])
        c[5].metric("Escalations", health["open_escalations"])
        c[6].metric("Closure ready", "YES" if health["closure_ready"] else "NO")

    tabs=st.tabs(["Released Documents","Stakeholder Milestones","Certificate Lifecycle","Closure Checklist","Escalation Actions","Audit Access"])
    with tabs[0]:
        st.markdown("#### Controlled stakeholder release")
        docs=pq.released_documents(pid, stakeholder_only=False)
        if not docs:
            st.info("No project documents available.")
        for d in docs:
            with st.container(border=True):
                st.write(f"**{d['file_name']}** · {d.get('category','—')} · v{d.get('version',1)} · {d.get('release_status','internal')}")
                c1,c2=st.columns([3,1])
                selected=c1.multiselect(
                    "Release audience",
                    [x[0] for x in STAKEHOLDER_AUDIENCES],
                    format_func=lambda v: dict(STAKEHOLDER_AUDIENCES)[v],
                    key=f"rel_aud_{d['id']}",
                    default=[],
                )
                note=c1.text_input("Release note",key=f"rel_note_{d['id']}")
                if c2.button("Release →",key=f"release_{d['id']}",type="primary",disabled=not selected):
                    if _safe(lambda:pq.release_document(d["id"],selected,note)): st.rerun()
                if d.get("release_status")=="released":
                    st.success("Released for stakeholder viewing")
                    if c2.button("Withdraw",key=f"withdraw_{d['id']}"):
                        if _safe(lambda:pq.withdraw_document_release(d["id"],note or "Release withdrawn by GM.")): st.rerun()
                    with st.expander("Release history"):
                        for r in pq.document_releases(d["id"]):
                            st.write(f"{r['audience_role']} · {r['status']} · {r['released_at']} · {r.get('release_note') or ''}")
    with tabs[1]:
        st.markdown("#### Controlled milestone release")
        st.caption("Only milestones explicitly released by GM/DM become visible to Owner/Shipyard and other external stakeholders.")
        for m in pq.milestones(pid):
            c1,c2,c3,c4=st.columns([2,2,2,1])
            c1.markdown(f"**{m.get('code','—')} · {m.get('title','—')}**")
            c2.write(f"Status: {m.get('status','—')}")
            c3.write(f"Due: {m.get('due_date') or '—'}")
            if m.get("stakeholder_visible"):
                c4.success("Released")
            else:
                if c4.button("Release",key=f"mil_release_{m['id']}"):
                    note=st.session_state.get(f"mil_note_{m['id']}","Released for stakeholder viewing.")
                    if _safe(lambda:pq.release_milestone(m["id"],note)): st.rerun()
                st.text_input("Release note",value="Released for stakeholder viewing.",key=f"mil_note_{m['id']}")
    with tabs[2]:
        st.markdown("#### Interim → Final certificate control")
        certs=pq.certificates(pid)
        if not certs:
            st.info("No certificates issued.")
        for c in certs:
            st.write(f"**{c['cert_number']}** · {c['cert_type']} · {c['status']} · valid to {c['expiry_date']}")
            if c["cert_type"]=="interim_certificate" and c["status"]=="active":
                open_obs=sum(1 for o in pq.observations(c["rfi_id"]) if o["status"]=="open")
                st.caption(f"Open survey observations: {open_obs}")
                if open_obs==0:
                    note=st.text_input("Finalization note",key=f"final_note_{c['id']}")
                    months=st.number_input("Final certificate validity (months)",min_value=1,max_value=60,value=12,key=f"final_m_{c['id']}")
                    if st.button("Finalize Interim → Full Class Certificate",key=f"finalize_{c['id']}",type="primary"):
                        if not note.strip(): st.error("Finalization note is required.")
                        elif _safe(lambda:pq.finalize_interim_certificate(c["id"],months,note)): st.rerun()
    with tabs[3]:
        st.markdown("#### Project closure checklist")
        checks=pq.project_closure_check(pid)
        all_ok=True
        for ch in checks:
            all_ok = all_ok and bool(ch["passed"])
            st.write(("✅" if ch["passed"] else "❌")+f" **{ch['check_title']}** — {ch['details']}")
        if all_ok:
            note=st.text_area("Closure note",key=f"close_note_{pid}")
            if st.button("Close & Archive Project",key=f"close_project_{pid}",type="primary"):
                if not note.strip(): st.error("Closure note is mandatory.")
                elif _safe(lambda:pq.close_project(pid,note)): st.rerun()
        else:
            st.warning("Project cannot be closed until every closure gate passes.")
    with tabs[4]:
        rows=pq.escalations(pid,open_only=True)
        if not rows: st.success("No open escalations.")
        for e in rows:
            st.write(f"**{e['severity'].upper()}** · {e['reason']} · {e['status']}")
            note=st.text_area("GM action note",key=f"gmv15_esc_note_{e['id']}")
            members=[m.get("profiles") for m in pq.members(pid) if m.get("profiles") and m["profiles"]["role"] in ("dm","engineer","surveyor","ship_management")]
            owner=None
            due=None
            if members:
                owner=st.selectbox("Action owner",[m["id"] for m in members],format_func=lambda x:next(m["full_name"] for m in members if m["id"]==x),key=f"owner_{e['id']}")
                due=st.date_input("Action due date",value=date.today()+timedelta(days=3),key=f"due_{e['id']}")
            c1,c2,c3=st.columns(3)
            if c1.button("Acknowledge",key=f"gmv15_ack_{e['id']}"):
                if _safe(lambda:pq.gm_escalation_decide_v36(e["id"],"acknowledge",note)): st.rerun()
            if c2.button("Return to DM",key=f"gmv15_ret_{e['id']}"):
                if not note.strip(): st.error("Return reason is required.")
                elif _safe(lambda:pq.gm_escalation_decide_v36(e["id"],"return_to_dm",note)): st.rerun()
            if c3.button("Assign action",key=f"gmv15_act_{e['id']}",type="primary"):
                if not members:
                    st.error("No project member is eligible to own this action.")
                elif not note.strip():
                    st.error("Action note is required.")
                elif _safe(lambda:pq.gm_escalation_decide_v36(e["id"],"assign_action",note,owner,due.isoformat()+"T17:00:00+00:00")):
                    st.rerun()
    with tabs[5]:
        rows=pq.document_access_log(project_id=pid,limit=200)
        st.markdown("#### Document access / release audit")
        if not rows:
            st.info("No document access events recorded.")
        for a in rows:
            st.write(f"{a['created_at']} · **{a['actor_role']}** · {a['action']} · document {a['document_id']}")

def render_dm():
    st.markdown("### Resource / SLA Assurance")
    projects=pq.projects("active")
    if not projects:
        st.info("No active projects.")
        return
    for p in projects:
        rows=pq.resource_workload(p["id"])
        st.markdown(f"#### {p['project_code']} · {p['name']}")
        if rows:
            for r in rows:
                cols=st.columns(8)
                cols[0].write(f"**{r['full_name']}**")
                cols[1].write(r["role"])
                cols[2].write(r.get("discipline") or "—")
                cols[3].metric("Load",f"{r['workload_pct']}%")
                cols[4].metric("Capacity",f"{r['capacity_pct']}%")
                cols[5].metric("Open",r["assigned_tasks"])
                cols[6].metric("Overdue",r["overdue_tasks"])
                cols[7].metric("Overlaps",r.get("overlapping_tasks",0))
                st.caption(f"Capacity {r.get('capacity_hours',0)}h · Assigned {r.get('assigned_hours',0)}h · Utilization {r.get('utilization_pct',0)}%")
                if r.get("overdue_tasks",0)>0 or r.get("overlapping_tasks",0)>2:
                    st.warning(f"{r['full_name']} requires workload/SLA attention.")
        snap=pq.task_sla_snapshot(p["id"])
        st.caption(f"{len(snap['open'])} open · {len(snap['overdue'])} overdue · {len(snap['due_7d'])} due within 7 days")
        if snap["overdue"]:
            st.error("SLA breach detected. Use the Escalation tab to create a documented GM recommendation.")
