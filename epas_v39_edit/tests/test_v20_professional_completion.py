from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SQL=(ROOT/'database/production_v2_0_professional_completion.sql').read_text()
APP=(ROOT/'app.py').read_text()
CENTER=(ROOT/'components/professional_center.py').read_text()


def test_sla_control_tower():
    assert 'workflow_task_sla_history' in SQL
    assert 'epas_sla_dashboard' in SQL
    assert 'BREACHED' in SQL and 'DUE_SOON' in SQL
    assert 'SLA control tower' in CENTER


def test_escalation_action_is_linked_and_synced():
    assert 'linked_task_id' in SQL
    assert 'epas_sync_escalation_action' in SQL
    assert 'trg_epas_sync_escalation_action' in SQL


def test_governance_integration():
    assert 'governance_entity_links' in SQL
    assert 'epas_link_governance_entity' in SQL
    assert 'epas_governance_register' in SQL


def test_closure_is_professional_gate():
    for code in ['SLA_BREACHES','INTERIM_CERTIFICATE','OPEN_RISKS','AUDIT_TRAIL']:
        assert code in SQL
    assert 'epas_refresh_closure_readiness' in SQL


def test_security_preflight_and_acceptance_cases():
    assert 'security_acceptance_cases' in SQL
    assert 'epas_security_preflight' in SQL
    for code in ['SEC-RLS-001','SEC-STG-001','SEC-RPC-001','SEC-XPROJ-001','SEC-LEAK-001']:
        assert code in SQL


def test_role_dashboard_and_work_queue():
    assert 'epas_role_dashboard_summary' in SQL
    assert 'epas_role_dashboard_detail' in SQL
    assert 'epas_my_work_queue' in SQL
    assert 'Professional Operations Center' in CENTER
    assert 'render_professional_center' in APP


def test_rfi_business_rule_remains_authoritative():
    v19=(ROOT/'database/production_v1_9_role_complete_gaps_11_20.sql').read_text()
    assert "v_role='shipyard' and p_phase<>'nsc_survey'" in v19
    assert "v_role in ('owner','ship_management') and p_phase<>'in_service'" in v19
