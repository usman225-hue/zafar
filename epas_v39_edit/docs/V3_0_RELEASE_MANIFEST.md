# EPAS v3.0 Release Manifest

## Baseline
EPAS v2.9 cumulative package.

## Final release assets
- `database/production_v3_0_final_release_hardening.sql`
- `deployment/supabase_cron_v30.sql`
- `deployment/live_acceptance_v30.py`
- `docs/V3_0_FINAL_PRODUCTION_ACCEPTANCE.md`
- `docs/V3_0_FINAL_GAP_CLOSURE_MATRIX.md`
- `tests/test_v30_final_release.py`

## Application
- Streamlit entrypoint: `app.py`
- Production auth: `config/production_auth.py`
- Production Supabase client: `config/supabase_client.py`
- Query layer: `database/production_queries.py`

## Release policy
This release uses a single current v3.0 API layer for newly hardened schedule/timeline/gate/report functions while retaining historical migrations for upgrade reproducibility. High-risk obsolete lifecycle RPCs are explicitly revoked from `authenticated` by the v3.0 migration.
