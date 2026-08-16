# EPAS v2.7 Final Gap Closure

## Purpose

v2.7 is the cumulative final hardening release after the v2.6 audit. It keeps the existing Streamlit + Supabase architecture and closes the remaining workflow, security, recurring In-Service, versioning, and operational gaps.

## Authoritative stakeholder RFI rules

- Shipyard → NSC Survey RFI only.
- Owner → In-Service Survey RFI only.
- Ship Management → In-Service Survey RFI only.

## Persistent In-Service model

The In-Service **project phase remains ACTIVE**. Individual survey cycles are represented by `survey_schedules.cycle_number` and may move through:

`DUE / DUE_SOON / OVERDUE → RFI_OPEN → survey execution → certificate → next cycle`

A completed cycle never closes the In-Service phase.

## Security hardening

Autonomous schedule synchronization and vessel status projection are service-role operations. Human users receive project-scoped read/control functions only. Cycle completion is restricted to project GM/DM or the service role.

## Drawing package control

Each survey drawing package has an immutable file/revision snapshot and a package-level fingerprint. Surveyor acknowledgement is bound to the exact package version and fingerprint.

## Scope/checklist/execution versioning

Scope amendments invalidate prior acknowledgement, drawing packages, checklist state, and frozen execution basis. Survey execution freezes the exact scope, drawing package, checklist definition and assignment versions.

## Scheduling

A survey schedule requires an explicit interval and schedule basis before a new In-Service RFI can be initiated. Certificate expiry may provide an initial provisional due date, but it does not silently create an assumed one-year survey interval.

## Streamlit

The supplied application remains Streamlit-based and now exposes the v2.7 lifecycle control surface to authenticated roles. `run_streamlit.sh` and the Dockerfile are included for deployment.

## Production scheduler

Configure Supabase Cron or the equivalent managed scheduler to call `public.epas_scheduler_tick_v27()` using service-role execution in the target environment.
