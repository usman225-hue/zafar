# EPAS v2.0 — Professional Completion (Items 21–32)

This release is cumulative on v1.9 and completes the management-control, security-assurance and role-workspace gaps identified during the workflow review.

## Business authority retained
- Shipyard: **NSC Survey RFI only**.
- Owner: **In-Service Survey RFI only**.
- Ship Management: **In-Service Survey RFI only**.
- Server-side RPC enforcement remains authoritative; UI restrictions are secondary.

## 21–25 Management controls
- SLA control tower with ON_TRACK / DUE_SOON / OVERDUE / BREACHED states and history.
- Escalation action task linkage and automatic resolution synchronization.
- Risk/decision integration through governance entity links.
- Professional closure gate includes observations, tasks, SLA breaches, corrective actions, escalations, milestones, certificates, interim certificate state, risks and audit trail.
- Closure readiness snapshots are persisted for audit evidence.

## 26–30 Security
- Security acceptance cases are persisted.
- `epas_security_preflight()` checks RLS, policy presence, storage policy presence, RPC availability and stakeholder RFI rules.
- Cross-project isolation and stakeholder leakage remain mandatory live acceptance tests; a static preflight cannot prove those runtime properties.
- Storage access is still governed by Supabase Storage RLS/policies.
- RPC workflow mutations remain the authoritative mutation boundary.

## 31–32 UX
- Every authenticated role receives a role-specific Professional Operations Center.
- Work queue is sorted by SLA risk.
- GM/DM receive governance and security assurance views.
- Stakeholder roles retain controlled visibility and cannot use the center to bypass project RLS.

## Production limitation
The package can statically validate the implementation, but live RLS, Storage and cross-project isolation require execution against the real Supabase project with separate role accounts.
