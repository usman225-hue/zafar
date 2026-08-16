# EPAS v3.1 Final Gap Closure Matrix

| Audit gap | v3.1 treatment |
|---|---|
| Global authenticated Supabase client | Session-local client in `config/supabase_client.py` |
| Full-app rerun query amplification | Session-local read cache + view-gated navigation |
| N+1 dashboard counts | `epas_role_dashboard_bundle_v31()` |
| Wide `select(*)` on common reads | Narrow projections on high-frequency query paths |
| In-Service 12-month silent fallback | v3.1 cycle completion requires configured interval/basis |
| Storage authorization | v3.1 bucket policies, released-stakeholder model, no direct client update/delete |
| Upload orphan files | `_upload_with_cleanup()` around authoritative registration |
| High-frequency DB load | Targeted indexes |
| Concurrency visibility | `row_version` on operational objects |
| Scheduler robustness | service-role v3.1 wrapper + retry metadata + degraded health |
| UX density | One heavy role surface rendered per selected workspace view |
| Role-specific cockpit load | Compact dashboard bundle + reduced duplicate schedule calls |
| Security privilege visibility | GM-only SECURITY DEFINER privilege audit |
