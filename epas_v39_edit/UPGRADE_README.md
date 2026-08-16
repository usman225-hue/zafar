# EPAS Production Upgrade — GM + DM

The previous v1.2 package contained a demo actor switcher and legacy in-memory workflow helpers. This release replaces the **GM and Department Manager entry point** with the production implementation.

Use `README_PRODUCTION.md` and `docs/PRODUCTION_IMPLEMENTATION.md`.

### Production entry point
`app.py`

### Production UI
- `components/auth_gate.py`
- `components/gm_production.py`
- `components/dm_production.py`

### Production service layer
- `config/production_auth.py`
- `database/production_queries.py`

### Production database migration
- `database/production_schema.sql`

There is no production fallback to seed/demo data. If Supabase is unavailable, the user is not admitted to the workflow.
