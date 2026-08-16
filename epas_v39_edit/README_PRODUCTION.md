# EPAS Production v2.8

The production application is a role-authenticated Streamlit surface backed by Supabase. There is no demo actor selector or in-memory workflow state.

## Required environment

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

The example Streamlit secrets file is under `.streamlit/secrets.toml.example`.

## Deployment

Use `run_streamlit.sh` or the supplied `Dockerfile`. Apply database migrations through v2.8 and configure the service-role scheduler. Execute the v2.8 role acceptance matrix against a live Supabase environment before production sign-off.

## Runtime modes

EPAS supports two explicit modes from the same package:

- `EPAS_RUNTIME_MODE=demo`: public UI demonstration on port 8501 with in-memory seeded data and published demo credentials; no Supabase connection.
- `EPAS_RUNTIME_MODE=production`: Supabase Auth/database/RLS/Storage only; no demo sign-in.

For GitHub Codespaces demo use `./scripts/run_demo_8501.sh`. For professional deployment first run `./scripts/promote_to_production.sh ../epas-production`, then configure `SUPABASE_URL` and `SUPABASE_ANON_KEY` and run `./scripts/run_production_8501.sh`.
