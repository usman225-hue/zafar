# EPAS v2.8 — Final Workflow Hardening

EPAS v2.8 is the cumulative Streamlit/Supabase release built on the v2.7 baseline.

## Authoritative stakeholder survey initiation

- Shipyard → NSC Survey RFI only
- Owner → In-Service Survey RFI only
- Ship Management → In-Service Survey RFI only

## Final lifecycle

Project Scope → Plan Appraisal → Approved Drawings → NSC (when selected) → Persistent In-Service Phase (when selected) → Recurring Survey Cycles → Surveyor Assignment → Assignment Acceptance → Scope Acknowledgement → Controlled Drawing Package → Package Acknowledgement → Versioned Checklist → Revision Impact Decision → Frozen Execution Basis → Survey → Professional Declaration → Report → Observation / Corrective Action → Evidence → DM Verification → GM Decision → Frozen Certificate Decision Package → DM Acknowledgement → Certificate → Ship Register → Next Survey Cycle.

## v2.8 hardening

- In-Service is a persistent project phase; completed survey cycles do not close it.
- Explicit `survey_cycle_instances` records the recurring cycle history.
- Schedule configuration has an explicit basis date; no silent 12-month assumption for new configurations.
- Drawing package acknowledgement is version/fingerprint/scope bound and invalidatable.
- Scope acknowledgements carry a SHA-256 fingerprint and are invalidated on approved scope amendments.
- Scope amendments invalidate package acknowledgements, checklist state and frozen execution basis.
- Checklist definitions and execution readiness are fingerprinted.
- Surveyor assignment acceptance is version/fingerprint bound.
- Drawing revision-impact decisions store shared/current revision and SHA-256 comparison evidence.
- Survey execution basis is frozen to assignment, scope, drawing package and checklist versions.
- Survey report stores its evidence/report hash and execution-basis version.
- Certificate decision packages freeze survey report and declaration hashes and supersede prior active packages.
- Certificate issuance requires the exact active decision package and matching DM acknowledgement.
- Evidence is restricted to the exact corrective-action/observation pair and authorized assignee.
- Autonomous lifecycle functions are service-role-only; human actions use project-scoped wrappers.
- Recurring scheduler is exposed through `epas_scheduler_tick_v28()` and the v2.8 Supabase Cron deployment file.
- Notification recipients are phase-aware and do not leak In-Service scheduling information to Shipyard.

## Deployment

Apply migrations cumulatively through v2.7, then apply:

`database/production_v2_8_final_hardening.sql`

Install the scheduler using:

`deployment/supabase_cron_v28.sql`

The Streamlit application is launched through `run_streamlit.sh` or the provided Dockerfile.
