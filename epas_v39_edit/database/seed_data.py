"""
EPAS · Demo Seed Data
----------------------
Builds a realistic in-memory dataset that deliberately spans every stage
of the RFI lifecycle, so the dashboard shows the full workflow (pending
allocation, mid-survey, awaiting GM approval, clean approval, approval
with open observations, issued certificates, an expiring-soon interim
certificate) the moment the app starts — no clicking required to see
the system "in motion".

This module is only ever read by `database/queries.py`, and only in
demo mode. Nothing here is imported by UI components directly.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta


def _uid() -> str:
    return str(uuid.uuid4())


def _iso_days_ago(days: int) -> date:
    """Returns a plain `date` (not `datetime`) so every timestamp in the
    seed set is comparable with `date.today()`-based values created later
    by `database/queries.py` — mixing the two types breaks sorting."""
    return (datetime.now() - timedelta(days=days)).date()


def build_seed_db() -> dict:
    """Returns a fresh, fully-populated in-memory database dict."""

    # ---------------------------------------------------------------
    # PROFILES
    # ---------------------------------------------------------------
    gm = {"id": _uid(), "full_name": "Ahmed Al-Maktoum", "role": "gm",
          "email": "gm@classification.com", "company_name": "Classification Authority"}

    dm_hassan = {"id": _uid(), "full_name": "Muhammad Hassan", "role": "dm",
                 "email": "m.hassan@classification.com", "company_name": "Classification Authority"}
    dm_rania = {"id": _uid(), "full_name": "Rania Al-Farsi", "role": "dm",
                "email": "r.alfarsi@classification.com", "company_name": "Classification Authority"}

    surv_park = {"id": _uid(), "full_name": "Capt. Park Min-jae", "role": "surveyor",
                 "email": "park@classification.com", "company_name": "Classification Authority"}
    surv_khan = {"id": _uid(), "full_name": "Capt. Khan", "role": "surveyor",
                 "email": "khan@classification.com", "company_name": "Classification Authority"}
    surv_ali = {"id": _uid(), "full_name": "Eng. Ali Raza", "role": "surveyor",
                "email": "ali@classification.com", "company_name": "Classification Authority"}

    eng_faruk = {"id": _uid(), "full_name": "Mehmet Faruk", "role": "engineer",
                 "email": "faruk@classification.com", "company_name": "Classification Authority"}

    designer_tayyab = {"id": _uid(), "full_name": "Tayyab Qureshi", "role": "designer",
                        "email": "designer@damen.com", "company_name": "Damen Shipyards"}
    shipyard_ali = {"id": _uid(), "full_name": "Mohammed Ali", "role": "shipyard",
                     "email": "shipyard@damen.com", "company_name": "Damen Shipyards"}
    shipmgmt_smith = {"id": _uid(), "full_name": "John Smith", "role": "ship_management",
                       "email": "shipmanagement@oceanic.co", "company_name": "Oceanic Ship Management"}
    owner_rep = {"id": _uid(), "full_name": "Fatima Noor", "role": "owner",
                 "email": "owner@vesselholdings.com", "company_name": "Vessel Holdings Ltd"}

    profiles = [gm, dm_hassan, dm_rania, surv_park, surv_khan, surv_ali,
                eng_faruk, designer_tayyab, shipyard_ali, shipmgmt_smith, owner_rep]

    # ---------------------------------------------------------------
    # PROJECTS + VESSELS
    # ---------------------------------------------------------------
    proj_karachi = {"id": _uid(), "project_code": "Y-2996", "name": "KARACHI SB-293 Newbuild",
                     "vessel_type": "Patrol Vessel", "flag_state": "Pakistan",
                     "phases": ["nsc_survey", "in_service"], "status": "active",
                     "created_by": gm["id"], "created_at": _iso_days_ago(310)}

    proj_gulshan = {"id": _uid(), "project_code": "C-5421", "name": "GULSHAN EXPRESS Change of Class",
                     "vessel_type": "Container Feeder", "flag_state": "Pakistan",
                     "phases": ["in_service"], "status": "active",
                     "created_by": gm["id"], "created_at": _iso_days_ago(48)}

    proj_abc = {"id": _uid(), "project_code": "M-7834", "name": "ABC CARGO Class Renewal",
                "vessel_type": "General Cargo", "flag_state": "Panama",
                "phases": ["in_service"], "status": "active",
                "created_by": gm["id"], "created_at": _iso_days_ago(190)}

    proj_zenith = {"id": _uid(), "project_code": "Z-1187", "name": "ZENITH TRADER Newbuild",
                    "vessel_type": "Bulk Carrier", "flag_state": "Marshall Islands",
                    "phases": ["plan_appraisal", "nsc_survey"], "status": "active",
                    "created_by": gm["id"], "created_at": _iso_days_ago(140)}

    projects = [proj_karachi, proj_gulshan, proj_abc, proj_zenith]

    v_karachi = {"id": _uid(), "project_id": proj_karachi["id"], "name": "KARACHI SB-293 \"GUN BOAT\"",
                 "imo_number": "—", "flag_state": "Pakistan", "loa_m": 62.0, "beam_m": 9.2,
                 "draft_m": 2.8, "power_kw": 4200, "speed_knots": 28, "build_year": 2026,
                 "owner_company": "Pakistan Maritime Security Agency", "current_class": "Classification Authority"}

    v_gulshan = {"id": _uid(), "project_id": proj_gulshan["id"], "name": "GULSHAN EXPRESS",
                 "imo_number": "9456781", "flag_state": "Pakistan", "loa_m": 148.0, "beam_m": 23.4,
                 "draft_m": 8.1, "power_kw": 9800, "speed_knots": 19, "build_year": 2014,
                 "owner_company": "Oceanic Ship Management", "current_class": "Classification Authority"}

    v_abc = {"id": _uid(), "project_id": proj_abc["id"], "name": "ABC CARGO",
             "imo_number": "9312456", "flag_state": "Panama", "loa_m": 189.0, "beam_m": 28.4,
             "draft_m": 10.9, "power_kw": 12400, "speed_knots": 16, "build_year": 2009,
             "owner_company": "Vessel Holdings Ltd", "current_class": "ABS (transferred)"}

    v_zenith = {"id": _uid(), "project_id": proj_zenith["id"], "name": "ZENITH TRADER",
                "imo_number": "—", "flag_state": "Marshall Islands", "loa_m": 225.0, "beam_m": 32.2,
                "draft_m": 13.5, "power_kw": 15200, "speed_knots": 14, "build_year": 2027,
                "owner_company": "Zenith Bulk Holdings", "current_class": "Classification Authority (pending)"}

    vessels = [v_karachi, v_gulshan, v_abc, v_zenith]

    # ---------------------------------------------------------------
    # TEAM ASSIGNMENTS + STAKEHOLDERS
    # ---------------------------------------------------------------
    team_assignments = [
        {"id": _uid(), "project_id": proj_karachi["id"], "user_id": dm_hassan["id"], "role": "dm", "discipline": None},
        {"id": _uid(), "project_id": proj_karachi["id"], "user_id": surv_park["id"], "role": "surveyor", "discipline": "Hull & Structure"},
        {"id": _uid(), "project_id": proj_gulshan["id"], "user_id": dm_hassan["id"], "role": "dm", "discipline": None},
        {"id": _uid(), "project_id": proj_gulshan["id"], "user_id": surv_khan["id"], "role": "surveyor", "discipline": "Machinery"},
        {"id": _uid(), "project_id": proj_abc["id"], "user_id": dm_rania["id"], "role": "dm", "discipline": None},
        {"id": _uid(), "project_id": proj_abc["id"], "user_id": surv_ali["id"], "role": "surveyor", "discipline": "Hull & Structure"},
        {"id": _uid(), "project_id": proj_zenith["id"], "user_id": dm_rania["id"], "role": "dm", "discipline": None},
        {"id": _uid(), "project_id": proj_zenith["id"], "user_id": eng_faruk["id"], "role": "engineer", "discipline": "Stability"},
    ]

    stakeholders = [
        {"id": _uid(), "project_id": proj_karachi["id"], "company_name": "Damen Shipyards", "contact_name": shipyard_ali["full_name"], "contact_email": shipyard_ali["email"], "stakeholder_type": "shipyard"},
        {"id": _uid(), "project_id": proj_gulshan["id"], "company_name": "Oceanic Ship Management", "contact_name": shipmgmt_smith["full_name"], "contact_email": shipmgmt_smith["email"], "stakeholder_type": "ship_management"},
        {"id": _uid(), "project_id": proj_abc["id"], "company_name": "Vessel Holdings Ltd", "contact_name": owner_rep["full_name"], "contact_email": owner_rep["email"], "stakeholder_type": "owner"},
        {"id": _uid(), "project_id": proj_zenith["id"], "company_name": "Damen Shipyards", "contact_name": designer_tayyab["full_name"], "contact_email": designer_tayyab["email"], "stakeholder_type": "designer"},
    ]

    # ---------------------------------------------------------------
    # RFIs — deliberately spread across every stage of the flowchart
    # ---------------------------------------------------------------
    rfis = []
    observations = []
    gm_decisions = []
    certificates = []
    audit_log = []

    def add_rfi(**kw):
        row = {
            "id": _uid(), "assigned_dm_id": None, "assigned_surveyor_id": None,
            "scheduled_date": None, "priority": "medium",
            "created_at": _iso_days_ago(kw.pop("_age_days", 3)),
        }
        row.update(kw)
        rfis.append(row)
        return row

    # 1) Pending allocation — needs GM to assign a DM right now
    r1 = add_rfi(project_id=proj_karachi["id"], vessel_id=v_karachi["id"], phase="nsc_survey",
                  survey_type="Final NSC Survey", rfi_code="RFI-2027-014",
                  status="pending_allocation", requested_by=shipyard_ali["id"],
                  requested_date=date.today() - timedelta(days=3), priority="high", _age_days=3)

    r2 = add_rfi(project_id=proj_gulshan["id"], vessel_id=v_gulshan["id"], phase="in_service",
                  survey_type="Change of Class", rfi_code="RFI-2027-015",
                  status="pending_allocation", requested_by=shipmgmt_smith["id"],
                  requested_date=date.today() - timedelta(days=1), priority="high", _age_days=1)

    # 2) Allocated to DM — surveyor notified, waiting on-site
    r3 = add_rfi(project_id=proj_abc["id"], vessel_id=v_abc["id"], phase="in_service",
                  survey_type="Class Renewal", rfi_code="RFI-2027-011",
                  status="allocated_to_dm", requested_by=owner_rep["id"],
                  assigned_dm_id=dm_rania["id"], assigned_surveyor_id=surv_ali["id"],
                  requested_date=date.today() - timedelta(days=9),
                  scheduled_date=date.today() + timedelta(days=4), _age_days=9)

    # 3) Survey in progress
    r4 = add_rfi(project_id=proj_karachi["id"], vessel_id=v_karachi["id"], phase="in_service",
                  survey_type="Annual Survey", rfi_code="RFI-2027-009",
                  status="survey_in_progress", requested_by=shipmgmt_smith["id"],
                  assigned_dm_id=dm_hassan["id"], assigned_surveyor_id=surv_park["id"],
                  requested_date=date.today() - timedelta(days=6),
                  scheduled_date=date.today() - timedelta(days=1), _age_days=6)

    # 4) Observations logged — DM reviewing before forwarding to GM
    r5 = add_rfi(project_id=proj_gulshan["id"], vessel_id=v_gulshan["id"], phase="in_service",
                  survey_type="Intermediate Survey", rfi_code="RFI-2027-006",
                  status="observations_logged", requested_by=shipmgmt_smith["id"],
                  assigned_dm_id=dm_hassan["id"], assigned_surveyor_id=surv_khan["id"],
                  requested_date=date.today() - timedelta(days=12), _age_days=12)
    observations.append({"id": _uid(), "rfi_id": r5["id"], "obs_code": "OBS-006-01",
                          "description": "Localised coating breakdown, port ballast tank frame 44-48.",
                          "severity": "Minor", "status": "open", "raised_by": surv_khan["id"],
                          "raised_at": _iso_days_ago(5)})

    # 5) Pending GM approval — CLEAN (no open observations) — ready for one-click approve
    r6 = add_rfi(project_id=proj_karachi["id"], vessel_id=v_karachi["id"], phase="nsc_survey",
                  survey_type="FTP", rfi_code="RFI-2027-001",
                  status="pending_gm_approval", requested_by=shipyard_ali["id"],
                  assigned_dm_id=dm_hassan["id"], assigned_surveyor_id=surv_park["id"],
                  requested_date=date.today() - timedelta(days=15), priority="high", _age_days=15)

    # 6) Pending GM approval — WITH open observations — approve routes to Interim cert
    r7 = add_rfi(project_id=proj_abc["id"], vessel_id=v_abc["id"], phase="in_service",
                  survey_type="Annual Survey", rfi_code="RFI-2027-002",
                  status="pending_gm_approval", requested_by=owner_rep["id"],
                  assigned_dm_id=dm_rania["id"], assigned_surveyor_id=surv_ali["id"],
                  requested_date=date.today() - timedelta(days=8), _age_days=8)
    observations.append({"id": _uid(), "rfi_id": r7["id"], "obs_code": "OBS-002-01",
                          "description": "Main engine coolant seepage at auxiliary pump gland.",
                          "severity": "Major", "status": "open", "raised_by": surv_ali["id"],
                          "raised_at": _iso_days_ago(4)})
    observations.append({"id": _uid(), "rfi_id": r7["id"], "obs_code": "OBS-002-02",
                          "description": "Corrosion pitting on weather deck plating, frame 60.",
                          "severity": "Minor", "status": "open", "raised_by": surv_ali["id"],
                          "raised_at": _iso_days_ago(4)})

    # 7) Sent back for rework (previously bounced by GM)
    r8 = add_rfi(project_id=proj_gulshan["id"], vessel_id=v_gulshan["id"], phase="in_service",
                  survey_type="Docking Survey", rfi_code="RFI-2026-098",
                  status="sent_back_for_rework", requested_by=shipmgmt_smith["id"],
                  assigned_dm_id=dm_hassan["id"], assigned_surveyor_id=surv_khan["id"],
                  requested_date=date.today() - timedelta(days=22), _age_days=22)
    gm_decisions.append({"id": _uid(), "rfi_id": r8["id"], "decided_by": gm["id"],
                          "decision": "sent_back",
                          "note": "Observation OBS-098-01 evidence photos missing — resubmit with survey photo log.",
                          "decided_at": _iso_days_ago(2)})
    observations.append({"id": _uid(), "rfi_id": r8["id"], "obs_code": "OBS-098-01",
                          "description": "Anode depletion beyond 70% on rudder stock — needs photographic evidence.",
                          "severity": "Major", "status": "open", "raised_by": surv_khan["id"],
                          "raised_at": _iso_days_ago(10)})

    # 8) Already approved-clean, certificate issued (closed loop, historical)
    r9 = add_rfi(project_id=proj_karachi["id"], vessel_id=v_karachi["id"], phase="nsc_survey",
                  survey_type="HATS", rfi_code="RFI-2026-071",
                  status="certificate_issued", requested_by=shipyard_ali["id"],
                  assigned_dm_id=dm_hassan["id"], assigned_surveyor_id=surv_park["id"],
                  requested_date=date.today() - timedelta(days=95), _age_days=95)

    # ---------------------------------------------------------------
    # CERTIFICATES — one clean, one interim (expiring soon), one historical NSC
    # ---------------------------------------------------------------
    certificates.append({
        "id": _uid(), "vessel_id": v_karachi["id"], "project_id": proj_karachi["id"], "rfi_id": r9["id"],
        "cert_type": "nsc_certificate", "cert_number": "NCC-2026-071-Y2996",
        "issue_date": date.today() - timedelta(days=90),
        "expiry_date": date.today() + timedelta(days=(60 * 30) - 90),
        "status": "active", "pending_observations": [], "issued_by": gm["id"],
    })

    certificates.append({
        "id": _uid(), "vessel_id": v_gulshan["id"], "project_id": proj_gulshan["id"], "rfi_id": None,
        "cert_type": "interim_certificate", "cert_number": "ICC-2027-001-C5421",
        "issue_date": date.today() - timedelta(days=184),
        "expiry_date": date.today() + timedelta(days=45),          # expiring soon → shows in widget
        "status": "active",
        "pending_observations": ["OBS-089-01 — Ballast tank coating (Minor)", "OBS-089-02 — Nav-light wiring (Minor)"],
        "issued_by": gm["id"],
    })

    certificates.append({
        "id": _uid(), "vessel_id": v_abc["id"], "project_id": proj_abc["id"], "rfi_id": None,
        "cert_type": "class_certificate", "cert_number": "CC-2023-001-M7834",
        "issue_date": date.today() - timedelta(days=220),
        "expiry_date": date.today() + timedelta(days=127),
        "status": "active", "pending_observations": [], "issued_by": gm["id"],
    })

    # ---------------------------------------------------------------
    # DOCUMENTS  (Plan Appraisal phase — Zenith Trader)
    # ---------------------------------------------------------------
    documents = [
        {"id": _uid(), "project_id": proj_zenith["id"], "category": "drawing",
         "file_name": "Hydrostatic_Curves_Rev_A.pdf", "version": 1, "status": "pending_review",
         "uploaded_by": designer_tayyab["id"], "uploaded_at": _iso_days_ago(4)},
        {"id": _uid(), "project_id": proj_zenith["id"], "category": "drawing",
         "file_name": "General_Arrangement_Rev_B.pdf", "version": 2, "status": "approved",
         "uploaded_by": designer_tayyab["id"], "uploaded_at": _iso_days_ago(20)},
        {"id": _uid(), "project_id": proj_zenith["id"], "category": "contract",
         "file_name": "Newbuild_Contract_Zenith.pdf", "version": 1, "status": "approved",
         "uploaded_by": designer_tayyab["id"], "uploaded_at": _iso_days_ago(140)},
        {"id": _uid(), "project_id": proj_zenith["id"], "category": "drawing",
         "file_name": "Stability_Booklet_Rev_A.pdf", "version": 1, "status": "amendments_required",
         "uploaded_by": designer_tayyab["id"], "uploaded_at": _iso_days_ago(9)},
    ]

    document_remarks = [
        {"id": _uid(), "document_id": documents[3]["id"], "author_id": eng_faruk["id"],
         "body": "Recalculate GZ curve per DNV-GL formula 3.5.2 — current margin insufficient at full load.",
         "created_at": _iso_days_ago(7)},
    ]

    # ---------------------------------------------------------------
    # AUDIT LOG (seed a few historical entries)
    # ---------------------------------------------------------------
    audit_log.append({"id": _uid(), "project_id": proj_karachi["id"], "actor_id": gm["id"],
                       "action": "CERTIFICATE_ISSUED",
                       "details": {"cert_number": "NCC-2026-071-Y2996"}, "created_at": _iso_days_ago(90)})
    audit_log.append({"id": _uid(), "project_id": proj_gulshan["id"], "actor_id": gm["id"],
                       "action": "RFI_SENT_BACK",
                       "details": {"rfi_code": "RFI-2026-098"}, "created_at": _iso_days_ago(2)})

    return {
        "profiles": profiles,
        "projects": projects,
        "vessels": vessels,
        "team_assignments": team_assignments,
        "stakeholders": stakeholders,
        "rfis": rfis,
        "observations": observations,
        "gm_decisions": gm_decisions,
        "certificates": certificates,
        "documents": documents,
        "document_remarks": document_remarks,
        "audit_log": audit_log,
        "_counters": {"rfi": 16, "obs": 100, "cert": len(certificates) + 1},
    }
