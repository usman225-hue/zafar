# EPAS v3.3 — Final Workflow, Security & Performance Hardening

This release is the cumulative v3.2 application plus the targeted closure of the remaining issues from the professional frontend/backend/security audit.

## Closed items 1–10
1. Added a real live-acceptance harness and evidence table for eight-role RLS/Storage/session/Cron acceptance.
2. Added the v3.3 authoritative survey/control facade and revoked direct authenticated execution of lower-version survey-control entry points.
3. Replaced major active N+1 task/drawing/RFI reads with batch helpers.
4. Narrowed active production `select(*)` paths to explicit column projections.
5. Standardized certificate registration through the cleanup-controlled v3.3 wrapper.
6. Added targeted cache-prefix invalidation while keeping bounded session-local cache safety.
7. Added explicit upload size/security controls, one materialized upload buffer, optional fail-closed ClamAV scanning, and cleanup-on-registration-failure.
8. Added stakeholder project/fleet/vessel bundles to reduce repeated project/vessel reads and enforce role-specific phase boundaries server-side.
9. Added the canonical v3.3 scheduler wrapper and deployment SQL; historical scheduler entry points are internal-only.
10. Added a repeatable live security/performance acceptance matrix, audit-chain acceptance, malware-scanning hook, and deployment validator.

## Workflow authority
- Shipyard → NSC Survey RFI only.
- Owner → In-Service Survey RFI only.
- Ship Management → In-Service Survey RFI only.
- Plan Appraisal → approved revision → relevant drawing handover → Surveyor only.
- In-Service is persistent; survey cycles repeat without closing the phase.

## Runtime note
The package is optimized for normal/moderate concurrent Streamlit usage, uses session-scoped Supabase clients and bounded read caching, and reduces common N+1 patterns. Final live load/RLS/Storage/Cron evidence must be recorded against the deployed Supabase project.
