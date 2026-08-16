# EPAS v2.1 Release Manifest

Baseline: EPAS v2.0 complete professional package.

New migration:
- `database/production_v2_1_engineer_surveyor_completion.sql`

Updated application:
- `components/role_workspaces.py`
- `database/production_queries.py`

New tests:
- `tests/test_v21_engineer_surveyor_completion.py`

Audit/documentation:
- `docs/V2_1_ENGINEER_SURVEYOR_AUDIT.md`
- `docs/V2_1_CHANGELOG.md`
- `docs/V2_1_RELEASE_MANIFEST.md`
- `docs/V2_0_ROLE_DIAGRAM_AUDIT.md` updated with v2.1 closure addendum

Validation:
- Python compileall: PASS
- Relevant cumulative static regression suite: 59 passed
- Live Supabase/browser acceptance: pending deployment environment
