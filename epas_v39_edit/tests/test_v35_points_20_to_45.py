from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def test_v35_release_files_present():
    required = [
        'database/production_v3_5_final_role_ux_scheduler.sql',
        'components/stakeholder_cockpits_v35.py',
        'components/survey_lifecycle_v35.py',
        'components/professional_center_v35.py',
        'deployment/live_acceptance_v35.py',
        'deployment/load_test_v35.py',
        'deployment/supabase_cron_v35.sql',
        'deployment/validate_production_v35.py',
        'README_V3_5_FINAL.md',
    ]
    assert all((ROOT / p).exists() for p in required)


def test_v35_stakeholder_bundles_exist():
    sql = read('database/production_v3_5_final_role_ux_scheduler.sql')
    for token in [
        'epas_owner_fleet_bundle_v35',
        'epas_ship_management_bundle_v35',
        'epas_shipyard_nsc_bundle_v35',
        'epas_coordination_timeline_v35',
        'epas_project_phase_workflow_v35',
        'epas_scheduler_tick_v35',
        'epas_audit_chain_verify_v35',
    ]:
        assert token in sql


def test_scheduler_does_not_delegate_to_old_scheduler():
    sql = read('database/production_v3_5_final_role_ux_scheduler.sql')
    start = sql.index('create or replace function epas_scheduler_tick_v35')
    end = sql.index('-- ================================================================\n-- 5. Security allowlist', start)
    body = sql[start:end]
    assert 'epas_scheduler_tick_v32' not in body
    assert 'epas_scheduler_tick_v31' not in body
    assert 'epas_scheduler_tick_v29' not in body


def test_active_app_is_v35():
    app = read('app.py')
    assert 'v3.9' in app
    assert 'survey_lifecycle_v36' in app or 'survey_lifecycle_v35' in app
    assert 'professional_center_v36' in app or 'professional_center_v35' in app


def test_authenticated_client_is_session_scoped_v35():
    src = read('config/supabase_client.py')
    assert 'st.session_state' in src
    assert 'st.cache_resource' not in src
    assert 'epas_supabase_client_v35' in src


def test_stakeholder_rules_remain_explicit():
    sql = ''.join(read(p) for p in [
        'database/production_v1_6_flow_alignment.sql',
        'database/production_v3_5_final_role_ux_scheduler.sql',
    ])
    assert "('shipyard','nsc_survey',true" in sql or "('shipyard','nsc_survey',true" in sql.replace(' ', '')
    assert "('shipyard','in_service',false" in sql or "('shipyard','in_service',false" in sql.replace(' ', '')
    assert "('owner','in_service',true" in sql or "('owner','in_service',true" in sql.replace(' ', '')
    assert "('ship_management','in_service',true" in sql or "('ship_management','in_service',true" in sql.replace(' ', '')


def test_accessibility_css_and_responsive_hooks():
    css = read('styles/theme.py')
    assert 'focus-visible' in css
    assert 'prefers-reduced-motion' in css
    assert '@media (max-width: 640px)' in css


def test_role_specific_frontend_panels():
    src = read('components/stakeholder_cockpits_v35.py')
    for token in ['owner_fleet', 'ship_management_operations', 'shipyard_nsc_operations']:
        assert token in src
