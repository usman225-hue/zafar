from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "database" / "production_v1_6_flow_alignment.sql").read_text()

def test_survey_observations_are_not_clearable_during_dm_pre_gm_review():
    assert "v_rfi.status not in ('sent_back_for_rework','certificate_issued')" in SQL
    assert "Only the Department Manager may verify survey observation closure" in SQL

def test_corrective_action_links_to_observations():
    assert "add column if not exists corrective_action_id" in SQL
    assert "set corrective_action_id=v_action.id" in SQL

def test_follow_up_rfi_is_linked_to_original():
    assert "follow_up_of_rfi_id" in SQL
    assert "follow_up_of_rfi_id=v_old.id" in SQL

def test_certificate_requires_dm_ack():
    assert "DM final-approval acknowledgement is required before certificate issuance" in SQL
    assert "task_type='DM_GM_FINAL_APPROVAL_ACK'" in SQL

def test_final_certificate_requires_follow_up_rfi():
    assert "A verified Follow-up RFI is required before finalising the Interim Certificate" in SQL
    assert "Follow-up RFI must be approved by GM with no open observations" in SQL

def test_gm_ui_removes_manual_observation_clear():
    gm = (ROOT / "components" / "gm_production.py").read_text()
    assert "GM cannot manually clear survey observations" in gm
    assert "gm_clear_obs_" not in gm

def test_dm_ui_does_not_offer_pre_gm_clearance():
    dm = (ROOT / "components" / "dm_production.py").read_text()
    assert "Observation closure is deliberately unavailable here." in dm
    assert "dm_clear_" not in dm
