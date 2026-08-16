from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'database' / 'production_v1_8_role_complete_hardening.sql').read_text()
PQ = (ROOT / 'database' / 'production_queries.py').read_text()
DM = (ROOT / 'components' / 'dm_production.py').read_text()
RW = (ROOT / 'components' / 'role_workspaces.py').read_text()


def test_exact_observation_binding_is_server_enforced():
    assert 'corrective_action_observations' in SQL
    assert 'p_observation_ids uuid[]' in SQL
    assert 'Every selected observation must belong to this RFI and remain open' in SQL
    assert 'already assigned to another corrective action' in SQL
    assert 'dm_issue_corrective(action[\'id\'],aid,instruction,due,selected_obs)' in DM


def test_generic_observation_clearance_is_revoked():
    assert 'revoke execute on function epas_clear_survey_observation(uuid,text)' in SQL.lower()
    assert 'epas_dm_verify_corrective_action' in SQL
    assert 'observation_verifications' in SQL
    assert 'controlled_closure' in SQL


def test_follow_up_requires_verified_action():
    assert "if v_action.status<>'verified'" in SQL
    assert "Follow-up type: '||v_type" in SQL
    assert 'follow_up_of_rfi_id' in SQL


def test_stakeholder_rfi_write_boundary():
    assert 'revoke insert,update,delete on rfis from authenticated,anon' in SQL.lower()
    assert 'epas_stakeholder_create_rfi' in SQL
    assert "v_role not in ('owner','ship_management','shipyard')" in SQL
    assert 'GM_SURVEY_RFI_INTAKE' in SQL
    assert 'stakeholder_create_rfi' in PQ
    assert 'phase_by_role' in RW



def test_stakeholder_rfi_phase_permissions_are_role_specific():
    assert "v_role='shipyard' and p_phase<>'nsc_survey'" in SQL
    assert "v_role in ('owner','ship_management') and p_phase<>'in_service'" in SQL
    assert 'Shipyard may initiate NSC Survey RFIs only' in SQL
    assert 'Owner and Ship Management may initiate In-Service Survey RFIs only' in SQL
    assert "'shipyard': ('nsc_survey','NSC Survey')" in RW
    assert "'owner': ('in_service','In-Service Survey')" in RW
    assert "'ship_management': ('in_service','In-Service Survey')" in RW

def test_certificate_state_machine():
    for state in ['DRAFT','PENDING_GM_APPROVAL','GM_APPROVED','PENDING_DM_ACK','READY_FOR_ISSUANCE','ISSUED','ACTIVE','EXPIRING','EXPIRED','SUPERSEDED']:
        assert state in SQL
    assert 'epas_transition_certificate_state' in SQL
    assert 'epas_refresh_certificate_lifecycle' in SQL


def test_document_lifecycle_and_policy():
    for marker in ['document_policies','document_lifecycle_events','epas_document_transition','epas_register_document_revision']:
        assert marker in SQL
    assert 'parent_document_id' in SQL
    assert 'supersedes_document_id' in SQL
    assert 'revision_no' in SQL


def test_security_preflight_exists():
    assert 'epas_security_preflight' in SQL
    assert 'RFI_WRITE_LOCK' in SQL
    assert 'OBSERVATION_GENERIC_CLEAR_REVOKED' in SQL


def test_query_and_ui_contracts_exist():
    assert re.search(r'def dm_issue_corrective\(.*observation_ids', PQ, re.S)
    assert 'def dm_verify_corrective' in PQ
    assert 'Exact observations resolved by this corrective action' in DM
