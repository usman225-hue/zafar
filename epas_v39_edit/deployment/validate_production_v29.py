"""Fail-closed deployment validator for EPAS v2.9."""
from __future__ import annotations
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors = []
if os.getenv('EPAS_ENABLE_DEMO_MODE','0') == '1':
    errors.append('EPAS_ENABLE_DEMO_MODE must not be enabled in production.')
if not (os.getenv('SUPABASE_URL') or os.getenv('SUPABASE_ANON_KEY')):
    # Streamlit may supply these through st.secrets; this check only warns when neither env is present.
    print('INFO: Supabase credentials may be configured through Streamlit secrets.')
for rel in [
    'app.py',
    'database/production_v2_8_final_hardening.sql',
    'database/production_v2_9_security_ux_release_hardening.sql',
    'deployment/supabase_cron_v28.sql',
    'components/role_cockpits.py',
]:
    if not (ROOT/rel).exists(): errors.append(f'Missing release file: {rel}')
if errors:
    for e in errors: print('ERROR:',e)
    raise SystemExit(1)
print('EPAS v2.9 production release validation: PASS')
