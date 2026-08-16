# EPAS v2.4 — State-of-the-Art Lifecycle Completion

## Scope

v2.4 closes the remaining gaps identified during the v2.3 role/workflow audit.
The package is cumulative from v2.3.

## Authoritative business rules

- Shipyard may initiate **NSC Survey RFI only**.
- Owner may initiate **In-Service Survey RFI only**.
- Ship Management may initiate **In-Service Survey RFI only**.
- Plan Appraisal gates NSC when Plan Appraisal is selected.
- NSC gates In-Service when NSC is selected.
- In-Service is a **continuing operational phase**. A completed survey is a completed cycle, not completion of the phase.
- Surveyor drawing handover freezes the exact revision, document, file path, SHA-256, MIME type and size.
- A later approved drawing revision never silently replaces an active survey package.
- Certificate issuance is based on a frozen decision package.

## 23 — Survey domain decomposition

RFI remains the business request spine, while three explicit objects now separate concerns:

1. `survey_scopes` — what is being requested and its controlled scope version.
2. `survey_assignments` — who is assigned and when.
3. `survey_executions` — what actually happened during the survey.

This prevents request, allocation and execution from becoming one overloaded record.

## 24 — Recurring In-Service scheduling

`survey_schedules` and `survey_schedule_events` maintain the next due date, survey window and status.
The schedule is synchronized from active/expiring certificates and can be surfaced to the Owner, Ship Management, DM and GM.

Lifecycle:

`Certificate → Next Due → Reminder → In-Service RFI → Survey → Certificate → Next Due`

## 25 — Immutable drawing handover

`survey_rfi_drawings` now stores the exact handover snapshot:

- shared revision
- document id
- file name
- storage path
- SHA-256
- MIME type
- file size
- package version
- package state

`epas_survey_drawing_revision_impact()` identifies whether a newer revision has appeared and requires a DM decision.

## 26 — Certificate decision package

`certificate_decision_packages` freezes the evidence basis for issuance:

- survey execution
- observations
- corrective actions
- drawing handover package
- GM decision
- DM acknowledgement snapshot

This gives auditors a reproducible issuance basis.

## 27 — Observation-level evidence

`observation_evidence` binds evidence to the exact observation and, where applicable, the exact corrective action. The database rejects evidence that is not linked to the relevant RFI observation relationship.

## 28 — Central RFI policy and controlled amendments

`rfi_creation_policy` is the authoritative role/phase policy. Stakeholder RFI creation also checks the project phase gate in the same RPC.

RFI scope changes use:

`Request Amendment → DM Decision → New Scope Version`

Once survey execution starts, stakeholder users cannot silently edit the scope.

## 29 — Phase semantics

Plan and NSC can complete as project phases. In-Service remains active after a survey cycle is completed. Current cycle state is represented by the RFI/schedule while phase state remains operational.

## 30 — Ship Register authority

The Ship Register now combines vessel status, certificate status and recurring survey schedule. The central status engine is the authoritative transition mechanism.

## 31 — Lifecycle timeline and notifications

`lifecycle_events` provides a chronological business timeline across RFI, survey, certificate and other entities. Due/overdue survey notifications are generated from the schedule engine.

## 32 — Automatic coherence

Database triggers keep phase state, vessel survey status, survey schedule and lifecycle timeline synchronized after RFI, certificate and survey-report changes.

## Production acceptance boundary

Static regression and source validation do not replace live acceptance. Before production sign-off, run the supplied live RLS, Storage, RPC, cross-project isolation and seven-role browser acceptance suite against the actual Supabase project.
