# EPAS v2.2 Audit Scope

The cumulative v2.2 package was checked against the requested project-scope behavior:

- Plan-only projects terminate after Plan Appraisal completion.
- Projects containing NSC cannot enter NSC until its predecessor is complete.
- Projects containing NSC + In-Service cannot enter In-Service until NSC is closed.
- In-Service without NSC waits for Plan Appraisal if Plan Appraisal is selected.
- Ship Register exposes vessel survey status and next due date.
- Survey status is recalculated from RFI/certificate/observation state.
- Stakeholder RFI initiation is server-gated by both role and project phase.
- Shipyard remains NSC-only.
- Owner and Ship Management remain In-Service-only.
