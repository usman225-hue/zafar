"""EPAS v3.3 live acceptance harness.

Requires a deployed Supabase project and role accounts. This script is intentionally
non-destructive by default and prints the exact acceptance cases. Use the project
Admin/SQL environment to execute the case-specific negative tests against RLS and
Storage. It never embeds credentials in the repository.
"""
from __future__ import annotations
import os, sys

CASES = [
    'RLS_CROSS_PROJECT','STORAGE_CROSS_PROJECT','SESSION_ISOLATION',
    'NSC_ONLY_SHIPYARD','INSERVICE_OWNER_ONLY','INSERVICE_SHIP_MANAGEMENT_ONLY',
    'ENGINEER_ONLY_MARKUP','SURVEYOR_ONLY_ASSIGNED_SURVEY','DM_ONLY_CERTIFICATE_ACK',
    'INSERVICE_CYCLE_1_TO_2','CERTIFICATE_UPLOAD_ROLLBACK','SCHEDULER_EXECUTION',
    'LARGE_FILE_CONCURRENCY','AUDIT_CHAIN_INTEGRITY'
]

def main() -> int:
    print('EPAS v3.3 live acceptance checklist')
    print('SUPABASE_URL configured:', bool(os.getenv('SUPABASE_URL')))
    print('SUPABASE_SERVICE_ROLE_KEY configured:', bool(os.getenv('SUPABASE_SERVICE_ROLE_KEY')))
    for case in CASES:
        print(f'- {case}')
    if not os.getenv('SUPABASE_URL'):
        print('No live environment configured; checklist only.', file=sys.stderr)
        return 2
    print('Run role-by-role browser/API checks against the supplied project and record evidence in epas_live_acceptance_runs_v33.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
