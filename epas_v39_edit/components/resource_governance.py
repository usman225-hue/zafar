"""EPAS Authorization, Competency & Availability Center."""
from __future__ import annotations
import streamlit as st
from config import settings as cfg
from database import production_queries as q
from database import upgrade_queries as uq


def render() -> None:
    st.markdown('<div class="eyebrow">Governance</div><div class="page-title">Authorization & Resource Control</div>', unsafe_allow_html=True)
    st.caption("Only personnel who are authorized, competent and available are eligible for assignment.")
    users = q.list_users(role=cfg.ROLE_ENGINEER) + q.list_users(role=cfg.ROLE_SURVEYOR)
    for u in users:
        with st.container(border=True):
            st.markdown(f'**{u["full_name"]}** · {cfg.ROLE_LABELS[u["role"]]}')
            disciplines = uq.user_disciplines(u["id"])
            if not disciplines:
                st.warning("No active discipline authorization.")
                continue
            cols = st.columns(min(4, len(disciplines)))
            for col, disc in zip(cols, disciplines):
                check = uq.engineer_eligibility(u["id"], disc) if u["role"] == cfg.ROLE_ENGINEER else uq.surveyor_eligibility(u["id"], disc)
                with col:
                    st.markdown(f'**{disc}**')
                    st.success("Eligible") if check["eligible"] else st.error("Not eligible")
                    st.caption(" · ".join(check["reasons"]))

    render_allocation_matrix()


def render_allocation_matrix() -> None:
    """Professional allocation view: eligibility + workload + date availability."""
    st.markdown('<div class="section-title">Assignment Matrix</div>', unsafe_allow_html=True)
    projects = q.list_projects(status="active")
    if not projects:
        st.info("No active projects available.")
        return
    labels = {p["id"]: f"{p.get('project_code','—')} · {p.get('name','—')}" for p in projects}
    pid = st.selectbox("Project", list(labels), format_func=lambda x: labels[x], key="resource_matrix_project")
    role = st.selectbox("Resource role", [cfg.ROLE_ENGINEER, cfg.ROLE_SURVEYOR], key="resource_matrix_role")
    discipline = st.selectbox("Discipline", ["Hull & Structure", "Machinery", "Electrical", "Stability", "Safety Equipment", "Fire & LSA"], key="resource_matrix_disc")
    work_date = st.date_input("Planned work date", key="resource_matrix_date")
    try:
        rows = __import__('database.production_queries', fromlist=['resource_allocation_matrix']).resource_allocation_matrix(pid, role, discipline, work_date)
        if not rows:
            st.info("No eligible resources returned for this project/date.")
            return
        for r in rows:
            with st.container(border=True):
                c1,c2,c3,c4,c5=st.columns([2,1,1,1,1])
                c1.markdown(f"**{r['full_name']}**")
                c2.write("Authorization ✓" if r.get('authorization_ok') else "Authorization ✗")
                c3.write("Competency ✓" if r.get('competency_ok') else "Competency ✗")
                c4.write("Available ✓" if r.get('availability_ok') else "Available ✗")
                c5.metric("Load", f"{r.get('workload_pct',0):.0f}%")
                st.caption((r.get('eligibility_note') or 'No eligibility note.'))
    except Exception as exc:
        st.error(str(exc))
