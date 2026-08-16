# EPAS v2.4 — State-of-the-Art Lifecycle Release

This is the complete cumulative EPAS package based on v2.3. It includes the prior role workflows, stakeholder RFI rules, phase orchestration, Engineer/Surveyor controls, immutable survey drawing handover, and the v2.4 lifecycle completion layer.

## v2.4 highlights

- Recurring In-Service survey scheduling and due windows
- Continuing In-Service phase semantics
- Explicit survey scope / assignment / execution domain objects
- Immutable Surveyor drawing handover at revision/hash level
- Drawing revision impact detection
- Frozen certificate decision package
- Observation-level evidence binding
- Central role/phase RFI creation policy
- Controlled stakeholder RFI scope amendment workflow
- Authoritative Ship Register projection
- Lifecycle timeline and survey due notifications
- Database lifecycle synchronization triggers
- Professional lifecycle/schedule control tower

## RFI policy

- Shipyard → NSC Survey RFI only
- Owner → In-Service Survey RFI only
- Ship Management → In-Service Survey RFI only

## Deployment

Apply all migrations through v2.3, then apply:

`database/production_v2_4_state_of_art_lifecycle.sql`

Live production acceptance must be executed against the actual Supabase project using the supplied role/security acceptance matrix.
