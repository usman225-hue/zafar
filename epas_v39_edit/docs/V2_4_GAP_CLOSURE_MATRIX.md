# EPAS v2.4 Gap Closure Matrix

| Gap | Closure |
|---|---|
| Survey request/assignment/execution overloaded in RFI | `survey_scopes`, `survey_assignments`, `survey_executions` |
| In-Service recurring lifecycle | `survey_schedules`, status engine, notifications |
| Exact drawing revision not frozen | immutable handover snapshot fields |
| Drawing revision changes during active survey | `epas_survey_drawing_revision_impact()` |
| Certificate basis not frozen | `certificate_decision_packages` |
| Evidence not observation-specific | `observation_evidence` + controlled RPC |
| RFI authorization duplicated/hard-coded | `rfi_creation_policy` |
| Stakeholder scope silently editable | scope amendment workflow |
| In-Service phase incorrectly considered complete | continuing phase semantics |
| Ship Register fragmented | enhanced authoritative `ship_register` view + central status engine |
| Business timeline fragmented | `lifecycle_events` + `epas_project_timeline()` |
| Survey reminders incomplete | schedule-driven notification generator |
| Cross-object state drift | lifecycle triggers |
| Professional management visibility | lifecycle/schedule control tower |
