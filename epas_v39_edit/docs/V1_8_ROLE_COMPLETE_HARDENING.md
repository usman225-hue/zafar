# EPAS v1.8 — Role-Complete Hardening

This patch closes the next professional workflow gaps after the stakeholder-RFI release.

## 1. Exact corrective-action binding

A DM must explicitly select the observations resolved by each corrective action. The server validates that every selected observation:

- belongs to the same RFI;
- is still open;
- is not already linked to another corrective action.

The normalized `corrective_action_observations` table is authoritative; the legacy `observations.corrective_action_id` field remains for compatibility.

## 2. Controlled observation closure

The generic survey-observation clear RPC is revoked for authenticated users. Observation closure is performed only by `epas_dm_verify_corrective_action()` after:

1. evidence submission;
2. evidence hash validation;
3. an active DM verification task;
4. explicit verification note.

Each closure is recorded in `observation_verifications`.

The verification transaction then creates the required follow-up RFI. The follow-up creation function itself never clears observations.

## 3. Stakeholder RFI security

Role-specific stakeholder initiation is enforced by `epas_stakeholder_create_rfi()`: Shipyard → NSC only; Owner/Ship Management → In-Service only.

Direct authenticated writes to `rfis` are revoked. Stakeholders receive controlled status only for RFIs they initiated; internal DM/GM review notes are hidden.

## 4. Certificate lifecycle

Certificates now have an explicit `lifecycle_state` in addition to the legacy `status` field. The lifecycle records the business process from draft/approval through active, expiring, expired, and superseded states.

`epas_transition_certificate_state()` enforces role-aware transitions and records lifecycle events.

## 5. Document lifecycle

Documents now have:

- document number;
- revision number;
- parent/superseded lineage;
- lifecycle state;
- approval/release metadata;
- document policy validation;
- lifecycle event history.

`epas_register_document_revision()` validates MIME type, file size and SHA-256 before registering a new controlled revision.

## 6. Acceptance/security preflight

`epas_security_preflight()` checks the deployment for the principal write/closure controls.

The repository also contains `tests/test_v18_role_complete_hardening.py` for static verification.

### Live acceptance still required

A real Supabase environment must be used to verify RLS, Storage policies, RPC execution, and cross-role isolation. Static tests cannot prove live database security.
