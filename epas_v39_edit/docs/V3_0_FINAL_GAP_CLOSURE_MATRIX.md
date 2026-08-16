# EPAS v3.0 Final Gap Closure Matrix

This release addresses the final gaps identified in the v2.9 backend, frontend and security audit.

| Gap area | v3.0 closure |
|---|---|
| New operational table RLS | Added final RLS policies for cycle/checklist/ack/security/scheduler/acceptance tables |
| SECURITY DEFINER read exposure | Added role-scoped v3.0 gate/timeline/schedule wrappers |
| Stakeholder schedule isolation | Shipyard = NSC; Owner/Ship Management = In-Service; Surveyor = assigned survey |
| Stakeholder timeline isolation | Phase-filtered business timeline, internal diagnostics hidden |
| Final privilege inventory | `epas_privilege_registry_v30` plus explicit revocations of high-risk legacy lifecycle RPCs |
| Recurring cycle idempotency | Cycle completion accepts mandatory idempotency key and unique constraint |
| Assignment reassignment invalidation | Assignment dependency trigger invalidates prior ack/package/scope/checklist/execution readiness |
| Scope amendment invalidation | Scope dependency trigger invalidates downstream artifacts |
| Actual report hash | Survey report insert/update trigger requires SHA-256, PDF MIME, storage path and size |
| Certificate gate privacy | Stakeholders receive safe certificate status, internal issuance gate is GM/DM only |
| Scheduler resilience | Scheduler failure metadata + internal health endpoint + Cron deployment script |
| Error-message leakage | Shared safe Streamlit error helper with stable reference codes |
| Role-native frontend | GM, DM, Engineer, Surveyor, Designer, Owner, Ship Management and Shipyard cockpit content differentiated |
| Workflow visibility | State / blocker / next-action pattern and readiness language surfaced in role cockpit |
| Responsive/accessibility | Responsive cockpit CSS, visible keyboard focus, reduced-motion support |
| External fonts | System-safe fonts only; no Google Fonts dependency |
| Live acceptance material | Non-mutating preflight script + final eight-role acceptance checklist |
| Audit integrity | Tamper-evident audit previous/event hash fields and trigger |
