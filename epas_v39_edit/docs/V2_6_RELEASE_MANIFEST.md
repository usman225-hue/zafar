# EPAS v2.6 Release Manifest

Baseline: EPAS v2.5 complete workflow enforcement package.

New migration:
- `database/production_v2_6_final_workflow_acceptance_hardening.sql`

New tests:
- `tests/test_v26_final_workflow_acceptance.py`

Primary UI updates:
- `components/role_workspaces.py`
- `database/production_queries.py`

The package is cumulative. Apply the v2.6 migration after the v2.5 migration.

Static test validation in the build environment does not constitute live RLS/Storage/browser acceptance.
