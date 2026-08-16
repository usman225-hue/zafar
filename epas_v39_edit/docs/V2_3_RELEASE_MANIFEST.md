# EPAS v2.3 Release Manifest

## Baseline
EPAS v2.2 complete project phase orchestration package.

## New capability
Controlled handover of approved Plan Appraisal drawings to the assigned Surveyor for the specific survey RFI.

## Supported survey phases
- NSC Survey — Shipyard-originated RFI only.
- In-Service Survey — Owner / Ship Management-originated RFI only.

## Required sequence
1. Plan Appraisal drawings are submitted and technically approved.
2. Project phase gate permits the relevant survey phase.
3. DM reviews the survey RFI and assigns an eligible Surveyor.
4. DM selects the relevant approved drawings.
5. Server validates project, RFI phase, drawing approval and Surveyor membership.
6. Server creates the controlled survey drawing package and Surveyor execution task atomically.
7. Surveyor sees the package in the assigned survey workspace.
8. Survey report submission is blocked if approved drawings exist but no active package has been handed over.

## Security
Surveyors cannot browse the full project's Plan Appraisal drawings/documents/revisions. They can only access approved drawings explicitly linked to their assigned survey package. Package rows cannot be written directly by clients.

## Validation
- v2.3 focused tests: 14 passed.
- Cumulative non-browser static/regression tests: 73 passed.
- Full browser/Streamlit suite: not executed because Streamlit testing runtime is not installed in this build environment.
