# EPAS v3.2 — Final 1–40 Audit Closure

This release addresses the improvement points identified in the v3.1 full audit. The closure is organized by the same audit categories used during review.

## 1–3 Security / architecture
1. Authenticated Supabase client remains Streamlit-session scoped, never process-global.
2. Active survey-control reads/actions use v3.2 canonical RPC wrappers.
3. Lower-version survey-control execute privileges are explicitly revoked from authenticated callers.

## 4–8 Performance / database access
4. Role dashboard bundle remains the single compact KPI source.
5. GM portfolio health uses a project-health bundle rather than per-project health RPCs.
6. Stakeholder/Designer project lists use an authorized-project RPC instead of N+1 membership scans.
7. Stakeholder In-Service schedule display uses one role-scoped schedule queue call.
8. Session read cache is bounded LRU with short TTL and write invalidation.

## 9–12 File / transaction controls
9. Centralized upload-with-cleanup is now the public production helper.
10. Certificate PDF registration uses cleanup + authoritative v3.2 registration.
11. Actual PDF SHA-256, size and MIME are required for controlled reports/certificates.
12. Upload validation uses a single materialized file buffer and controlled signatures.

## 13–17 Workflow / version control
13. Scope/package/checklist/execution-basis versioning is retained and exposed through v3.2 facade calls.
14. Survey start/submission/certificate gates are role-scoped through v3.2 wrappers.
15. In-Service cycle completion remains persistent/recurring and idempotent.
16. Schedule basis is explicit and must be configured before a new cycle can proceed.
17. Scheduler health and failure metadata are available through bounded operational reads.

## 18–22 Frontend / navigation
18. Active lifecycle component is now explicitly v3.2.
19. Visible UI version labels are updated to v3.2.
20. Heavy workspaces remain mutually exclusive in Streamlit navigation.
21. Stakeholder experiences retain phase-specific behavior: Shipyard = NSC; Owner/Ship Management = In-Service.
22. The Survey Lifecycle surface keeps clear State / readiness / next-action guidance.

## 23–27 Role workflow closure
23. GM workflow remains project/governance/approval/certificate focused.
24. DM workflow remains allocation/review/survey/verification/certificate-ack focused.
25. Engineer workflow remains controlled technical appraisal with artifacts and Surveyor verification branch.
26. Surveyor workflow remains assignment → scope → drawings → checklist → gate → execution → declaration → report.
27. Designer workflow remains controlled submission → correction → revision → resubmission.

## 28–32 Stakeholder workflow closure
28. Shipyard is NSC-only for RFI initiation and schedule visibility.
29. Owner is In-Service-only for RFI initiation and schedule visibility.
30. Ship Management is In-Service-only for RFI initiation and schedule visibility.
31. Stakeholder project lists are server-authorized and project-scoped.
32. Stakeholder timeline/schedule data stays phase-safe and does not expose internal control diagnostics.

## 33–36 Performance / scalability closure
33. High-frequency operational tables have supporting indexes from prior releases.
34. Primary management N+1 health reads are replaced by one bundle call.
35. Resource capacity UI now selects one project at a time rather than querying every project during one render.
36. Stakeholder RFI history uses one authorized RFI query rather than one query per project.

## 37–40 Production readiness / verification
37. Canonical v3.2 scheduler wrapper is service-role-only and has a deployable Cron definition.
38. Final privilege audit RPC reports routines executable by `authenticated` and flags non-v3.2 routines for deployment review.
39. Static regression suite is green; browser/live acceptance remains a deployment-environment test rather than an unverified claim.
40. Final release validator / documentation are included in the package so the live eight-role Supabase acceptance can be executed reproducibly.

## Acceptance status

**Static code/test closure: complete.**

**Live deployment evidence still requires the real Supabase project:** RLS, Storage, Cron, concurrent user isolation, large-file uploads, and Cycle 1 → Cycle 2 recurrence.
