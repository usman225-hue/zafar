"""EPAS v3.5 live acceptance harness.
Prints non-destructive acceptance cases and validates that required environment
variables are present. Actual role/RLS/Storage execution must be performed in
an authorized deployed Supabase project.
"""
from __future__ import annotations
import os

CASES = [
    'V35_OWNER_FLEET', 'V35_SHIP_MGMT_ACTION_CARD', 'V35_SHIPYARD_NSC_CONSOLE',
    'V35_COORDINATION_TIMELINE', 'V35_PHASE_WORKFLOW', 'V35_RECURRING_IN_SERVICE',
    'V35_SELF_CONTAINED_SCHEDULER', 'V35_GATE_DATA_MINIMIZATION', 'V35_AUDIT_CHAIN',
    'V35_FILE_SECURITY', 'LIVE_RLS_CROSS_PROJECT', 'LIVE_STORAGE_CROSS_PROJECT',
    'LIVE_SESSION_ISOLATION', 'LIVE_CRON_EXECUTION', 'LIVE_LOAD_10_USERS', 'LIVE_LOAD_30_USERS'
]

def main() -> int:
    print('EPAS v3.5 live acceptance checklist')
    print('SUPABASE_URL configured:', bool(os.getenv('SUPABASE_URL')))
    print('SUPABASE_SERVICE_ROLE_KEY configured:', bool(os.getenv('SUPABASE_SERVICE_ROLE_KEY')))
    print('EPAS_REQUIRE_ANTIVIRUS:', os.getenv('EPAS_REQUIRE_ANTIVIRUS', '0'))
    for case in CASES:
        print(f'- {case}')
    if not os.getenv('SUPABASE_URL'):
        print('No live environment configured; checklist only.')
        return 2
    print('Use the deployed Supabase project and eight role accounts to execute the listed cases and record evidence.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
