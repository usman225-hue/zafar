# EPAS v2.2 Change Log

- Added authoritative project phase orchestration.
- Added sequential phase gates: Plan Appraisal → NSC → In-Service where selected.
- Added explicit end-of-scope behavior for Plan-only projects.
- Added NSC closure gate before In-Service can begin when both are selected.
- Added persistent vessel survey/class status and status history.
- Added live Ship Register view backed by `epas_ship_register`.
- Added next-survey due and last-survey information to the vessel state.
- Added server-side stakeholder RFI phase gating.
- Preserved the business rule: Shipyard = NSC only; Owner/Ship Management = In-Service only.
- Added triggers to keep project phase and vessel survey state synchronized with workflow changes.
- Added project workspace roadmap and locked-phase presentation.
