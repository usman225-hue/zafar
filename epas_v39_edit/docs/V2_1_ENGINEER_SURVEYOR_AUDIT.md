# EPAS v2.1 — Engineer + Surveyor Workflow Completion Audit

## Scope
This release closes the four residual workflow items identified in the v2.0 role-diagram audit.

### 1. Engineer marked-up drawing / appraisal report
**Status: COMPLETE**

The Engineer workspace now has two distinct controlled artifacts:
- Marked-up Drawing (PDF)
- Technical Appraisal Report (PDF)

Each artifact is registered against the project, drawing, current revision and Engineer task with:
- SHA-256
- MIME type
- file size
- uploader
- timestamp
- controlled storage path

The database RPC validates role, assignment, drawing state, artifact type, PDF format, size and SHA-256 before registering the artifact.

### 2. Explicit Engineer decision taxonomy
**Status: COMPLETE**

The Engineer now selects one of:
- APPROVED
- APPROVED_AS_AMENDED
- INFORMATION
- REJECTED

Rules are enforced server-side:
- APPROVED cannot contain observations.
- APPROVED_AS_AMENDED requires at least one amendment/observation.
- REJECTED requires a technical reason/observation package.
- A rejected conclusion cannot simultaneously request Surveyor verification.

The decision is stored on the drawing and recorded in workflow/audit history.

### 3. Engineer → Surveyor verification branch
**Status: COMPLETE**

The Engineer can explicitly request Surveyor verification.

Workflow:

```text
ENGINEER
  ↓
TECHNICAL DECISION
  ↓
Need Surveyor Verification?
  ├── NO → MANAGER REVIEW
  └── YES
        ↓
  ELIGIBLE SURVEYOR
        ↓
  SURVEYOR VERIFICATION
        ├── VERIFIED → MANAGER REVIEW
        └── NOT VERIFIED → ENGINEER FEEDBACK
```

Server-side controls include:
- Engineer assignment check
- Surveyor project membership
- active Surveyor authorization
- availability preference
- controlled verification task
- verification result and note
- workflow event and audit record

### 4. First-class NSC / In-Service Surveyor branch
**Status: COMPLETE**

The Surveyor workspace now visibly identifies the survey branch before the checklist/report process.

**NSC:**
Shipyard coordination → approved design package → access/schedule confirmation → survey execution.

**In-Service:**
Owner / Ship Management coordination → previous survey/certificate review → maintenance/change-of-class checks → survey execution.

The branch is derived from the controlled RFI phase and rejects an unrecognized phase before survey execution.

## Business RFI authority remains unchanged

| Role | NSC Survey RFI | In-Service Survey RFI |
|---|---:|---:|
| Shipyard | ALLOWED | DENIED |
| Owner | DENIED | ALLOWED |
| Ship Management | DENIED | ALLOWED |

This rule remains server-enforced by the stakeholder RFI RPC.

## Static validation
The cumulative relevant regression suite passes: **59 tests passed**.

Python compilation passes for the complete application tree.

The Streamlit browser smoke suite is not claimed as passed because the execution environment used for this package does not include the Streamlit test runtime or a live Supabase project.

## Production acceptance still required

Against the real Supabase project, execute at minimum:
1. Engineer uploads both controlled artifacts.
2. Engineer submits each of the four decision types.
3. Engineer requests Surveyor verification.
4. Surveyor receives and completes verification.
5. Surveyor returns NOT_VERIFIED and Engineer receives feedback.
6. Surveyor executes an NSC RFI from Shipyard origin.
7. Surveyor executes an In-Service RFI from Owner/Ship Management origin.
8. Unauthorized role/phase combinations are rejected by the RPC.
9. Cross-project and stakeholder release RLS is tested.
