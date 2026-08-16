"""Static production release validator for EPAS v3.0."""
from __future__ import annotations
from pathlib import Path
import ast

ROOT=Path(__file__).resolve().parents[1]
REQUIRED=[
    ROOT/'app.py',
    ROOT/'requirements.txt',
    ROOT/'run_streamlit.sh',
    ROOT/'database'/'production_v3_0_final_release_hardening.sql',
    ROOT/'deployment'/'supabase_cron_v30.sql',
    ROOT/'deployment'/'live_acceptance_v30.py',
    ROOT/'components'/'role_cockpits.py',
    ROOT/'utils'/'file_validation.py',
]
for path in REQUIRED:
    if not path.exists():
        raise SystemExit(f'FAIL: missing required release asset: {path.relative_to(ROOT)}')

for path in ROOT.rglob('*.py'):
    if '.pytest_cache' in path.parts or '__pycache__' in path.parts:
        continue
    ast.parse(path.read_text(encoding='utf-8'), filename=str(path))

sql=(ROOT/'database'/'production_v3_0_final_release_hardening.sql').read_text(encoding='utf-8')
for token in [
    'enable row level security',
    'epas_schedule_queue_v30',
    'epas_timeline_v30',
    'epas_mark_in_service_cycle_complete_v30',
    'epas_submit_survey_report_v30',
    'epas_privilege_registry_v30',
    'epas_audit_chain_hash_v30',
]:
    if token.lower() not in sql.lower():
        raise SystemExit(f'FAIL: required v3.0 control missing: {token}')
print('EPAS v3.0 production release validation: PASS')
