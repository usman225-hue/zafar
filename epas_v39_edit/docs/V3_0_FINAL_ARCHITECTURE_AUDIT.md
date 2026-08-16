# EPAS v3.0 Final Architecture Audit

## Backend / workflow
- Project phases are modeled separately from recurring In-Service survey cycles.
- Plan Appraisal gates NSC and/or In-Service according to project scope.
- NSC RFI authority is Shipyard only.
- In-Service RFI authority is Owner and Ship Management only.
- Approved Plan Appraisal drawings are selectively handed to the assigned Surveyor.
- Survey readiness requires assignment acceptance, scope acknowledgement, drawing-package acknowledgement, checklist readiness and revision-impact clearance.
- Scope/assignment changes invalidate downstream acknowledgements/packages/readiness.
- Corrective actions bind to exact observations.
- Evidence binds to exact observation/corrective-action pairs.
- Certificate package freezes survey/report/observation/evidence basis and requires DM acknowledgement.
- In-Service cycle completion is idempotent and creates one next cycle.

## Frontend
- Streamlit application with role-native cockpits.
- Current State / Blocker / Next Action pattern.
- Owner, Shipyard and Ship Management have distinct workflow emphasis.
- Responsive layouts and visible keyboard focus.
- Reduced-motion support.
- No external web-font dependency.
- Controlled error reference codes.
- Authorized global search.

## Security
- RLS reasserted on operational records.
- Stakeholder phase isolation for schedules and timelines.
- Internal readiness/issuance gates are role-scoped.
- High-risk legacy lifecycle functions are revoked from `authenticated` by v3.0 migration.
- File uploads use real SHA-256, size, MIME and storage-path controls.
- Production runtime is fail-closed.
- Optional MFA policy is supported.
- Audit chain stores previous/event hashes.
- Scheduler is service-role-only and has health/failure controls.

## Live validation still required
The release is code-complete for the identified gaps, but live deployment evidence is still required for:
- actual PostgreSQL grants after the full migration chain is applied;
- real RLS/Storage isolation across eight accounts;
- pg_cron execution;
- two consecutive In-Service cycles;
- full Streamlit browser acceptance.
