# EPAS v4.0 — GitHub / Codespaces Demo Mode

Use this mode to preview the full Streamlit frontend and role workflows on **port 8501** without a Supabase project.

**Start:** `./scripts/run_demo_8501.sh`

**Mode:** `EPAS_RUNTIME_MODE=demo`

**Demo password:** `PSB-Demo-2026!` (change via `EPAS_DEMO_PASSWORD` before sharing a public demo).

The demo dataset is in-memory. It is intentionally not a production data store.

When moving to real operations, create a clean production copy using:

`python scripts/strip_demo_for_production.py --output ../epas-production`

Then run the production copy with Supabase credentials only.


## Direct Streamlit launch (fixed)

The demo package also auto-loads the bundled `.env.demo` when no explicit `EPAS_RUNTIME_MODE` is set. This means you can launch the app directly with:

```bash
streamlit run app.py --server.address 0.0.0.0 --server.port 8501
```

or use the helper:

```bash
./scripts/run_demo_8501.sh
```

Use any published demo email from `DEMO_CREDENTIALS.md` and the demo password from that file. The demo uses the in-memory dataset and does not contact Supabase.
