# EPAS v1.8 Role Permission Matrix

| Capability | GM | DM | Engineer | Surveyor | Designer | Ship Mgmt | Owner | Shipyard |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Create NSC RFI | ✓ | — | — | — | — | ✓ | ✓ | ✓ |
| Create In-Service RFI | ✓ | — | — | — | — | ✓ | ✓ | ✓ |
| Review GM RFI Intake | ✓ | — | — | — | — | — | — | — |
| Assign DM | ✓ | — | — | — | — | — | — | — |
| Assign Engineer | — | ✓ | — | — | — | — | — | — |
| Technical appraisal | — | — | ✓ | — | — | — | — | — |
| Conduct survey | — | — | — | ✓ | — | — | — | — |
| Submit corrective evidence | — | — | — | ✓ | — | ✓ | — | — |
| Select exact observations for corrective action | — | ✓ | — | — | — | — | — | — |
| Verify corrective action / close observations | — | ✓ | — | — | — | — | — | — |
| Create follow-up RFI | — | ✓ | — | — | — | — | — | — |
| Submit design revision | — | — | — | — | ✓ | — | — | — |
| Approve / reject certificate | ✓ | — | — | — | — | — | — | — |
| DM certificate acknowledgement | — | ✓ | — | — | — | — | — | — |
| Release controlled document | ✓ | ✓ | — | — | — | — | — | — |
| View released documents | ✓ | ✓ | ✓* | ✓* | ✓* | ✓* | ✓* | ✓* |
| View internal appraisal records | ✓ | ✓ | ✓** | ✓** | — | — | — | — |

`*` Only records released to that audience and permitted by RLS.

`**` Only records required for the assigned technical task.

## Security principle

Stakeholder RFI initiation is a **write capability implemented through a security-definer RPC**, not direct table INSERT access. Internal classification review remains protected.


## Stakeholder RFI initiation rule (clarified)

| Role | NSC Survey RFI | In-Service Survey RFI |
|---|---|---|
| Shipyard | **May initiate** | **Cannot initiate** |
| Owner | **Cannot initiate** | **May initiate** |
| Ship Management | **Cannot initiate** | **May initiate** |

The database RPC enforces this rule server-side; the UI only exposes the permitted survey phase.
