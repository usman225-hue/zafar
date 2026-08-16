# EPAS v2.4 Release Manifest

Baseline: EPAS v2.3 complete surveyor drawing handover package.

Migration:
- `database/production_v2_4_state_of_art_lifecycle.sql`

Application additions:
- lifecycle/survey schedule control tower in `components/professional_center.py`
- v2.4 production RPC wrappers in `database/production_queries.py`

Tests:
- `tests/test_v24_state_of_art_lifecycle.py`

Documentation:
- `docs/V2_4_STATE_OF_ART_LIFECYCLE.md`
- `docs/V2_4_ROLE_FLOW_AUDIT.md`
- `docs/V2_4_RELEASE_MANIFEST.md`

Deployment order:
1. Existing production baseline through v2.3.
2. Apply `production_v2_4_state_of_art_lifecycle.sql`.
3. Verify migration with the live acceptance matrix.
4. Run role-specific browser tests with separate Supabase users.
