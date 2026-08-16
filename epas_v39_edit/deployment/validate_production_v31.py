"""Static release validator for EPAS v3.1."""
from __future__ import annotations
from pathlib import Path
import ast

ROOT=Path(__file__).resolve().parents[1]
REQUIRED=[
    'app.py','requirements.txt','Dockerfile','run_streamlit.sh',
    'config/supabase_client.py','config/production_auth.py',
    'database/production_queries.py',
    'database/production_v3_0_final_release_hardening.sql',
    'database/production_v3_1_performance_security_final.sql',
    'deployment/supabase_cron_v31.sql',
    'utils/session_cache.py', 'utils/file_validation.py',
]

def main()->int:
    missing=[p for p in REQUIRED if not (ROOT/p).exists()]
    if missing:
        print('MISSING:', ', '.join(missing)); return 2
    app=(ROOT/'app.py').read_text()
    client=(ROOT/'config/supabase_client.py').read_text()
    sql=(ROOT/'database/production_v3_1_performance_security_final.sql').read_text().lower()
    ast.parse(app)
    ast.parse(client)
    checks=[
        ('no global cached auth client','@st.cache_resource' not in client),
        ('session-scoped client','epas_supabase_client_v31' in client),
        ('scheduler service-only',"current_user<>'service_role'" in sql),
        ('role dashboard bundle','epas_role_dashboard_bundle_v31' in sql),
        ('final storage policy','epas_project_documents_select_v31' in sql),
        ('cycle no silent interval','epas_mark_in_service_cycle_complete_v31' in sql and 'schedule interval/basis is not configured' in sql),
        ('scheduler cron','epas-v31-lifecycle-tick' in (ROOT/'deployment/supabase_cron_v31.sql').read_text()),
    ]
    failed=[name for name,ok in checks if not ok]
    if failed:
        print('FAILED:', ', '.join(failed)); return 3
    print('EPAS v3.1 production release validation: PASS')
    return 0

if __name__=='__main__':
    raise SystemExit(main())
