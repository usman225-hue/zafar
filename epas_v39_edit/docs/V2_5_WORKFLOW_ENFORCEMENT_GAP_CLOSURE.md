# EPAS v2.5 — Workflow Enforcement & Gap Closure

v2.5 is the cumulative hardening release after v2.4. It is designed to close the remaining workflow, security, document-control, recurring-survey, and role-coordination gaps identified in the v2.4 audit.

## Final business rules

| Role | NSC Survey RFI | In-Service RFI |
|---|---:|---:|
| Shipyard | Yes | No |
| Owner | No | Yes |
| Ship Management | No | Yes |

## Controlled survey lifecycle

`RFI -> Scope Version -> DM Assignment -> Surveyor Acceptance -> Drawing Package -> Package Acknowledgement -> Pre-Survey Checklist -> Revision Impact Decision -> Survey Start -> Execution -> Report -> Observations -> Corrective Action -> Evidence -> Verification -> GM Decision -> Frozen Certificate Decision Package -> DM Acknowledgement -> Certificate -> Ship Register -> Next Survey Schedule`

## Key v2.5 controls

- Scope versions are immutable and amendments create a new version.
- Survey drawing handover freezes drawing number, title, discipline, revision, document identity and SHA-256.
- If the current approved revision differs from the handed-over revision/hash, survey start is blocked until DM records an explicit impact decision.
- Reissue creates a new package version and supersedes the prior package; the prior handover remains auditable.
- Surveyor assignment requires resource eligibility checks and creates a resource snapshot.
- Surveyor must accept the assignment and acknowledge the drawing package before starting.
- Mandatory pre-survey checklist remains a server-side gate.
- Survey execution freezes the exact scope version, drawing package version and checklist version into an execution basis.
- Survey report submission is server-gated by assignment, package acknowledgement, checklist and revision-impact state.
- Certificate issuance requires a frozen certificate decision package and a real DM acknowledgement record.
- Observation evidence is limited to the project/RFI/action relationship appropriate to the actor's role.
- SECURITY DEFINER timeline/schedule/checklist/certificate helpers explicitly verify project authorization.
- Global schedule refresh and notification generation are no longer callable by any authenticated user; operator-only wrappers are provided.
- In-Service schedule has an independent survey due date, configurable interval, due basis/reference, window and cycle number; certificate expiry is not treated as the survey due date by definition.
- In-Service remains an active recurring phase; completing a survey cycle does not close the phase.
- Vessel survey status history uses the pre-transition status and records actual report completion/submission dates.
- A secured Survey Control Tower RPC provides the operational schedule view instead of exposing a broad view directly to authenticated clients.

## Acceptance limitation

Static and source-level regression tests were executed successfully. Live Supabase/RLS/Storage/browser acceptance still requires the deployment's actual Supabase project and Streamlit runtime.
