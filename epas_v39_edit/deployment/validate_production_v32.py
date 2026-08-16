from __future__ import annotations
from pathlib import Path
import subprocess, sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    ROOT / 'app.py',
    ROOT / 'database/production_v3_2_final_performance_security_ux.sql',
    ROOT / 'deployment/supabase_cron_v32.sql',
    ROOT / 'components/survey_lifecycle_v32.py',
    ROOT / 'utils/session_cache.py',
]

for path in REQUIRED:
    if not path.exists():
        raise SystemExit(f'Missing release file: {path}')

client = (ROOT/'config/supabase_client.py').read_text()
if '@st.cache_resource' in client:
    raise SystemExit('Authenticated Supabase client must not be globally cached')

print('EPAS v3.2 release structure: PASS')
print('Run `python -m compileall .` and `pytest -q` for full static validation.')
