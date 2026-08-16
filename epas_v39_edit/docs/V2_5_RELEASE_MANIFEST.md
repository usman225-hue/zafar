# EPAS v2.5 Release Manifest

## Baseline
EPAS v2.4 complete package, cumulatively retained.

## New migration
`database/production_v2_5_workflow_enforcement_hardening.sql`

## Application changes
- `database/production_queries.py` — v2.5 RPC/service wrappers
- `components/professional_center.py` — Survey Control operational surface
- `tests/test_v25_workflow_enforcement.py` — v2.5 static regression tests

## Documentation
- `docs/V2_5_WORKFLOW_ENFORCEMENT_GAP_CLOSURE.md`
- `docs/V2_5_RELEASE_MANIFEST.md`
- `docs/V2_5_FINAL_WORKFLOW_AUDIT.md`

## Validation
- Non-browser pytest suite: 97 passed
- Python compilation: passed
- Streamlit/browser smoke suite: requires Streamlit/live Supabase deployment and is not claimed as passed in this environment
