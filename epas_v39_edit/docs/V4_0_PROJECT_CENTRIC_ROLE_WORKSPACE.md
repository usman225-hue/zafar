# EPAS v4.0 — Project-Centric Role Workspace

## Frontend behavior

- Global navigation is used to reach the Projects register.
- Only GM Classification sees **Create Project**, and it appears only on the Projects register.
- After a project is opened, the left sidebar changes to the selected project context.
- Project navigation contains:
  - Project Overview
  - Plan Appraisal (only if in project scope)
  - NSC Survey (only if in project scope)
  - In-Service Survey (only if in project scope)
  - Survey Status (review-only)
  - Risk Register
  - Ship Register (review-only)
  - Certification
  - Documents
  - Notifications
  - Audit Trail
- The Project Overview deliberately excludes Workflow Snapshot and Recent Activity.
- The overview is focused on Project Health, Survey Due, Open Observations, Certificates, Overdue Tasks, Project Lifecycle, Survey Status, Priority Actions, Milestones, Certificates and Project Summary.

## Security

The UI is not the security boundary. Project membership, role and phase permissions remain enforced by the production RPC/RLS layer.
