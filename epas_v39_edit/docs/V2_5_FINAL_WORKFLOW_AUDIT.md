# EPAS v2.5 Final Workflow Audit — Static Review

## 1. Project / phase orchestration

**Result: PASS at static design level.**

- Plan Appraisal gates later selected phases.
- NSC gates In-Service when NSC is selected.
- In-Service is represented as a continuing phase; survey cycle completion does not close the phase.
- `scope_status` and `project_phase_control.lifecycle_status` distinguish phase/cycle semantics.

## 2. RFI initiation policy

**Result: PASS at static design level.**

- Shipyard: NSC only.
- Owner: In-Service only.
- Ship Management: In-Service only.
- Policy is restated in the final cumulative migration and consumed by the stakeholder creation RPC.

## 3. Plan Appraisal → Surveyor drawing handover

**Result: PASS at static design level.**

- Only approved Plan Appraisal drawings may be shared.
- DM selects relevant drawings.
- Handover freezes revision/hash plus drawing metadata.
- Revisions create an impact decision requirement.
- Reissue creates a new package version.

## 4. Survey assignment / execution

**Result: PASS at static design level.**

- DM assignment is role-restricted.
- Resource eligibility snapshot is captured.
- Surveyor acceptance is required.
- Drawing package acknowledgement is required when a package exists.
- Mandatory checklist is required.
- Revision-impact changes require a DM decision.
- Server-side start gate controls execution.

## 5. Survey report / observation / corrective action

**Result: PASS at static design level.**

- Survey report submission is server-gated.
- Observation evidence requires exact observation/corrective-action linkage.
- Evidence uploader is constrained by project/RFI/action responsibility.
- Report basis records scope/package/checklist versions.

## 6. Certificate workflow

**Result: PASS at static design level.**

- Certificate issuance now requires a frozen decision package and a real DM acknowledgement.
- Interim/final certificate rule remains observation-aware.

## 7. In-Service recurring cycle

**Result: PASS at static design level.**

- Survey due date is independent of certificate expiry as a business concept.
- Interval and basis/reference are configurable.
- Current cycle RFI is tracked separately from the active In-Service phase.
- Cycle number increments after completion.

## 8. Security-definer read/control paths

**Result: PASS at static design level.**

- Timeline and schedule RPCs explicitly verify project access.
- Direct broad access to the Survey Control Tower view is revoked; clients use a member-aware RPC.
- Global refresh and due-notification functions are restricted to operator wrappers.
- Checklist and certificate gate helpers are membership-restricted.

## 9. Vessel status projection

**Result: PASS at static design level.**

- Previous survey status is captured before update.
- History row is written only on actual state change.
- Actual report completion/submission dates are used for last-survey projection.

## 10. Remaining production acceptance item

The package is structurally and statically hardened. The remaining validation step is environmental, not an unresolved workflow design gap: execute the seven/eight-role acceptance suite against a live Supabase instance with real RLS, Storage and browser flows.
