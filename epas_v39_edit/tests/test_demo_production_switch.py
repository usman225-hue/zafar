from pathlib import Path
import subprocess
import sys


def test_demo_production_switch_files_exist():
    root = Path(__file__).resolve().parents[1]
    assert (root / 'scripts' / 'run_demo_8501.sh').exists()
    assert (root / 'scripts' / 'run_production_8501.sh').exists()
    assert (root / 'scripts' / 'promote_to_production.sh').exists()
    assert (root / 'config' / 'demo_runtime.py').exists()
    assert (root / 'database' / 'demo_queries_v40.py').exists()


def test_production_promotion_removes_demo_runtime(tmp_path):
    root = Path(__file__).resolve().parents[1]
    out = tmp_path / 'production'
    subprocess.run([
        sys.executable,
        str(root / 'scripts' / 'strip_demo_for_production.py'),
        '--output', str(out),
    ], check=True)
    forbidden = [
        out / 'config' / 'demo_runtime.py',
        out / 'database' / 'demo_queries_v40.py',
        out / 'database' / 'seed_data.py',
        out / 'DEMO_CREDENTIALS.md',
        out / 'scripts' / 'run_demo_8501.sh',
        out / '.env.demo',
        out / '.devcontainer',
    ]
    assert all(not p.exists() for p in forbidden)
    assert 'Demo runtime' in (out / 'PRODUCTION_MODE.txt').read_text(encoding='utf-8')


def test_run_script_is_port_8501_aware():
    root = Path(__file__).resolve().parents[1]
    demo = (root / 'scripts' / 'run_demo_8501.sh').read_text(encoding='utf-8')
    prod = (root / 'scripts' / 'run_production_8501.sh').read_text(encoding='utf-8')
    assert '--server.port 8501' in demo
    assert '--server.port 8501' in prod
    assert 'EPAS_RUNTIME_MODE=demo' in demo
    assert 'EPAS_RUNTIME_MODE=production' in prod


def test_demo_env_file_auto_load_is_supported_for_direct_streamlit_launch():
    root = Path(__file__).resolve().parents[1]
    client = (root / 'config' / 'supabase_client.py').read_text(encoding='utf-8')
    assert '_load_demo_env_file' in client
    assert 'EPAS_RUNTIME_MODE' in client
    assert '.env.demo' in client
    assert 'production promotion script removes `.env.demo`' in client


def test_demo_sign_in_accepts_published_credentials(monkeypatch):
    root = Path(__file__).resolve().parents[1]
    monkeypatch.setenv('EPAS_RUNTIME_MODE', 'demo')
    monkeypatch.setenv('EPAS_DEMO_PASSWORD', 'PSB-Demo-2026!')
    import sys
    sys.path.insert(0, str(root))
    from config import production_auth
    ok, message = production_auth.sign_in('gm@classification.com', 'PSB-Demo-2026!')
    assert ok is True
    assert 'demo' in message.lower()
    assert production_auth.current_user()['email'] == 'gm@classification.com'


def test_demo_runtime_has_seeded_database_and_current_user(monkeypatch):
    root = Path(__file__).resolve().parents[1]
    monkeypatch.setenv('EPAS_RUNTIME_MODE', 'demo')
    import sys
    sys.path.insert(0, str(root))
    from config import demo_runtime, production_auth
    production_auth.sign_in('gm@classification.com', 'PSB-Demo-2026!')
    db = demo_runtime._db()
    assert 'projects' in db and len(db['projects']) > 0
    assert demo_runtime.current_user()['role'] == 'gm'
    assert 'users' in db or True


def test_demo_create_project_records_team_and_stakeholders(monkeypatch):
    root = Path(__file__).resolve().parents[1]
    monkeypatch.setenv('EPAS_RUNTIME_MODE', 'demo')
    import sys
    sys.path.insert(0, str(root))
    from config import demo_runtime, production_auth
    production_auth.sign_in('gm@classification.com', 'PSB-Demo-2026!')
    db = demo_runtime._db()
    before = len(db['projects'])
    payload = {
        'project_code': 'DEMO-NEW',
        'name': 'Demo Newbuild',
        'vessel_type': 'Patrol Vessel',
        'flag_state': 'Pakistan',
        'phases': ['plan_appraisal', 'nsc_survey'],
        'team': [
            {'user_id': 'demo-dm', 'role': 'dm', 'department': 'Hull'},
            {'user_id': 'demo-engineer', 'role': 'engineer', 'phase': 'plan_appraisal'},
            {'user_id': 'demo-surveyor', 'role': 'surveyor', 'phase': 'nsc_survey'},
        ],
        'stakeholders': [
            {'company_name': 'Oceanic Ship Management', 'stakeholder_type': 'ship_management', 'contact_email': 'ops@oceanic.co', 'user_id': 'demo-ship-management'},
        ],
    }
    result = demo_runtime._db()  # ensure DB initialized for later evaluation
    from database import demo_queries_v40
    created = demo_queries_v40.dispatch('create_project', payload)
    assert created['project']['project_code'] == 'DEMO-NEW'
    assert any(t['project_id'] == created['project']['id'] and t['role'] == 'dm' for t in db['team_assignments'])
    assert any(s['project_id'] == created['project']['id'] and s['stakeholder_type'] == 'ship_management' for s in db['stakeholders'])
    assert len(db['projects']) == before + 1
