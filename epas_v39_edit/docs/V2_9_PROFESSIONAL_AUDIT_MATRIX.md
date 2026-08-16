# EPAS v2.9 Professional Audit Matrix

| Domain | v2.8 finding | v2.9 control | Evidence in package |
|---|---|---|---|
| RLS | New operational tables lacked complete RLS | RLS + scoped policies | `database/production_v2_9_security_ux_release_hardening.sql` |
| SECURITY DEFINER | Read RPCs lacked consistent caller checks | v2.9 authorized wrappers + revokes | same migration |
| Stakeholder boundary | Schedule/timeline phase leakage risk | phase-aware access helper | same migration |
| Report integrity | Synthetic hash fallback | actual PDF hash required | same migration + query/UI |
| Demo runtime | Implicit fallback possible | explicit opt-in only / fail closed | `config/supabase_client.py` |
| In-Service recurrence | Phase/cycle confusion | cycle instances + idempotent completion | same migration |
| Scheduler | Failure was swallowed | failure table + degraded health | same migration |
| Concurrency | transition replay risk | row version/idempotency fields | same migration |
| Certificate acknowledgement | not package-version bound | v2.9 fingerprinted acknowledgement | same migration |
| UX | generic admin surfaces | role decision cockpits | `components/role_cockpits.py` |
| Responsive | desktop-first only | responsive CSS | `styles/theme.py` |
| Accessibility | limited | focus-visible / reduced-motion / text states | `styles/theme.py` |
| External fonts | third-party dependency | system-safe fonts | `styles/theme.py` |

## Role scope
- GM: full internal governance and approval.
- DM: allocation, readiness, verification and acknowledgement.
- Engineer: Plan Appraisal.
- Surveyor: assigned survey execution only.
- Designer: drawing submission/revision only.
- Shipyard: NSC RFI and released NSC information only.
- Owner: In-Service RFI and fleet/ship status information only.
- Ship Management: In-Service RFI + assigned corrective actions/evidence.
