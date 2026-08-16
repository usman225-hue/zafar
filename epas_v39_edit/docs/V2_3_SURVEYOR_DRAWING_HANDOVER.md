# EPAS v2.3 — Controlled Approved Drawing Handover

## Business rule

For both **NSC** and **In-Service** surveys, Plan Appraisal drawings become available to the Surveyor only after they are approved.

When the Department Manager assigns a Surveyor to a specific RFI, the DM selects the **relevant approved drawings** for that survey. The server creates a controlled package linking:

`RFI → Surveyor → Approved Drawing Revision`

The Surveyor sees those drawings in the assigned survey workspace as read-only controlled references.

## Sequence

Plan Appraisal → Drawing Approved → Survey RFI Open/Eligible → DM Assigns Surveyor → DM Selects Relevant Approved Drawings → Controlled Package Created → Surveyor Receives Package → Survey Execution

This applies identically to:

- NSC Survey
- In-Service Survey

## Security

- Surveyor cannot browse all project drawings.
- Surveyor cannot access an unapproved Plan Appraisal drawing through the application RLS path.
- Surveyor cannot insert/update/delete package rows directly.
- Package creation is performed by a SECURITY DEFINER RPC after server-side validation.
- Survey report submission is blocked when approved drawings exist but no package has been handed over.
- Previous packages remain auditable; reassignment revokes the previous active package and creates a new package.

## Relevance

The DM deliberately selects the drawings relevant to the survey rather than automatically exposing every approved drawing. This supports survey-specific packages and avoids unnecessary document exposure.
