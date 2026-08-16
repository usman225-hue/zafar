# EPAS v1.8 Change Log

## Corrective-action precision

- Added normalized `corrective_action_observations` relationship.
- Added exact observation selection to DM corrective-action assignment.
- Prevented duplicate observation assignment.
- Added `observation_verifications` history.

## Observation closure

- Revoked generic authenticated survey-observation clearing.
- Added `epas_dm_verify_corrective_action()`.
- Verification requires controlled evidence and an active DM verification task.
- Verification is the only supported closure transaction.
- Verified closure creates the linked follow-up RFI.

## Stakeholder security

- Stakeholder RFI initiation is role-specific: Shipyard creates NSC RFIs only; Owner and Ship Management create In-Service RFIs only.
- Direct authenticated writes to `rfis` are revoked.
- Stakeholder RFI status hides internal DM/GM notes.
- Owner and Shipyard workspaces now include RFI initiation/status controls.
- Ship Management workspace now includes RFI initiation/status controls.

## Certificate control

- Added explicit `lifecycle_state`.
- Added role-aware lifecycle transitions.
- Added expiry-state refresh function.
- Preserved existing `status` field for compatibility.

## Document control

- Added document number and revision lineage.
- Added lifecycle state and lifecycle events.
- Added document policy registry for MIME/size/hash rules.
- Added controlled revision registration RPC.
- Releasing a new revision supersedes the previous released revision.

## Testing

- Added static v1.8 security/workflow tests.
- Added live acceptance matrix and database security preflight.
- Static regression suite: **32 passed** in the available environment.
- Streamlit browser smoke tests require the application's runtime dependencies and a configured live Supabase environment; they were not claimed as live-tested here.


## Clarification patch — stakeholder RFI initiation
- Shipyard can initiate **NSC Survey RFI only**.
- Owner can initiate **In-Service Survey RFI only**.
- Ship Management can initiate **In-Service Survey RFI only**.
- Server-side RPC rejects all other combinations; UI exposes only the permitted phase.
