# EPAS v1.9 — Role-Complete Gap Closure (Items 11–20)

Applied after v1.8.

## Stakeholder RFI rule — authoritative

- **Shipyard:** may initiate **NSC Survey RFI only**.
- **Owner:** may initiate **In-Service Survey RFI only**.
- **Ship Management:** may initiate **In-Service Survey RFI only**.
- The rule is enforced in the server-side `epas_stakeholder_create_rfi()` RPC and must not rely on UI filtering.

## 11. Pre-survey checklist

- Controlled `survey_checklist_items` entity.
- NSC and In-Service checklist initialization.
- In-Service-specific prior-report/maintenance/change-of-class checks.
- Mandatory checklist gate before controlled survey report submission.

## 12. Professional observation model

Survey observations now capture rule reference, location, equipment/system, deficiency category, responsible party, target date, corrective action, evidence requirement and verification method.

## 13. Follow-up RFI

Explicit follow-up types:

- `NSC_REWORK_VERIFICATION`
- `IN_SERVICE_OBSERVATION_CLEARANCE`
- `CHANGE_OF_CLASS_FOLLOW_UP`
- `GENERAL_FOLLOW_UP`

Every follow-up retains `follow_up_of_rfi_id` lineage.

## 14. Certificate lifecycle

Certificate stage is explicitly `INTERIM` or `FINAL`, with lifecycle refresh for expiring/expired certificates and existing controlled GM/DM state transitions retained.

## 15–16. Owner / Shipyard / Ship Management stakeholder portal

Stakeholder dashboards now include fleet KPIs, vessel status, upcoming surveys, controlled survey history and controlled observation visibility. Internal appraisal notes remain protected.

## 17–18. Designer portal and revision lineage

Designer submission tracker added. Plan revisions now support parent revision, submission reason and integrity metadata.

## 19. Ship Management corrective-action queue

Ship Management receives a controlled action queue showing linked observation count, due date, evidence state and submission status.

## 20. Resource allocation

A professional allocation matrix exposes authorization, competency, availability and workload for candidate resources before assignment. Allocation snapshots provide an auditable basis for the assignment decision.

## SLA

Workflow tasks now carry accepted/started timestamps, SLA due date and SLA state (`ON_TRACK`, `DUE_SOON`, `OVERDUE`, `BREACHED`).
