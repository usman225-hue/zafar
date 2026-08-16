# EPAS v1.5.1 Production Acceptance Matrix

## Internal roles
- GM Classification
- Department Manager
- Authorized Engineer
- Authorized Surveyor

## External stakeholder roles
- Designer: controlled drawing submission/revision only
- Ship Management: assigned corrective-action execution only
- Owner: read-only released information
- Shipyard: read-only released information

## Plan Appraisal
1. Designer submits initial drawing.
2. GM receives drawing and forwards to DM.
3. DM receives revision and sees engineer eligibility based on authorization, competency, availability, workload and overlap.
4. DM assigns a specific Engineer.
5. Engineer accepts, starts and submits technical appraisal.
6. Engineer may create one or more structured observations.
7. DM reviews.
8. DM can return to Engineer for changes; return creates a new task and preserves audit history.
9. DM can mark design rejected/amended and forward a decision to GM.
10. GM can send the drawing to Designer or return the recommendation to DM.
11. Designer submits a controlled revision linked to the previous revision/correction decision.
12. Revision returns to DM before any Engineer re-review.
13. GM approves only the current revision.
14. Approved drawing becomes eligible for stakeholder release.
15. GM/DM can release the approved document to a selected stakeholder audience.
16. Owner/Shipyard only see released copies.

## Survey RFI
1. GM forwards RFI to DM.
2. DM sees scope/survey type.
3. DM sees only authorized/competent/available Surveyors.
4. DM assigns a specific Surveyor and schedule date.
5. Surveyor accepts/starts.
6. Surveyor submits a controlled report with declaration and optional evidence.
7. Surveyor can create structured observations with rule/location/category/responsible party/target/corrective action.
8. DM reviews and may clear observations only with a recorded verification note.
9. DM forwards the controlled review to GM.
10. GM approves clean RFI or sends it back.
11. Send-back creates a corrective-action workflow.
12. Corrective action may be assigned to Surveyor or Ship Management.
13. Evidence is submitted through a controlled Storage path with hash/mime/size metadata.
14. DM verifies the corrective action.
15. Follow-up RFI loops back to DM scope review.
16. Interim certificate may be finalized only after all relevant observations are verified closed.
17. Full certificate is linked to the superseded Interim certificate.

## Governance / Project Control
- Project is activated atomically at creation.
- Milestones are generated and can be explicitly released to stakeholders.
- GM can review project health, risks, decisions and audit.
- DM can review capacity, assigned hours, utilization, overdue work, due-soon work and overlapping tasks.
- SLA due dates use the configurable working-day SLA engine.
- GM escalation decisions create/return/resolve linked actions.
- Project closure checks verify drawings, observations, workflow tasks, corrective actions, escalations, milestones and certificate state.
- Closed projects are archived through the controlled closure RPC.

## Security acceptance
Negative tests must pass:
- Owner cannot read internal RFIs, observations, risks, decisions or audit.
- Shipyard cannot read internal appraisal work.
- Designer cannot assign Engineer/Surveyor.
- Ship Management cannot modify survey report or observations.
- Engineer cannot make DM/GM decisions.
- Surveyor cannot clear observations.
- DM cannot approve as GM.
- Owner/Shipyard cannot upload workflow records.
- Authenticated users cannot directly INSERT/UPDATE/DELETE workflow business tables.
- Legacy RPC overloads are not executable.
- Private Storage URLs are generated only through controlled access paths.

## Evidence to retain
For every transition capture:
- actor
- role
- timestamp
- project
- entity
- old state
- new state
- action
- reason
- request metadata when available
- document hash for controlled files
