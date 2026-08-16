"""Final live acceptance checklist runner for EPAS v3.6.
Requires real Supabase credentials/accounts; intentionally does not fabricate pass results.
"""
CASES=['eight-role RLS','Storage isolation','Shipyard NSC-only','Owner In-Service-only','Ship Management In-Service-only','Cycle 1 -> Cycle 2','scheduler execution','audit-chain integrity','concurrent user session isolation']
if __name__=='__main__':
    print('EPAS v3.6 live acceptance cases:')
    for c in CASES: print('-',c)
