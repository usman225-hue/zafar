# EPAS v1.6 — GM/DM Flow Comparison and Gap Closure

## Source workflow baseline

### Plan Appraisal
GM drawing intake
-> GM forwards to DM
-> DM receives version
-> Engineer authorization / competency / availability / workload
-> Assign specific authorized Engineer
-> Engineer appraisal
-> DM reviews appraisal
-> Changes required -> Engineer
-> Rejected/Amended -> GM
-> GM sends to Designer
-> Designer resubmits
-> DM receives new revision
-> Engineer re-review
-> Approved -> GM final approval.

### Survey RFI
GM forwards RFI
-> DM reviews scope/survey type
-> Surveyor authorization / specialization / competency / availability
-> Assign specific authorized Surveyor
-> Surveyor conducts and reports
-> DM reviews report and observations
-> No observations -> GM
-> Observations -> DM review only; remain open
-> GM final approval
-> Send back -> DM corrective action
-> Surveyor / Ship Management
-> controlled evidence
-> DM verification
-> Follow-up RFI
-> DM scope review
-> repeat workflow.

## Critical issues found in v1.5 and fixed in v1.6

1. **Pre-GM observation clearing**
   - v1.5 allowed DM/GM observation clearing during the pre-GM survey-review stage.
   - v1.6 removes the UI action and restricts the RPC.
   - Observations can only be verified through the corrective-action stage.

2. **Corrective action had no exact observation binding**
   - v1.6 links open observations to the corrective action issued by DM.
   - DM verification closes those linked observations transactionally.

3. **Follow-up RFI had weak lineage**
   - v1.6 adds `rfis.follow_up_of_rfi_id`.
   - Final certificate logic can now prove which Follow-up RFI completed the loop.

4. **Certificate could be issued before DM acknowledgement**
   - v1.6 requires the `DM_GM_FINAL_APPROVAL_ACK` task to be completed.
   - The GM UI locks the certificate action until acknowledgement is received.

5. **Interim-to-final certificate was too loosely linked**
   - v1.6 requires the linked Follow-up RFI to be GM-approved with zero open observations and DM acknowledgement before the final certificate can be issued.

6. **DM review package was not sufficiently visible**
   - DM review notes are now stored on the RFI.
   - GM sees the DM review package before making the final decision.

## Remaining deployment validation

After applying v1.6 against the live Supabase project, perform role-by-role tests for:
GM, DM, Engineer, Surveyor, Designer, Ship Management, Owner, Shipyard.

The application cannot be called production-certified until those live RLS, Storage and RPC transaction tests pass.
