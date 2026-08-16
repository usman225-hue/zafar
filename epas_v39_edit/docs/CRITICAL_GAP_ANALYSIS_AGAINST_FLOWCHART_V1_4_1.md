# Critical Gap Analysis Against Supplied GM/DM Workflow

## Workflow baseline
The supplied diagram requires two principal internal workflows:

1. Plan Appraisal:
GM drawing intake -> DM technical review -> authorization/competency/availability ->
specific Engineer -> appraisal -> DM review -> GM decision / Designer correction ->
new revision -> DM -> Engineer loop.

2. Survey RFI:
GM RFI -> DM scope/type review -> surveyor authorization/competency/availability ->
specific Surveyor -> survey/report -> DM review -> GM approval/send-back ->
corrective action -> Surveyor/Ship Management -> evidence -> DM verification ->
Follow-up RFI -> DM.

## Critical gaps still remaining after v1.4

### C1 — Stakeholder document release is not yet wired to the actual document lifecycle
v1.4.1 adds `stakeholder_visible` and `release_status`, but there is no complete GM/DM
release action in the UI/RPC that changes a document from internal to released.
**Status: CRITICAL**

### C2 — Owner and Shipyard are read-only, but their full stakeholder information model is incomplete
The portal is present, but controlled views for released drawings, certificates, milestone
status, correspondence and formal submissions are not yet a complete stakeholder DMS.
**Status: HIGH**

### C3 — Designer initial submission task is not a true task handover
Initial submission goes through a dedicated RPC to GM, but it is not represented as a
standard stakeholder task with acceptance/SLA tracking.
**Status: HIGH**

### C4 — Designer correction must be linked to a specific rejected/amended decision
The UI shows the correction task, but production validation should enforce that the revision
is for the exact drawing/revision/decision that generated the correction.
**Status: HIGH**

### C5 — Survey observation model is less detailed than plan appraisal observations
Survey observations need clause/reference, location, deficiency category, evidence,
responsible party, target date, verification method and closure history.
**Status: HIGH**

### C6 — Corrective action evidence is not yet a controlled document workflow
The file is uploaded and linked, but production needs immutable evidence revision,
checksum, MIME/size validation, uploader identity, evidence type and release/retention.
**Status: HIGH**

### C7 — GM final certificate lifecycle needs formal closure controls
The flow shows Interim -> corrective action -> follow-up -> final approval -> certificate.
A formal state machine is still required to prevent premature full certificate issuance.
**Status: CRITICAL**

### C8 — Project Health is calculated, but management thresholds need formal configuration
The dashboard should have configurable SLA/health thresholds by project/vessel/work package,
not only generic percentages.
**Status: MEDIUM**

### C9 — Resource planning needs date-range conflict detection
Current capacity/workload logic is stronger than the original version, but production should
check overlapping assignments across their actual due/start ranges, leave, and assignment priority.
**Status: HIGH**

### C10 — Escalation resolution needs downstream task linkage
GM can decide escalation, but a resolved/returned escalation should optionally create or
close a linked corrective/management task with due date and owner.
**Status: HIGH**

### C11 — Audit must cover external stakeholder document views/downloads
The mutation audit is strong, but access to released/confidential documents should also be
auditable for regulated traceability.
**Status: HIGH**

### C12 — Live database acceptance testing is still required
Static tests cannot prove Supabase RLS, SECURITY DEFINER ownership, grants, Storage policies,
or transaction behavior. A real authenticated role-by-role acceptance test is mandatory.
**Status: CRITICAL**
