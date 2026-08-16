# EPAS v2.0 — Role-by-Role Workflow Audit

Audit basis:
- GM workflow diagram supplied by user
- Department Manager workflow diagram supplied by user
- Plan Appraisal Engineer workflow diagram supplied by user
- Surveyor workflow diagram supplied by user
- Shipyard workflow diagram supplied by user
- Owner workflow diagram supplied by user
- Designer workflow diagram supplied by user
- cumulative EPAS source/database through v2.0

## Executive result

The application is now materially stronger as a production workflow platform. Items 21–32 are implemented in the v2.0 migration and role operations center. The audit below distinguishes **implemented**, **partially evidenced**, and **live-test required** so that no static source review is mistaken for production acceptance.

## Business RFI authority — authoritative

| Role | NSC Survey RFI | In-Service Survey RFI |
|---|---:|---:|
| Shipyard | **ALLOWED** | **DENIED** |
| Owner | **DENIED** | **ALLOWED** |
| Ship Management | **DENIED** | **ALLOWED** |

This is server-enforced in `epas_stakeholder_create_rfi()`; UI filtering is not the security boundary.

---

## 1. GM — Command / Governance

### Diagram intent
- Create/manage project
- Receive stakeholder request
- Intake and validate drawings/RFIs
- Assign DM
- Review technical recommendation
- Approve / return / reject
- Manage certificate gate
- Governance, risk, decision, escalation and closure
- Release controlled information to stakeholders

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Project creation and activation | PASS | GM production/project wizard |
| NSC/In-Service RFI intake | PASS | RFI queue + protected RPC |
| Drawing intake | PASS | plan appraisal workflow |
| DM assignment | PASS | DM handover/assignment RPCs |
| Technical approval path | PASS | GM decision workflow |
| Risk register | PASS | project_risks + GM UI |
| Decision register | PASS | project_decisions + governance integration |
| Escalation decision | PASS | GM escalation RPC + linked task |
| Certificate gate | PASS | controlled certificate lifecycle |
| Stakeholder release | PASS | document/milestone release controls |
| Closure gate | PASS | v2.0 enhanced closure checks |
| SLA control tower | PASS | Professional Operations Center |
| Security assurance | PASS* | preflight exists; live role test required |

**GM residual risk:** final acceptance requires live test of approval/release/closure against a real Supabase project.

---

## 2. Department Manager — Operational Control

### Diagram intent
- Receive GM work
- Review scope
- Check resource eligibility
- Assign Engineer/Surveyor
- Review technical/survey outputs
- Send recommendation to GM
- Manage corrective actions
- Verify corrective evidence
- Create/coordinate follow-up
- Monitor SLA/resource load

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| GM handover | PASS | workflow task/RPC |
| Engineer allocation | PASS | resource eligibility + allocation matrix |
| Surveyor allocation | PASS | resource eligibility + allocation matrix |
| Authorization check | PASS | resource_authorizations |
| Competency check | PASS | resource_competencies |
| Availability/conflict check | PASS | availability/workload controls |
| Survey report review | PASS | DM survey review UI |
| Exact observation binding | PASS | corrective_action_observations |
| Corrective evidence verification | PASS | controlled DM verification |
| Follow-up RFI | PASS | explicit follow-up types |
| SLA monitoring | PASS | v2.0 SLA control tower |
| Escalation action assignment | PASS | linked workflow task |
| Risk/decision governance | PASS | v2.0 governance register |

**DM residual risk:** live authorization/RLS tests remain required because source-level checks cannot prove policy behavior for every role.

---

## 3. Plan Appraisal Engineer

### Diagram intent
- Receive assigned drawing
- Accept/start task
- Review controlled revision
- Technical appraisal
- Record rule/drawing references
- Produce technical conclusion
- Raise observations
- Request Surveyor verification where needed
- Return recommendation to DM

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Assignment inbox | PASS | authenticated Engineer task queue |
| Accept/start lifecycle | PASS | secure task RPCs |
| Drawing review | PASS | plan_drawing + revision history |
| Rule reference | PASS | engineer observation UI |
| Drawing reference | PASS | engineer observation UI |
| Technical conclusion | PASS | review submission |
| Technical observations | PASS | plan appraisal observation model |
| Revision lineage | PASS | parent revision / correction task / source decision |
| SLA queue | PASS | v2.0 work queue |
| Marked-up drawing upload | **PARTIAL** | revision/evidence architecture exists, but Engineer UI does not yet expose a dedicated marked-up drawing field |
| Explicit “Approved as Amended” outcome | **PARTIAL** | current Engineer UI uses accepted/observation; decision taxonomy should be expanded to diagram vocabulary |
| Surveyor verification branch | **PARTIAL** | surveyor workflow exists, but dedicated Engineer → Surveyor verification routing should be made explicit in the Engineer UI/RPC |

**Priority residual:** complete the Engineer marked-up appraisal package and exact decision/verification branch before final production sign-off.

---

## 4. Surveyor

### Diagram intent
- Receive survey RFI
- Determine NSC vs In-Service
- Complete pre-survey coordination/checklist
- Conduct survey
- Record attendance/location/evidence
- Raise observations
- Produce report
- Support corrective/follow-up verification

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Survey assignment | PASS | SURVEY_EXECUTION task |
| NSC/In-Service distinction | PASS | RFI phase + checklist initialization |
| Pre-survey checklist | PASS | mandatory checklist gate |
| Survey report | PASS | controlled report submission |
| Attendance/location | PASS | survey report fields |
| Evidence | PASS | controlled upload/integrity fields |
| Observation severity | PASS | observation model |
| Rule reference | PASS | observation model |
| Deficiency category | PASS | observation model |
| Responsible party | PASS | observation model |
| Target date | PASS | observation model |
| Corrective action requirement | PASS | observation model |
| Follow-up type | PASS | v1.9 explicit types |
| Corrective verification | PASS | controlled DM verification flow |
| SLA queue | PASS | v2.0 |

**Residual:** make the NSC/In-Service pre-survey decision visually explicit as a first-class branch rather than relying only on the RFI phase value.

---

## 5. Shipyard

### Diagram intent
- Initiate NSC survey request
- Provide survey scope/schedule information
- Track request
- Receive controlled survey/project outputs
- Participate in corrective/rework cycle where business process permits

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Create NSC RFI | PASS | protected stakeholder RPC + UI |
| Create In-Service RFI | **DENIED BY DESIGN** | correct business rule |
| RFI status tracking | PASS | stakeholder status view |
| Vessel/project view | PASS | controlled fleet/vessel dashboard |
| Released documents | PASS | release-only external view |
| Certificate visibility | PASS | controlled stakeholder access |
| Internal appraisal leakage protection | PASS* | RLS/release design; live test required |
| SLA/work queue | PASS | role-specific operations center |

**Important:** Shipyard is an RFI originator for **NSC only**. It must not be treated as a read-only stakeholder for RFI initiation.

---

## 6. Owner

### Diagram intent
- Fleet dashboard
- Vessel status
- Certificate history
- Survey history
- Upcoming surveys
- Initiate In-Service survey request
- Receive controlled alerts/status

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Fleet dashboard | PASS | stakeholder fleet summary |
| Vessel status | PASS | vessel dashboard |
| Certificate status/history | PASS | stakeholder certificate views |
| Survey history | PASS | controlled survey history |
| Upcoming surveys | PASS | upcoming survey query |
| Create In-Service RFI | PASS | protected RPC |
| Create NSC RFI | **DENIED BY DESIGN** | correct business rule |
| Internal appraisal visibility | PASS* | intended to remain protected; live test required |
| SLA/work queue | PASS | v2.0 |

---

## 7. Designer

### Diagram intent
- Submit drawing
- Receive amendment/correction instruction
- Create revision
- Maintain revision lineage
- Resubmit for appraisal
- Track status
- See approved/released output where permitted

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Initial submission | PASS | Designer workspace |
| Correction task | PASS | PLAN_APPRAISAL_DESIGNER_RESPONSE |
| New revision | PASS | controlled revision submission |
| Parent revision lineage | PASS | parent_revision_id |
| Submission reason | PASS | revision metadata |
| Source decision/correction linkage | PASS | revision metadata |
| SHA-256/MIME/size | PASS | document/revision integrity model |
| Submission tracker | PASS | Designer dashboard |
| SLA/work queue | PASS | v2.0 |
| Internal GM/DM appraisal leakage | PASS* | intended by RLS/release model; live test required |

---

## 8. Ship Management

### Diagram intent
- Initiate In-Service survey request
- Receive corrective actions
- Perform corrective work
- Submit evidence
- Track observation/action status
- Participate in follow-up survey

### Audit

| Capability | Result | Evidence / note |
|---|---|---|
| Create In-Service RFI | PASS | protected RPC + UI |
| Create NSC RFI | **DENIED BY DESIGN** | correct business rule |
| Corrective-action queue | PASS | v1.9 action queue |
| Exact observation relationship | PASS | action-to-observation link table |
| Evidence submission | PASS | controlled evidence flow |
| DM verification | PASS | server-side verification transaction |
| Follow-up | PASS | explicit follow-up types |
| SLA/work queue | PASS | v2.0 |
| Internal classification data protection | PASS* | live RLS test required |

---

# Cross-cutting audit

## Workflow integrity

**PASS:** the cumulative system has a controlled mutation model using authenticated RPCs, explicit workflow tasks, audit events, SLA metadata, document/revision lineage, observation/corrective-action binding and certificate lifecycle controls.

## Security

**PASS in design / LIVE TEST REQUIRED:** v2.0 provides a security preflight and persisted acceptance cases. However, only a live Supabase project with separate role accounts can prove:
- cross-project isolation;
- Storage object denial;
- exact RLS behavior;
- RPC denial for unauthorized roles;
- absence of stakeholder data leakage.

## Document control

**PASS in architecture:** controlled revision lineage, integrity metadata, release states and access audit are present.

## SLA

**PASS:** dashboard, state model, history and work queue are implemented.

## Governance

**PASS:** risks, decisions and linked governance entities are now integrated into the management layer.

## Closure

**PASS:** closure is no longer just a simple status change; the gate checks workflow, SLA, observations, corrective actions, escalations, milestones, certificates, interim certificate status, risks and audit evidence.

---

# Final production-readiness rating

**Static implementation maturity: HIGH / approximately 90%+**

**Production acceptance: NOT YET CERTIFIED** because the final 10% is environment-dependent live validation, especially RLS, Storage, cross-project isolation, RPC authorization and end-to-end role execution.

## Highest-priority remaining engineering work

1. Engineer marked-up drawing / appraisal report upload.
2. Engineer decision taxonomy: Approved / Approved as Amended / Information / Rejected.
3. Explicit Engineer → Surveyor verification branch and return-to-Engineer result.
4. Explicit visual NSC/In-Service pre-survey branch for Surveyor.
5. Execute the live security acceptance matrix with eight real test accounts.
6. Execute complete role-by-role browser workflow tests against a real Supabase project.

These are deliberately called out rather than hidden so the system can be taken to a genuine production acceptance stage professionally.

---

# v2.1 Audit Closure Addendum

The four residual items listed in Sections 3 and 4 of this audit were addressed in `production_v2_1_engineer_surveyor_completion.sql` and the role workspaces:

1. **Engineer marked-up drawing + appraisal report — CLOSED.**
2. **Explicit Engineer decision taxonomy — CLOSED.**
3. **Engineer → Surveyor verification branch — CLOSED.**
4. **First-class Surveyor NSC/In-Service branch — CLOSED.**

For the cumulative role-diagram audit, these items are now implementation-complete at the static application/database level. Live Supabase/RLS/browser acceptance remains a separate production verification step.
