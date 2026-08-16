# EPAS v4.0.2 — Demo on Port 8501, Production on Supabase

This package supports two **explicit** runtime modes.

## 1. Public/demo mode — GitHub Codespaces / port 8501

GitHub Pages cannot run Streamlit. Use **GitHub Codespaces**, GitHub Actions with a runner, or another host that can expose port **8501**.

Start:

```bash
./scripts/run_demo_8501.sh
```

Demo mode:

- Uses `EPAS_RUNTIME_MODE=demo`.
- Uses an in-memory realistic EPAS seed dataset.
- Does not connect to Supabase.
- Uses demo credentials listed in `DEMO_CREDENTIALS.md`.
- Is suitable for UI/workflow demonstration only.

## 2. Professional production mode

Before production, create a clean production copy:

```bash
./scripts/promote_to_production.sh ../epas-production
```

The promotion process removes demo-only runtime files, demo credentials, demo seed data, and the demo query adapter. The resulting copy is Supabase-only.

Configure:

```bash
export EPAS_RUNTIME_MODE=production
export SUPABASE_URL=https://YOUR_PROJECT.supabase.co
export SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
```

Then:

```bash
cd ../epas-production
./scripts/run_production_8501.sh
```

Production login is Supabase Auth only. RLS, Storage policies, workflow RPCs, certificate controls, audit trail and scheduler run from Supabase.

## Important

Do not put real passwords or Supabase service-role keys in GitHub source code. Use GitHub Codespaces secrets, GitHub repository secrets, Streamlit secrets, or deployment-platform environment variables.
