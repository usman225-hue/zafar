"""EPAS v4.0 production Streamlit entrypoint.
Historical modules remain archived for cumulative migration/testing coverage; the active surface is v3.9.
The page is deliberately role-native and view-gated so a rerun renders only one operational surface at a time.
"""

from __future__ import annotations
import streamlit as st
from config import settings as cfg
from styles.theme import inject_css
from components.auth_gate import render as render_auth
from components.branding import render_topbar
from components.gm_production import render as render_gm
from components.dm_production import render as render_dm
from components.role_workspaces import render_engineer, render_surveyor, render_designer, render_ship_management, render_readonly_stakeholder
from components.professional_center_v36 import render as render_professional_center
from components.role_cockpits_v40 import render as render_role_cockpit
from components.project_workspace_v40 import render as render_project_workspace, render_project_launcher
from components.survey_lifecycle_v36 import render as render_survey_lifecycle_v36, render_role_acceptance as render_v36_acceptance
render_v33_acceptance = render_v36_acceptance  # archived compatibility alias


def main() -> None:
    st.set_page_config(page_title=f"{cfg.APP_NAME} · v4.0", page_icon="🚢", layout="wide", initial_sidebar_state="expanded")
    inject_css()

    user = render_auth()
    if not user:
        st.stop()

    role = user.get('role')

    NAV = {
        'gm': [('Command Center', 'cockpit'), ('Projects', 'projects'), ('Project & Plan', 'operations'), ('Survey Control', 'survey'), ('Governance & Acceptance', 'governance')],
        'dm': [('Operations Center', 'cockpit'), ('Projects', 'projects'), ('Plan / Allocation', 'operations'), ('Survey Control', 'survey'), ('Acceptance', 'governance')],
        'engineer': [('Technical Cockpit', 'cockpit'), ('Projects', 'projects'), ('Plan Appraisal', 'operations')],
        'surveyor': [('Field Cockpit', 'cockpit'), ('Projects', 'projects'), ('Survey Lifecycle', 'survey')],
        'designer': [('Submission Cockpit', 'cockpit'), ('Projects', 'projects'), ('Plan Appraisal', 'operations')],
        'ship_management': [('Operations Cockpit', 'cockpit'), ('Projects', 'projects'), ('Corrective / Survey', 'operations') , ('Survey Lifecycle', 'survey')],
        'owner': [('Fleet Cockpit', 'cockpit'), ('Projects', 'projects'), ('In-Service', 'operations'), ('Survey Lifecycle', 'survey')],
        'shipyard': [('NSC Cockpit', 'cockpit'), ('Projects', 'projects'), ('NSC Operations', 'operations'), ('Survey Lifecycle', 'survey')],
    }

    if role not in NAV:
        st.error("Your account has no valid EPAS workflow role. Contact the system administrator.")
        st.stop()

    options = NAV[role]
    state_key = f"epas_view_{role}_v39"
    labels = [x[0] for x in options]
    view_titles = {label: key for label, key in options}
    selected_label = st.radio(
        "WORKSPACE",
        labels,
        index=0,
        horizontal=True,
        key=state_key,
        label_visibility="collapsed",
    )
    view = view_titles[selected_label]

    # PSB application shell: authenticated identity, current workspace and secure status.
    project_id = st.session_state.get("selected_project_id")
    render_topbar(user, "Project Workspace" if project_id else selected_label)

    if project_id:
        # Once a project is opened, it becomes the primary context. The role-specific
        # project navigation sits on the left and all project operations remain in the
        # selected project boundary.
        render_project_workspace(role, project_id)
        st.stop()

    # Always render the lightweight role header/cockpit; all heavy pages are mutually exclusive.
    render_role_cockpit(role)

    if view == 'cockpit':
        st.markdown("### Next-action guidance")
        st.caption("Select an operational surface above. Only the selected page is loaded, reducing unnecessary database calls on Streamlit reruns.")
    elif view == 'projects':
        render_project_launcher(role)
    elif view == 'operations':
        if role == cfg.ROLE_GM:
            render_gm()
        elif role == cfg.ROLE_DM:
            render_dm()
        elif role == cfg.ROLE_ENGINEER:
            render_engineer()
        elif role == cfg.ROLE_SURVEYOR:
            render_surveyor()
        elif role == cfg.ROLE_DESIGNER:
            render_designer()
        elif role == cfg.ROLE_SHIP_MANAGEMENT:
            render_ship_management()
        elif role in (cfg.ROLE_OWNER, cfg.ROLE_SHIPYARD):
            render_readonly_stakeholder()
    elif view == 'survey':
        render_professional_center(include_security=(role in (cfg.ROLE_GM, cfg.ROLE_DM)))
        render_survey_lifecycle_v36()
    elif view == 'governance':
        render_professional_center(include_security=True)
        render_v36_acceptance()


if __name__ == "__main__":
    main()
