# EPAS v2.8 Release Manifest

## Baseline
EPAS v2.7 final complete Streamlit package.

## New migration
`database/production_v2_8_final_hardening.sql`

## New scheduler deployment
`deployment/supabase_cron_v28.sql`

## Updated runtime surfaces
- `components/survey_lifecycle_v27.py` — v2.8 schedule basis UX and v2.8 queue
- `components/professional_center.py` — explicit basis date and v2.8 queue integration
- `database/production_queries.py` — v2.8 RPC bindings

## Validation
- Python compileall: PASS
- Static/regression tests: 145 passed, 1 skipped (Streamlit browser runtime unavailable in build environment)
- Streamlit release validation: PASS

## Runtime acceptance still performed during deployment
- Live Supabase RLS/Storage isolation
- Live Cron execution
- Live end-to-end Cycle 1 → Cycle 2 In-Service lifecycle
- Live eight-role browser acceptance
