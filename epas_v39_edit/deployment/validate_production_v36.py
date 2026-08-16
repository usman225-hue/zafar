from pathlib import Path
import ast, re, sys
ROOT=Path(__file__).resolve().parents[1]

def fail(msg):
    print('FAIL:',msg); sys.exit(1)

required=[
'app.py','database/production_queries.py','database/production_v3_6_final_query_consolidation.sql',
'components/stakeholder_cockpits_v36.py','components/professional_center_v36.py','components/survey_lifecycle_v36.py',
'deployment/entrypoint_v36.sh','deployment/supabase_cron_v36.sql','README_V3_6_FINAL.md'
]
for p in required:
    if not (ROOT/p).exists(): fail(f'missing {p}')
app=(ROOT/'app.py').read_text()
if 'render_survey_lifecycle_v36' not in app: fail('active survey lifecycle is not v3.6')
if 'components.professional_center_v36' not in app: fail('active professional center is not v3.6')
for p in (ROOT/'components').glob('*.py'):
    if 'database.queries' in p.read_text(): fail(f'legacy query import in {p}')
queries=(ROOT/'database/production_queries.py').read_text()
for token in ['epas_schedule_queue_v36','epas_scheduler_health_v36','epas_mark_in_service_cycle_complete_v36','epas_set_in_service_schedule_basis_v36']:
    if token not in queries: fail(f'missing active query facade {token}')
sql=(ROOT/'database/production_v3_6_final_query_consolidation.sql').read_text()
for token in ['epas_scheduler_tick_v36','epas_schedule_queue_v35','V36_ACTIVE_COMPONENTS_CANONICAL']:
    if token not in sql: fail(f'missing SQL hardening marker {token}')
print('EPAS v3.6 production release validation: PASS')
