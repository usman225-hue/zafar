# EPAS v3.2 — Final Performance, Security, Workflow & UX Hardening

EPAS v3.2 is the cumulative Streamlit release based on v3.1. It focuses on the remaining production-hardening items from the full frontend/backend/security/workflow audit.

### Core controls
- Session-scoped authenticated Supabase clients.
- Bounded session-local LRU read cache.
- Canonical v3.2 survey-control RPC facade.
- Explicit revocation of lower-version survey-control RPCs from authenticated callers.
- Bundle-based project health reads for GM portfolio screens.
- Role-authorized project-list RPC for stakeholder/designer surfaces.
- Controlled certificate upload with rollback-on-registration-failure.
- Actual file hash, MIME and size provenance.
- Persistent recurring In-Service cycles.
- Explicit schedule basis/date/interval.
- Service-role-only v3.2 scheduler.
- Stakeholder phase restrictions: Shipyard NSC only; Owner/Ship Management In-Service only.
- v3.2 role-aware schedule, timeline and internal gate wrappers.

### Deployment order
Apply cumulative migrations through v3.1, then apply:

`database/production_v3_2_final_performance_security_ux.sql`

Install the managed scheduler using:

`deployment/supabase_cron_v32.sql`

### Validation
The included static suite is expected to be green. Live acceptance must still be executed against an actual Supabase project with real GM, DM, Engineer, Surveyor, Designer, Shipyard, Owner and Ship Management accounts.
