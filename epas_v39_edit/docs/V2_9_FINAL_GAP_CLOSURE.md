# EPAS v2.9 Final Gap Closure

## Purpose
EPAS v2.9 is the cumulative hardening release after the v2.8 backend/security/frontend audit. It addresses the outstanding gaps from the coding, workflow, frontend and security reviews.

## Closed areas

### Backend / workflow
- Persistent In-Service phase with recurring cycle instances.
- Idempotent cycle completion and unique cycle numbering.
- Explicit schedule basis, basis date, reference, fingerprint and history.
- Project-scoped manual lifecycle mutations.
- Per-vessel scheduler failure records and degraded-health state.
- Scope amendment invalidation of acknowledgements, drawing packages, checklist and execution basis.
- Version/fingerprint-bound assignment, scope, drawing package and checklist controls.
- Exact survey execution basis.
- Actual PDF SHA-256 required for survey reports; synthetic hash fallback removed.
- Certificate acknowledgement version/fingerprint controls.
- Stakeholder-safe schedule/timeline reads.

### Security
- RLS enabled on all new v2.8 operational tables.
- SECURITY DEFINER read wrappers now perform caller/project/phase authorization.
- Shipyard restricted to NSC schedule/timeline data; Owner and Ship Management restricted to In-Service operational data.
- Legacy direct RPC execution revoked where a secure v2.9 wrapper now exists.
- Production client is fail-closed by default. Demo mode requires explicit non-production opt-in.
- Scheduler is service-role-only.
- Audit records gain a tamper-evident previous-hash/event-hash chain.

### Frontend / UX
- Role-specific decision cockpits for GM, DM, Engineer, Surveyor, Designer, Owner, Ship Management and Shipyard.
- State → blocker → next action language added to the top of each role workspace.
- Responsive layout rules for smaller screens.
- Visible focus state and reduced-motion support.
- External Google Fonts dependency removed; typography uses local/system-safe fallbacks.
- High-impact operations retain controlled backend gates; frontend errors now surface a safe reference code rather than raw database errors in core professional surfaces.
- Owner/Shipyard role experiences are differentiated by phase and data boundary.

## Remaining deployment evidence
The release intentionally does not fabricate live production evidence. Final acceptance still requires running the included live tests against the actual Supabase project with separate accounts for all eight roles and confirming Supabase Cron is installed and executing `epas_scheduler_tick_v29()`.
