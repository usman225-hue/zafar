# EPAS v1.4 Production Acceptance Test

## 1. Security
- [ ] Authenticated user receives role from `profiles` only.
- [ ] No actor selector exists.
- [ ] Direct INSERT/UPDATE/DELETE against critical workflow tables fails for authenticated browser clients.
- [ ] RPC state transition succeeds for an authorized user.
- [ ] Unauthorized user receives an authorization error.

## 2. Plan Appraisal
- [ ] Designer submits initial drawing.
- [ ] GM receives drawing intake task.
- [ ] GM forwards drawing to active project DM.
- [ ] DM sees only eligible Engineer resources.
- [ ] Engineer accepts/starts task.
- [ ] Engineer records observations.
- [ ] Observation register is persisted.
- [ ] DM can review and send changes.
- [ ] Engineer reworks.
- [ ] DM can mark rejected/amended.
- [ ] GM can send amended design to Designer.
- [ ] Designer uploads new revision.
- [ ] New revision returns to DM.
- [ ] Approved revision becomes controlling revision.

## 3. Survey RFI
- [ ] GM forwards RFI to active project DM.
- [ ] DM sees eligible Surveyors.
- [ ] Surveyor accepts/starts survey.
- [ ] Survey report is submitted.
- [ ] Survey observations are persisted.
- [ ] DM reviews report.
- [ ] GM approves or sends back.
- [ ] Corrective action can be assigned to Surveyor/Ship Management project member.
- [ ] Evidence is submitted.
- [ ] DM verifies.
- [ ] Follow-up RFI is created.

## 4. Management control
- [ ] GM project health is visible.
- [ ] DM workload/capacity is visible.
- [ ] SLA overdue tasks are visible.
- [ ] DM can escalate.
- [ ] GM can acknowledge / return / resolve / reject escalation.
- [ ] Risk and decision registers are persisted.

## 5. Audit
- [ ] Task accept/start/complete creates audit records.
- [ ] Drawing transitions create audit records.
- [ ] Observation actions create audit records.
- [ ] Escalation decisions create audit records.
- [ ] Audit includes actor, role, timestamp, entity and old/new status.
