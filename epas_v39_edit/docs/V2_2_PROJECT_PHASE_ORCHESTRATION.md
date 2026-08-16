# EPAS v2.2 — Project Phase Orchestration

## Business rule

A project executes only the phases selected in the project scope. The execution engine follows the selected phases in this order:

1. Plan Appraisal
2. NSC Survey
3. In-Service Survey

Unselected phases are `NOT_APPLICABLE` and are skipped.

### Examples

**Plan Appraisal only**

`Plan Appraisal → Project Scope Complete`

No NSC or In-Service work is opened.

**Plan Appraisal + NSC**

`Plan Appraisal → NSC → Project Scope Complete`

NSC cannot start until Plan Appraisal is complete. NSC closes only after its survey cycle is closed and observations are cleared.

**Plan Appraisal + NSC + In-Service**

`Plan Appraisal → NSC → In-Service → ongoing survey lifecycle`

In-Service remains the active operational phase after NSC closure. Owner / Ship Management may initiate subsequent In-Service RFIs when the current In-Service cycle is complete.

**In-Service without NSC**

If Plan Appraisal is selected, In-Service waits for Plan Appraisal. If neither Plan Appraisal nor NSC is selected, In-Service may start directly.

## Server-side controls

`project_phase_control` stores the authoritative state of every selected phase:

- NOT_APPLICABLE
- LOCKED
- READY
- IN_PROGRESS
- COMPLETED
- BLOCKED

The same gate is checked by the stakeholder RFI creation RPC. UI visibility is therefore not the security boundary.

## Ship Register / survey status

The vessel record now carries:

- `survey_status`
- `class_status`
- `next_survey_due`
- `last_survey_date`
- `last_survey_phase`

A history table records every calculated survey-status transition.

The global Ship Register displays the live survey status and next due date, and the project workspace shows the same status next to the project phase roadmap.

## Survey scheduling principle

Survey execution is downstream of the project phase gate and the RFI lifecycle. A surveyor should receive a survey task only after the relevant phase is eligible and the RFI has passed GM/DM allocation controls.

## RFI authority remains unchanged

| Role | NSC RFI | In-Service RFI |
|---|---:|---:|
| Shipyard | Yes | No |
| Owner | No | Yes |
| Ship Management | No | Yes |

## Important production note

The SQL migration contains triggers for RFI, observation, certificate, plan-drawing and plan-observation changes so phase and vessel status remain synchronized as workflow records change.
