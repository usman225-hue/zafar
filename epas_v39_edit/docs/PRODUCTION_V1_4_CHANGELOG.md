# EPAS Production v1.4 — Critical Workflow Closure

## Objective
Make the GM and DM workflows real, professional, complete and usable in a production multi-user environment, with authenticated Engineer, Surveyor, Designer and Ship Management execution portals.

## Critical closures

1. **RPC-only RLS boundary**
   - Removes every INSERT/UPDATE/DELETE policy on `workflow_tasks`, `plan_drawings`, `plan_appraisal_observations`, `document_revisions`, and `notifications`.
   - Revokes browser table mutation privileges for `anon` and `authenticated`.
   - Keeps scoped SELECT policies.
   - Task and notification mutation now goes through trusted RPCs.

2. **GM rejected/amended decision**
   - DM `rejected_amended` creates a GM decision task.
   - GM can send to Designer or return to DM for clarification.
   - Designer revision returns to DM, then Engineer.

3. **Engineer execution portal**
   - Authenticated Engineer receives actual assignments.
   - Accept → Start → Technical appraisal.
   - Observation register with severity, clause and drawing reference.
   - Acceptance is blocked while open observations remain.

4. **Surveyor execution portal**
   - Authenticated Surveyor receives RFI execution tasks.
   - Accept → Start → report + observations.
   - Corrective action execution with evidence.

5. **Designer revision portal**
   - Initial drawing intake is supported.
   - GM/DM correction tasks are actionable.
   - Corrected PDF is uploaded to a controlled revision folder.
   - RPC validates the exact storage path and creates the revision record.

6. **Observation register**
   - Plan appraisal observations can be responded to and closed.
   - Survey observations can be cleared by DM/GM with a closure note.
   - Observation actions are audited.

7. **GM project workspace / health**
   - Project health aggregates milestones, drawings, RFIs, observations, overdue tasks, escalations and risks.
   - Project information, team, milestones, risk/decision register and audit trail are visible.

8. **DM resource + SLA engine**
   - Workload, remaining capacity, assigned tasks, overdue tasks, tasks due within seven days and same-date workload conflicts are shown.
   - SLA breach can be escalated to GM with reason, recommendation and severity.

9. **GM escalation decision**
   - Acknowledge, Return to DM, Resolve or Reject.
   - Decision is persisted and audited.

10. **Audit/security architecture**
   - Trusted RPCs create audit events.
   - A row-change trigger provides a final audit safety net for critical workflow tables.
   - Actor, role, timestamp, entity, old/new status, reason and request metadata are captured where available.

## Deployment order

```text
1. database/schema.sql
2. database/upgrade_schema.sql
3. database/production_schema.sql
4. database/production_v1_4.sql
5. Configure Supabase Auth users + profiles
6. Link internal/external users through project_members
7. Configure Storage bucket: project-documents
8. Deploy Streamlit application
9. Run production role-by-role acceptance test
```

**Do not run the v1.4 migration before the first three schema files.**
