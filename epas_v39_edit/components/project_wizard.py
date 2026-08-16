"""
EPAS · Project Creation Wizard
--------------------------------
Mirrors the flowchart's five wizard steps exactly:

    1. Project Info          — Name, Type, Flag
    2. Vessel Particulars    — Dimensions, Power, Speed
    3. Upload Documents      — Contract, Rules, Timeline
    4. Assign Internal Team  — DM, Engineers, Surveyors
    5. Add Stakeholders      — Owner, Designer, Ship Mgmt, Shipyard
       (+ Project Phase selection, per the phase-options spec, which
       the flowchart places inside this same step)

    → "Project Created & Live — Notifications sent to all"

IMPORTANT — why values live in `st.session_state["wiz_data"]`:
Streamlit clears a widget's session_state entry on any run where that
widget is NOT instantiated. Since only the current step's widgets are
rendered, a naive implementation that reads `st.session_state["wiz_name"]`
from step 5 (after step 1's widget hasn't rendered for four steps)
raises a KeyError. Every widget below writes its return value into the
plain `wiz_data` dict immediately, and reads its displayed default back
out of that same dict — so Back/Next never loses anything, and _finish()
only ever reads from `wiz_data`, never from a possibly-stale widget key.
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q

STEP_LABELS = [
    "Project Info", "Vessel Particulars", "Documents", "Internal Team", "Stakeholders & Phases",
]


def _data() -> dict:
    return st.session_state.setdefault("wiz_data", {})


def _init_state() -> None:
    st.session_state.setdefault("wiz_step", 1)
    st.session_state.setdefault("wiz_data", {})


def _reset_wizard() -> None:
    for k in ("wiz_step", "wiz_data"):
        st.session_state.pop(k, None)
    keys = [k for k in st.session_state.keys() if k.startswith("wizw_")]
    for k in keys:
        del st.session_state[k]


def _rail() -> None:
    step = st.session_state["wiz_step"]
    cols = st.columns(5)
    for i, (col, label) in enumerate(zip(cols, STEP_LABELS), start=1):
        state = "done" if i < step else "active" if i == step else "pending"
        mark = "✓" if state == "done" else f"{i:02d}"
        with col:
            st.markdown(
                f'<div class="wizard-step wizard-step--{state}">'
                f'<div class="wizard-step-num">ENTRY {mark}</div>'
                f'<div class="wizard-step-label">{label}</div></div>',
                unsafe_allow_html=True,
            )


def render() -> None:
    """Legacy wizard guard: project creation is GM-only and exposed only from the Projects register."""
    try:
        from database import production_queries as _pq
        if (_pq.profile() or {}).get("role") != "gm":
            st.error("Project creation is restricted to GM Classification.")
            return
    except Exception:
        st.error("Project creation is unavailable until authentication is verified.")
        return

    _init_state()

    st.markdown(
        '<div class="eyebrow">New Project</div>'
        '<div class="page-title">Create Project</div>'
        "<div class=\"page-sub\">Five entries in the ledger — from vessel particulars to the stakeholders who'll watch it progress.</div>",
        unsafe_allow_html=True,
    )
    st.write("")
    st.markdown('<div class="wizard-rail">', unsafe_allow_html=True)
    _rail()
    st.markdown("</div>", unsafe_allow_html=True)
    st.write("")

    step = st.session_state["wiz_step"]
    with st.container(border=True):
        if step == 1:
            _step_1()
        elif step == 2:
            _step_2()
        elif step == 3:
            _step_3()
        elif step == 4:
            _step_4()
        elif step == 5:
            _step_5()

    st.write("")
    if st.button("← Cancel and return to Projects", key="wizw_cancel"):
        _reset_wizard()
        st.session_state["page"] = "projects"
        st.rerun()


# -------------------------------------------------------------------------
# STEP 1 — Project Info
# -------------------------------------------------------------------------

def _step_1() -> None:
    d = _data()
    st.markdown('<div class="section-title">Entry 01 · Project Info</div>', unsafe_allow_html=True)
    st.caption("Name, vessel type, and flag state.")
    st.write("")

    d["name"] = st.text_input("Project / Vessel Name *", value=d.get("name", ""),
                               key="wizw_name", placeholder="e.g. ZENITH TRADER Newbuild")
    d["vessel_type"] = st.selectbox(
        "Vessel Type *", options=cfg.VESSEL_TYPES,
        index=cfg.VESSEL_TYPES.index(d["vessel_type"]) if d.get("vessel_type") in cfg.VESSEL_TYPES else 0,
        key="wizw_vessel_type",
    )
    d["flag_state"] = st.selectbox(
        "Flag State *", options=cfg.COMMON_FLAG_STATES,
        index=cfg.COMMON_FLAG_STATES.index(d["flag_state"]) if d.get("flag_state") in cfg.COMMON_FLAG_STATES else 0,
        key="wizw_flag_state",
    )

    _nav(back=False, next_enabled=bool(d["name"].strip()))


# -------------------------------------------------------------------------
# STEP 2 — Vessel Particulars
# -------------------------------------------------------------------------

def _step_2() -> None:
    d = _data()
    st.markdown('<div class="section-title">Entry 02 · Vessel Particulars</div>', unsafe_allow_html=True)
    st.caption("Dimensions, power, and speed.")
    st.write("")

    c1, c2 = st.columns(2)
    with c1:
        d["imo"] = st.text_input("IMO / Registration No.", value=d.get("imo", ""),
                                  key="wizw_imo", placeholder="Leave blank if not yet assigned")
        d["loa"] = st.number_input("Length Overall (m)", value=float(d.get("loa", 0.0)),
                                    min_value=0.0, step=0.5, key="wizw_loa")
        d["beam"] = st.number_input("Beam (m)", value=float(d.get("beam", 0.0)),
                                     min_value=0.0, step=0.1, key="wizw_beam")
        d["draft"] = st.number_input("Draft (m)", value=float(d.get("draft", 0.0)),
                                      min_value=0.0, step=0.1, key="wizw_draft")
    with c2:
        d["power"] = st.number_input("Power (kW)", value=float(d.get("power", 0.0)),
                                      min_value=0.0, step=50.0, key="wizw_power")
        d["speed"] = st.number_input("Speed (knots)", value=float(d.get("speed", 0.0)),
                                      min_value=0.0, step=0.5, key="wizw_speed")
        d["build_year"] = st.number_input("Build Year", value=int(d.get("build_year", 2027)),
                                           min_value=1970, max_value=2035, step=1, key="wizw_build_year")
        d["owner_company"] = st.text_input("Owner Company", value=d.get("owner_company", ""),
                                            key="wizw_owner_company")

    _nav(back=True, next_enabled=True)


# -------------------------------------------------------------------------
# STEP 3 — Upload Documents (Contract, Rules, Timeline)
# -------------------------------------------------------------------------

def _step_3() -> None:
    d = _data()
    st.markdown('<div class="section-title">Entry 03 · Upload Documents</div>', unsafe_allow_html=True)
    st.caption("Contract, class rules, and project timeline.")
    st.write("")

    contract_files = st.file_uploader("Contract Documents", accept_multiple_files=True, key="wizw_docs_contract")
    if contract_files:
        d["docs_contract"] = [f.name for f in contract_files]

    rules_files = st.file_uploader("Class Rules", accept_multiple_files=True, key="wizw_docs_rules")
    if rules_files:
        d["docs_rules"] = [f.name for f in rules_files]

    timeline_file = st.file_uploader("Project Timeline", accept_multiple_files=False, key="wizw_docs_timeline")
    if timeline_file is not None:
        d["docs_timeline"] = timeline_file.name

    attached = len(d.get("docs_contract", [])) + len(d.get("docs_rules", [])) + (1 if d.get("docs_timeline") else 0)
    if attached:
        st.caption(f"📎 {attached} file(s) attached and will be catalogued when the project is created "
                   "— they stay attached even if this uploader looks empty after navigating back.")

    _nav(back=True, next_enabled=True)


# -------------------------------------------------------------------------
# STEP 4 — Assign Internal Team (DM, Engineers, Surveyors)
# -------------------------------------------------------------------------

def _step_4() -> None:
    d = _data()
    st.markdown('<div class="section-title">Entry 04 · Assign Internal Team</div>', unsafe_allow_html=True)
    st.caption("Department Manager, Engineers, and Surveyors.")
    st.write("")

    dms = q.list_users(role=cfg.ROLE_DM)
    engineers = q.list_users(role=cfg.ROLE_ENGINEER)
    surveyors = q.list_users(role=cfg.ROLE_SURVEYOR)

    dm_ids = [x["id"] for x in dms]
    dm_default_idx = dm_ids.index(d["dm_id"]) if d.get("dm_id") in dm_ids else 0
    d["dm_id"] = st.selectbox(
        "Department Manager *", options=dm_ids,
        format_func=lambda uid: next(x["full_name"] for x in dms if x["id"] == uid),
        index=dm_default_idx, key="wizw_dm_id",
    )

    st.markdown("**Engineers**")
    eng_ids_all = [x["id"] for x in engineers]
    d["engineer_ids"] = st.multiselect(
        "Select engineers", options=eng_ids_all,
        default=[e for e in d.get("engineer_ids", []) if e in eng_ids_all],
        format_func=lambda uid: next(x["full_name"] for x in engineers if x["id"] == uid),
        key="wizw_engineer_ids", label_visibility="collapsed",
    )
    d.setdefault("engineer_disciplines", {})
    for eid in d["engineer_ids"]:
        ename = next(x["full_name"] for x in engineers if x["id"] == eid)
        current = d["engineer_disciplines"].get(eid, cfg.DISCIPLINES[0])
        idx = cfg.DISCIPLINES.index(current) if current in cfg.DISCIPLINES else 0
        d["engineer_disciplines"][eid] = st.selectbox(
            f"Discipline — {ename}", options=cfg.DISCIPLINES, index=idx, key=f"wizw_eng_disc_{eid}",
        )

    st.markdown("**Surveyors**")
    surv_ids_all = [x["id"] for x in surveyors]
    d["surveyor_ids"] = st.multiselect(
        "Select surveyors", options=surv_ids_all,
        default=[s for s in d.get("surveyor_ids", []) if s in surv_ids_all],
        format_func=lambda uid: next(x["full_name"] for x in surveyors if x["id"] == uid),
        key="wizw_surveyor_ids", label_visibility="collapsed",
    )
    d.setdefault("surveyor_disciplines", {})
    for sid in d["surveyor_ids"]:
        sname = next(x["full_name"] for x in surveyors if x["id"] == sid)
        current = d["surveyor_disciplines"].get(sid, cfg.DISCIPLINES[0])
        idx = cfg.DISCIPLINES.index(current) if current in cfg.DISCIPLINES else 0
        d["surveyor_disciplines"][sid] = st.selectbox(
            f"Discipline — {sname}", options=cfg.DISCIPLINES, index=idx, key=f"wizw_surv_disc_{sid}",
        )

    _nav(back=True, next_enabled=bool(d.get("dm_id")))


# -------------------------------------------------------------------------
# STEP 5 — Stakeholders + Project Phases → Finish
# -------------------------------------------------------------------------

def _step_5() -> None:
    d = _data()
    st.markdown('<div class="section-title">Entry 05 · Stakeholders &amp; Project Phases</div>', unsafe_allow_html=True)
    st.caption("Owner, Designer, Ship Management, Shipyard — and which phases this project will run.")
    st.write("")

    st.markdown("**Project phases** — contextual tabs in the workspace follow this selection.")
    pc1, pc2, pc3 = st.columns(3)
    with pc1:
        d["phase_plan"] = st.checkbox(f"{cfg.PHASE_ICONS[cfg.PHASE_PLAN_APPRAISAL]} Plan Appraisal",
                                       value=d.get("phase_plan", False), key="wizw_phase_plan")
    with pc2:
        d["phase_nsc"] = st.checkbox(f"{cfg.PHASE_ICONS[cfg.PHASE_NSC_SURVEY]} NSC Survey",
                                      value=d.get("phase_nsc", False), key="wizw_phase_nsc")
    with pc3:
        d["phase_inservice"] = st.checkbox(f"{cfg.PHASE_ICONS[cfg.PHASE_IN_SERVICE]} In-Service Surveys",
                                            value=d.get("phase_inservice", False), key="wizw_phase_inservice")

    st.write("")
    st.markdown("**External stakeholders** (leave company name blank to skip a role)")

    d.setdefault("stakeholders", {})
    stakeholder_rows = [
        (cfg.ROLE_OWNER, "Owner"), (cfg.ROLE_DESIGNER, "Designer"),
        (cfg.ROLE_SHIP_MANAGEMENT, "Ship Management Co."), (cfg.ROLE_SHIPYARD, "Shipyard"),
    ]
    for role_key, label in stakeholder_rows:
        row = d["stakeholders"].setdefault(role_key, {"company": "", "contact": "", "email": ""})
        c1, c2 = st.columns([1.2, 2])
        with c1:
            row["company"] = st.text_input(f"{label} — Company", value=row.get("company", ""),
                                            key=f"wizw_sh_company_{role_key}")
        with c2:
            cc1, cc2 = st.columns(2)
            with cc1:
                row["contact"] = st.text_input("Contact name", value=row.get("contact", ""),
                                                key=f"wizw_sh_contact_{role_key}",
                                                label_visibility="collapsed", placeholder="Contact name")
            with cc2:
                row["email"] = st.text_input("Contact email", value=row.get("email", ""),
                                              key=f"wizw_sh_email_{role_key}",
                                              label_visibility="collapsed", placeholder="Contact email")

    any_phase = bool(d.get("phase_plan") or d.get("phase_nsc") or d.get("phase_inservice"))
    if not any_phase:
        st.info("Select at least one project phase to continue.")

    st.write("")
    c1, c2 = st.columns(2)
    with c1:
        if st.button("← Back", key="wizw_back_5", use_container_width=True):
            st.session_state["wiz_step"] = 4
            st.rerun()
    with c2:
        if st.button("✅ Create Project", key="wizw_finish", type="primary",
                      use_container_width=True, disabled=not any_phase):
            _finish()


def _finish() -> None:
    d = _data()

    phases = []
    if d.get("phase_plan"):
        phases.append(cfg.PHASE_PLAN_APPRAISAL)
    if d.get("phase_nsc"):
        phases.append(cfg.PHASE_NSC_SURVEY)
    if d.get("phase_inservice"):
        phases.append(cfg.PHASE_IN_SERVICE)

    team = [{"user_id": d.get("dm_id"), "role": cfg.ROLE_DM, "discipline": None}]
    for eid in d.get("engineer_ids", []):
        team.append({"user_id": eid, "role": cfg.ROLE_ENGINEER,
                     "discipline": d.get("engineer_disciplines", {}).get(eid)})
    for sid in d.get("surveyor_ids", []):
        team.append({"user_id": sid, "role": cfg.ROLE_SURVEYOR,
                     "discipline": d.get("surveyor_disciplines", {}).get(sid)})

    stakeholders = []
    for role_key, row in d.get("stakeholders", {}).items():
        company = (row.get("company") or "").strip()
        if company:
            stakeholders.append({
                "company_name": company,
                "contact_name": row.get("contact", ""),
                "contact_email": row.get("email", ""),
                "stakeholder_type": role_key,
            })

    documents = []
    for name in d.get("docs_contract", []):
        documents.append({"category": cfg.DOC_CATEGORY_CONTRACT, "file_name": name})
    for name in d.get("docs_rules", []):
        documents.append({"category": cfg.DOC_CATEGORY_RULES, "file_name": name})
    if d.get("docs_timeline"):
        documents.append({"category": cfg.DOC_CATEGORY_TIMELINE, "file_name": d["docs_timeline"]})

    payload = {
        "name": d["name"].strip(),
        "vessel_type": d["vessel_type"],
        "flag_state": d["flag_state"],
        "phases": phases,
        "vessel": {
            "name": d["name"].strip(),
            "imo_number": d.get("imo") or "—",
            "loa_m": d.get("loa") or None,
            "beam_m": d.get("beam") or None,
            "draft_m": d.get("draft") or None,
            "power_kw": d.get("power") or None,
            "speed_knots": d.get("speed") or None,
            "build_year": d.get("build_year"),
            "owner_company": d.get("owner_company") or "—",
        },
        "team": team,
        "stakeholders": stakeholders,
        "documents": documents,
    }

    project = q.create_project(payload)
    _reset_wizard()
    st.session_state["page"] = "workspace"
    st.session_state["selected_project_id"] = project["id"]
    st.toast(f"{project['project_code']} created — notifications sent to all stakeholders.", icon="🚀")
    st.rerun()


# -------------------------------------------------------------------------
# Nav buttons
# -------------------------------------------------------------------------

def _nav(back: bool, next_enabled: bool) -> None:
    st.write("")
    c1, c2 = st.columns(2)
    with c1:
        if back:
            if st.button("← Back", key=f"wizw_back_{st.session_state['wiz_step']}", use_container_width=True):
                st.session_state["wiz_step"] -= 1
                st.rerun()
    with c2:
        if st.button("Next →", key=f"wizw_next_{st.session_state['wiz_step']}", type="primary",
                      use_container_width=True, disabled=not next_enabled):
            st.session_state["wiz_step"] += 1
            st.rerun()
