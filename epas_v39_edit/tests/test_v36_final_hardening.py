from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def read(p): return (ROOT/p).read_text()

def test_legacy_query_module_is_thin_shim():
    src=read('database/queries.py')
    assert 'in-memory' not in src.lower() and 'demo' not in src.lower()
    assert 'from .production_queries import *' in src

def test_active_components_use_production_queries():
    bad=[]
    for p in (ROOT/'components').glob('*.py'):
        s=p.read_text()
        if 'database.queries' in s and p.name!='queries.py': bad.append(str(p))
    assert not bad, bad

def test_v35_active_wrappers_call_v35_rpc_names():
    src=read('database/production_queries.py')
    assert "_rpc_read('epas_schedule_queue_v36'" in src or "_rpc_read('epas_schedule_queue_v35'" in src
    assert "_rpc_read('epas_scheduler_health_v36'" in src or "_rpc_read('epas_scheduler_health_v35'" in src
    assert "_rpc('epas_mark_in_service_cycle_complete_v36'" in src or "_rpc('epas_mark_in_service_cycle_complete_v35'" in src
    assert "_rpc('epas_set_in_service_schedule_basis_v36'" in src or "_rpc('epas_set_in_service_schedule_basis_v35'" in src

def test_clamav_entrypoint_present():
    d=read('Dockerfile'); e=read('deployment/entrypoint_v36.sh')
    assert 'clamav-freshclam' in d
    assert 'freshclam' in e

def test_v36_ux_hooks_present():
    s=read('components/survey_lifecycle_v35.py')
    assert 'Survey Start Readiness' in s
    assert 'READY TO START SURVEY' in s
    owner=read('components/stakeholder_cockpits_v35.py')
    assert 'Fleet focus' in owner
    assert 'NSC Journey' in owner
