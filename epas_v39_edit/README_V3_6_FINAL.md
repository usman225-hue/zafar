# EPAS v3.6.0 — Final Query Consolidation, UX and Production Hardening

This release consolidates active Streamlit components onto `database.production_queries`, removes the legacy demo/query implementation from the active `database.queries` module, hardens the v3.5 production RPC facade usage, adds visible role workflow guidance, and adds ClamAV database refresh at container startup.

## Final workflow boundaries
- Shipyard → NSC Survey RFI only
- Owner → In-Service Survey RFI only
- Ship Management → In-Service Survey RFI only

## Performance
The active application uses role bundles, bounded session cache, consolidated stakeholder views and explicit DB projections. Large file uploads remain size-limited and are scanned once.

## Live deployment
After deployment, run the live acceptance harness against Supabase for eight real role accounts and run the included load test before broad rollout.
