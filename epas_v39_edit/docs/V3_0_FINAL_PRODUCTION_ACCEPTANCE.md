# EPAS v3.0 Final Production Acceptance

## Scope
This checklist is the final live validation companion to the cumulative EPAS v3.0 package.

## Required accounts
GM, DM, Engineer, Surveyor, Designer, Owner, Ship Management, Shipyard.

## Required positive flows
- Plan Appraisal only: Designer → Engineer → DM/GM → Approved → project scope complete.
- Plan + NSC: Plan complete → Shipyard NSC RFI → GM → DM → Surveyor → survey → certificate/closure.
- Plan + NSC + In-Service: Plan → NSC → persistent In-Service phase → Cycle 1 → next due → Cycle 2.
- In-Service without NSC: Plan → In-Service active → Owner/Ship Management RFI → survey → cycle completion.
- Engineer verification branch: Engineer marks “Need Surveyor Verification” → Surveyor verifies → DM continues.
- Drawing handover: only approved, relevant Plan Appraisal revisions are shared to the assigned Surveyor.
- Scope amendment: acknowledgement/package/checklist/execution basis invalidated and rebuilt.

## Required negative security tests
- Shipyard cannot create or view In-Service RFI/schedule.
- Owner cannot create NSC RFI.
- Ship Management cannot create NSC RFI.
- Surveyor A cannot read Surveyor B package/checklist/evidence.
- Owner cannot call internal certificate issuance gate.
- Stakeholders cannot read internal GM/DM gate diagnostics.
- User from Project A cannot access Project B lifecycle/schedule/timeline.
- Direct execution of revoked legacy lifecycle RPCs must fail.
- Direct writes to RLS-protected operational tables must fail.
- Unassigned users cannot submit survey reports/evidence.

## Recurrence test
1. Complete In-Service Cycle 1.
2. Confirm phase remains ACTIVE.
3. Confirm Cycle 2 is created exactly once.
4. Confirm next due/window and Ship Register update.
5. Initiate Cycle 2 from Owner/Ship Management.
6. Complete Cycle 2.
7. Confirm Cycle 3 is created exactly once.

## Scheduler test
- Confirm pg_cron job exists and runs every 15 minutes.
- Force a schedule-state transition in a controlled test vessel.
- Confirm scheduler run record, status transition and notification.
- Introduce one controlled failure and confirm `scheduler_failures_v29` and degraded health.

## Browser acceptance
Run the Streamlit application with requirements installed and perform all role flows manually. Confirm keyboard focus, narrow viewport layout, error reference UX and state/blocker/next-action cockpit behavior.
