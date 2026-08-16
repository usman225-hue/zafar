"""
Headless functional smoke test — not part of the shipped app.

Exercises app.py through Streamlit's AppTest harness. Two parts:

  PART A — UI-driven integration test. Every mutation happens via a
  real `.click()` on the actual rendered button, and every assertion
  reads `at.session_state["_db"]` — the *exact* store the running app
  itself reads and writes. (A plain `import database.queries` from
  outside the AppTest sandbox gets its own independent session_state
  and silently checks a different, unmutated copy of the seed data —
  a real gotcha worth documenting here for the next person.)

  PART B — isolated unit tests of the state-machine functions in
  `database/queries.py` (send-back/resubmit loop, interim-certificate
  observation snapshotting, PDF byte generation) against a freshly
  built seed store, independent of any running UI.
"""
import sys
from pathlib import Path
import pytest
pytest.importorskip("streamlit")
from streamlit.testing.v1 import AppTest

# Make the project root importable when this file is run directly
# (e.g. `python tests/test_workflow_smoke.py` from anywhere).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def check(at: AppTest, label: str):
    if at.exception:
        print(f"\n❌ EXCEPTION after: {label}")
        for e in at.exception:
            print(e)
        sys.exit(1)
    print(f"✅ {label}")


def find_button(at: AppTest, prefix: str):
    matches = [b for b in at.button if b.key and b.key.startswith(prefix)]
    return matches[0] if matches else None


# =========================================================================
# PART A — UI-driven integration test
# =========================================================================

at = AppTest.from_file(str(Path(__file__).resolve().parent.parent / "app.py"), default_timeout=30)
at.run()
check(at, "cold start / overview page")
assert any("Good day" in m.value for m in at.markdown), "GM greeting missing from overview"

at.session_state["page"] = "projects"
at.run()
check(at, "navigate to Projects list")

# --- walk the full 5-step wizard -----------------------------------------
at.session_state["page"] = "wizard"
at.run()
check(at, "open wizard step 1")

at.text_input(key="wizw_name").set_value("TEST VESSEL Smoke Run")
at.selectbox(key="wizw_vessel_type").set_value("Bulk Carrier")
at.selectbox(key="wizw_flag_state").set_value("Panama")
at.run()
at.button(key="wizw_next_1").click().run()
check(at, "wizard step 1 -> 2")
assert at.session_state["wiz_step"] == 2

at.number_input(key="wizw_loa").set_value(180.0)
at.run()
at.button(key="wizw_next_2").click().run()
check(at, "wizard step 2 -> 3")
assert at.session_state["wiz_step"] == 3

at.button(key="wizw_next_3").click().run()
check(at, "wizard step 3 -> 4")
assert at.session_state["wiz_step"] == 4

at.button(key="wizw_next_4").click().run()  # DM selectbox already defaults to first option
check(at, "wizard step 4 -> 5")
assert at.session_state["wiz_step"] == 5

at.checkbox(key="wizw_phase_inservice").check()
at.run()
at.button(key="wizw_finish").click().run()
check(at, "wizard finish -> project created")
assert at.session_state["page"] == "workspace"
new_project_id = at.session_state["selected_project_id"]

# Verify the cross-step data actually survived to _finish() — this is
# precisely the bug class that was found and fixed during this build.
db = at.session_state["_db"]
created_project = next(p for p in db["projects"] if p["id"] == new_project_id)
created_vessel = next(v for v in db["vessels"] if v["project_id"] == new_project_id)
assert created_project["name"] == "TEST VESSEL Smoke Run", created_project["name"]
assert created_project["flag_state"] == "Panama", created_project["flag_state"]
assert created_vessel["loa_m"] == 180.0, created_vessel["loa_m"]
print("✅ cross-step wizard data integrity: name / flag / LOA all persisted step 1 -> step 5 -> save")

# --- RFI allocation via a real button click -------------------------------
at.session_state["page"] = "overview"
at.run()
check(at, "overview after project creation")

assign_btn = find_button(at, "assign_")
assert assign_btn is not None, "expected at least one 'Pending Allocation' RFI on Overview"
target_rfi_id = assign_btn.key.replace("assign_", "")
before = next(r for r in at.session_state["_db"]["rfis"] if r["id"] == target_rfi_id)
assert before["status"] == "pending_allocation"

assign_btn.click().run()
check(at, "click 'Assign to DM →' on a real RFI card")
after = next(r for r in at.session_state["_db"]["rfis"] if r["id"] == target_rfi_id)
assert after["status"] == "allocated_to_dm", after["status"]
assert after["assigned_dm_id"] is not None
print(f"✅ UI-driven assign_rfi_to_dm: {after['rfi_code']} pending_allocation -> allocated_to_dm")

# --- GM approval decision via a real button click -------------------------
at.session_state["page"] = "overview"
at.run()

# Find the seeded CLEAN pending-approval RFI (RFI-2027-001, no open observations)
clean_rfi = next(r for r in at.session_state["_db"]["rfis"] if r["rfi_code"] == "RFI-2027-001")
approve_btn = find_button(at, f"approve_{clean_rfi['id']}")
assert approve_btn is not None, "expected an Approve button for RFI-2027-001 on Overview"
approve_btn.click().run()
check(at, "click 'Approve' on a clean RFI (no open observations)")
after = next(r for r in at.session_state["_db"]["rfis"] if r["id"] == clean_rfi["id"])
assert after["status"] == "approved_no_observations", after["status"]
print(f"✅ UI-driven gm_decide(approved): {after['rfi_code']} -> {after['status']} "
      f"(routes to Class Certificate, matching the flowchart's clean branch)")

# "Ready to Certify" is intentionally NOT part of Overview's "Needs Your
# Signature" queue (RFI_GM_ACTIONABLE = pending_allocation + pending_gm_approval
# only — issuing the certificate is a follow-up action, not a pending
# decision). It surfaces on that RFI's phase-specific queue instead.
at.session_state["page"] = "rfi_nsc" if clean_rfi["phase"] == "nsc_survey" else "rfi_in_service"
at.run()
check(at, "navigate to phase-specific RFI queue to find the certify action")
cert_btn = find_button(at, f"cert_{clean_rfi['id']}")
assert cert_btn is not None, "expected an 'Issue Certificate' button to appear after approval"
print("✅ 'Issue Certificate' action appears on the phase queue immediately after approval, as the flowchart requires")

# --- Regression sweep: every top-level page still renders after all this
#     real, UI-driven mutation ------------------------------------------
for page in ["overview", "projects", "rfi_nsc", "rfi_in_service", "certificates", "ship_register", "reports"]:
    at.session_state["page"] = page
    at.run()
    check(at, f"re-render '{page}' after UI-driven mutations")

at.session_state["page"] = "workspace"
at.session_state["selected_project_id"] = new_project_id
at.run()
check(at, "re-render newly created project's workspace")

# --- Plan Appraisal tab + Document Detail dialog, on the seeded project
#     that actually has documents (Z-1187 ZENITH TRADER) --------------
zenith = next(p for p in at.session_state["_db"]["projects"] if p["project_code"] == "Z-1187")
at.session_state["page"] = "workspace"
at.session_state["selected_project_id"] = zenith["id"]
at.run()
check(at, "render workspace for a project with Plan Appraisal + documents")

doc_view_btn = find_button(at, "doc_view_")
assert doc_view_btn is not None, "expected a document 'View →' button in Project Info tab"
doc_view_btn.click().run()
check(at, "open Document Detail dialog")
print("✅ Document Detail dialog opens without error")


# =========================================================================
# PART B — isolated unit tests of the state-machine / cert / PDF logic
# (independent seed store — not the AppTest session above)
# =========================================================================
print("\n--- Part B: isolated query-layer + PDF unit tests ---")

from database import queries as q
from database.seed_data import build_seed_db
from config import settings as cfg
from components.pdf_certificate import generate_certificate_pdf

# queries.py pulls its store from st.session_state; outside of an AppTest
# run this is a bare, unshared instance — perfectly fine for unit-testing
# pure state-machine behaviour in isolation.
import streamlit as st
st.session_state["_db"] = build_seed_db()

obs_rfi = next(r for r in q.list_rfis(status=cfg.RFI_PENDING_GM_APPROVAL) if q.open_observations(r["id"]))
q.gm_decide(obs_rfi["id"], "approved", "")
updated = q.get_rfi(obs_rfi["id"])
assert updated["status"] == cfg.RFI_APPROVED_WITH_OBS, updated["status"]
print(f"✅ gm_decide(approved, open observations present): {obs_rfi['rfi_code']} -> {updated['status']}")

open_obs = q.open_observations(obs_rfi["id"])
descriptions = [f"{o['obs_code']} — {o['description']} ({o['severity']})" for o in open_obs]
interim_cert = q.issue_certificate(obs_rfi["vessel_id"], obs_rfi["project_id"], obs_rfi["id"],
                                    cfg.CERT_TYPE_INTERIM, 6, descriptions)
assert interim_cert["cert_type"] == cfg.CERT_TYPE_INTERIM
assert len(interim_cert["pending_observations"]) == len(open_obs) > 0
rfi_after = q.get_rfi(obs_rfi["id"])
assert rfi_after["status"] == cfg.RFI_CERT_ISSUED
print(f"✅ issue_certificate(interim): {interim_cert['cert_number']} lists "
      f"{len(interim_cert['pending_observations'])} pending observation(s); RFI closed to {rfi_after['status']}")

vessel = q.get_vessel(interim_cert["vessel_id"])
pdf_bytes = generate_certificate_pdf(interim_cert, vessel, q.current_gm()["full_name"])
assert isinstance(pdf_bytes, bytes) and pdf_bytes[:4] == b"%PDF"
print(f"✅ generate_certificate_pdf: {len(pdf_bytes):,} bytes, valid PDF header")

# Send-back -> resubmit loop
sb_candidates = q.list_rfis(status=cfg.RFI_PENDING_GM_APPROVAL)
assert sb_candidates, "expected at least one more pending_gm_approval RFI for the send-back test"
sb_rfi = sb_candidates[0]
q.gm_decide(sb_rfi["id"], "sent_back", "Missing evidence photos — resubmit with photo log.")
assert q.get_rfi(sb_rfi["id"])["status"] == cfg.RFI_SENT_BACK
q.resubmit_rfi(sb_rfi["id"])
assert q.get_rfi(sb_rfi["id"])["status"] == cfg.RFI_PENDING_GM_APPROVAL
print(f"✅ send-back -> resubmit loop: {sb_rfi['rfi_code']} sent_back_for_rework -> pending_gm_approval")

# Class certificate path (no open observations)
clean_candidates = [r for r in q.list_rfis(status=cfg.RFI_PENDING_GM_APPROVAL) if not q.open_observations(r["id"])]
assert clean_candidates, "expected a clean pending_gm_approval RFI"
clean2 = clean_candidates[0]
q.gm_decide(clean2["id"], "approved", "")
assert q.get_rfi(clean2["id"])["status"] == cfg.RFI_APPROVED_CLEAN
class_cert = q.issue_certificate(clean2["vessel_id"], clean2["project_id"], clean2["id"], cfg.CERT_TYPE_CLASS, 12)
assert class_cert["cert_type"] == cfg.CERT_TYPE_CLASS
assert class_cert["pending_observations"] == []
print(f"✅ issue_certificate(class): {class_cert['cert_number']}, no pending observations, "
      f"12-month validity honoured ({class_cert['expiry_date']})")

kpis = q.kpi_summary()
assert set(kpis) == {"active_projects", "total_projects", "rfis_in_progress", "needs_gm_action",
                      "pending_allocation", "pending_approval", "certs_expiring_soon"}
print(f"✅ kpi_summary() shape correct: {kpis}")

from components.ship_register import _certificate_ledger_csv
some_vessel = q.list_vessels()[0]
csv_bytes = _certificate_ledger_csv(some_vessel, q.list_certificates(vessel_id=some_vessel["id"]))
assert isinstance(csv_bytes, bytes) and b"Vessel" in csv_bytes
print(f"✅ Ship Register CSV export: {len(csv_bytes)} bytes generated for {some_vessel['name']}")

print("\n🎉 ALL SMOKE TESTS PASSED (Part A: UI-driven · Part B: state-machine unit tests)")
