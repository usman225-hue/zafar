"""EPAS v3.5 static release validator."""
from __future__ import annotations
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
REQUIRED=[
 'app.py','requirements.txt','config/supabase_client.py','database/production_v3_5_final_role_ux_scheduler.sql',
 'components/stakeholder_cockpits_v35.py','components/survey_lifecycle_v35.py','components/professional_center_v35.py',
 'deployment/supabase_cron_v35.sql','deployment/live_acceptance_v35.py','deployment/load_test_v35.py'
]

def main():
    missing=[p for p in REQUIRED if not (ROOT/p).exists()]
    if missing:
        print('Missing:', *missing, sep='\n- ')
        return 1
    app=(ROOT/'app.py').read_text()
    checks=[
        ('v3.5 app', 'v3.5 Production' in app),
        ('session-scoped client', 'epas_supabase_client_v35' in (ROOT/'config/supabase_client.py').read_text()),
        ('owner fleet', 'owner_fleet_bundle_v35' in (ROOT/'database/production_v3_5_final_role_ux_scheduler.sql').read_text()),
        ('ship management', 'ship_management_actions_v35' in (ROOT/'database/production_v3_5_final_role_ux_scheduler.sql').read_text()),
        ('shipyard NSC', 'shipyard_nsc_bundle_v35' in (ROOT/'database/production_v3_5_final_role_ux_scheduler.sql').read_text()),
        ('self-contained scheduler', 'epas_scheduler_tick_v35' in (ROOT/'database/production_v3_5_final_role_ux_scheduler.sql').read_text()),
        ('accessibility CSS', 'prefers-reduced-motion' in (ROOT/'styles/theme.py').read_text()),
    ]
    bad=[name for name,ok in checks if not ok]
    for name,ok in checks: print(('PASS ' if ok else 'FAIL ')+name)
    return 1 if bad else 0

if __name__=='__main__': sys.exit(main())
