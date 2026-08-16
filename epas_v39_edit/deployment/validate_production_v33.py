from __future__ import annotations
from pathlib import Path
import subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
REQUIRED=[
    ROOT/'app.py', ROOT/'database/production_v3_3_final_hardening.sql',
    ROOT/'deployment/supabase_cron_v33.sql', ROOT/'deployment/live_acceptance_v33.py',
    ROOT/'components/survey_lifecycle_v33.py', ROOT/'utils/session_cache.py', ROOT/'utils/file_security.py'
]
for p in REQUIRED:
    if not p.exists(): raise SystemExit(f'Missing release file: {p}')
client=(ROOT/'config/supabase_client.py').read_text()
if '@st.cache_resource' in client: raise SystemExit('Authenticated Supabase client must not be globally cached')
q=(ROOT/'database/production_queries.py').read_text()
for marker in ['epas_schedule_queue_v33','epas_timeline_v33','epas_survey_start_gate_v33','epas_register_certificate_pdf_v33','epas_submit_survey_report_v33']:
    if marker not in q: raise SystemExit(f'Missing active v3.3 query binding: {marker}')
print('EPAS v3.3 production release structure: PASS')
