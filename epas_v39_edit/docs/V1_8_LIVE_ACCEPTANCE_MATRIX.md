# EPAS v1.8 Live Acceptance Matrix

Run this matrix against a real Supabase project with eight test identities:

- GM
- DM
- Engineer
- Surveyor
- Designer
- Ship Management
- Owner
- Shipyard

## Stakeholder RFI

| Test | Owner | Ship Mgmt | Shipyard | Expected |
|---|---:|---:|---:|---|
| Create NSC RFI | ✓ | ✓ | ✓ | RFI created in GM Intake |
| Create In-Service RFI | ✓ | ✓ | ✓ | RFI created in GM Intake |
| Direct INSERT into `rfis` | ✗ | ✗ | ✗ | Denied |
| Read another stakeholder's RFI status | ✗ | ✗ | ✗ | Denied |
| Read own RFI status | ✓ | ✓ | ✓ | Allowed |
| Read internal DM/GM notes | ✗ | ✗ | ✗ | Hidden |

## Corrective actions

| Test | Expected |
|---|---|
| DM selects exact observations | Action links only selected observations |
| DM omits observation selection | RPC rejects |
| DM selects another RFI observation | RPC rejects |
| DM selects already-linked observation | RPC rejects |
| Assignee submits evidence | Action becomes submitted |
| Non-DM tries to clear observation | Denied |
| DM verifies evidence | Linked observations become cleared and verification history is written |
| Follow-up created | `follow_up_of_rfi_id` points to original RFI |

## Certificates

| Test | Expected |
|---|---|
| GM approves | `GM_APPROVED` event |
| DM acknowledgement | `READY_FOR_ISSUANCE` gate |
| GM issues | `ACTIVE` |
| 60 days or less to expiry | `EXPIRING` |
| Past expiry | `EXPIRED` |
| Interim finalized | old certificate `SUPERSEDED`, final certificate `ACTIVE` |

## Documents

| Test | Expected |
|---|---|
| Upload valid PDF | Accepted by policy |
| Upload disallowed MIME | Rejected |
| Upload oversized file | Rejected |
| Register revision | Parent lineage recorded |
| Release revision | Previous released revision becomes superseded/withdrawn |
| Stakeholder reads draft | Denied |
| Stakeholder reads released revision | Allowed |

## Isolation

Every role must be tested against another project and another user's records. Expected result is denial or zero rows, never partial leakage.
