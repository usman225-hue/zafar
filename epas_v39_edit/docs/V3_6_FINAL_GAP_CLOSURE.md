# EPAS v3.6 Final Gap Closure

## Closed
1. Active production query bindings no longer call v3.3 RPCs for schedule/health/cycle/basis flows.
2. Legacy `database.queries` implementation is archived and replaced with a production-only compatibility shim.
3. Active components no longer import the legacy query implementation.
4. Owner fleet has KPI-driven focus filtering.
5. Ship Management corrective-action cards are consolidated.
6. Shipyard has an explicit NSC journey tracker.
7. GM has a decision-focus control.
8. Surveyor has a prominent readiness gate.
9. ClamAV database refresh is attempted at container startup.
10. Accessibility focus styles and reduced-motion behavior remain active.

## Live evidence still required
- Eight-role RLS/Storage acceptance against a real Supabase deployment.
- Concurrent upload/load test in the target deployment.
- Cron execution verification.
