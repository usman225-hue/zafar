from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_production_entrypoint_has_no_demo_actor_switcher():
    app = (ROOT / 'app.py').read_text()
    assert 'dev_advance_stage' not in app
    assert 'workflow_actor_id' not in app
    assert 'Demo login' not in app


def test_production_modules_do_not_use_legacy_demo_store():
    for rel in ['components/gm_production.py','components/dm_production.py','database/production_queries.py','config/production_auth.py']:
        text = (ROOT / rel).read_text()
        assert 'is_demo_mode' not in text
        assert 'build_seed_db' not in text


def test_required_production_files_exist():
    for rel in [
        'database/production_schema.sql',
        'database/production_queries.py',
        'components/auth_gate.py',
        'components/gm_production.py',
        'components/dm_production.py',
        'config/production_auth.py',
        'docs/GM_DM_PRODUCTION_WORKFLOW.mmd',
    ]:
        assert (ROOT / rel).exists(), rel
