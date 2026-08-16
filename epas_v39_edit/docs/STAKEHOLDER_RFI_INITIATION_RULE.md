# Stakeholder RFI Initiation Rule

## Final business rule

| Role | NSC Survey RFI | In-Service Survey RFI |
|---|---|---|
| Shipyard | **Allowed** | **Not allowed** |
| Owner | **Not allowed** | **Allowed** |
| Ship Management | **Not allowed** | **Allowed** |

## Workflow

### NSC Survey
Shipyard → GM Intake → DM Scope Review → Surveyor Assignment → Survey → DM Review → GM Decision → Certificate / Follow-up

### In-Service Survey
Owner OR Ship Management → GM Intake → DM Scope Review → Surveyor Assignment → Survey → DM Review → GM Decision → Certificate / Follow-up

The restriction is enforced server-side in `epas_stakeholder_create_rfi`; the UI only presents the phase permitted for the authenticated stakeholder role.
