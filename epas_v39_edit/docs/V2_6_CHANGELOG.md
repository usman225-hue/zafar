# EPAS v2.6 Change Log

## Workflow enforcement
- Added immutable drawing impact comparison history and snapshot.
- Added immutable, versioned survey execution basis with SHA-256 fingerprint.
- Added scope acknowledgement and scope-amendment cascade that invalidates prior survey handover state.
- Added versioned checklist definitions and response binding.
- Added structured Surveyor professional declaration.
- Added formal assignment acceptance/package acknowledgement versioning.
- Added composite server-side survey-start and report-submit gates.

## Certificate governance
- Added decision-package SHA-256 fingerprint.
- Added versioned DM acknowledgement tied to exact package fingerprint.
- Certificate gate now consumes the exact frozen package/acknowledgement.

## In-Service operations
- Removed silent 12-month fallback from the recurring schedule engine.
- Added explicit schedule configuration state and schedule-basis history.
- Linked new In-Service RFIs to the active schedule cycle.
- Added guided Owner / Ship Management In-Service initiation.
- Added service-role scheduler tick and scheduler run history.
- Added phase-specific notification policy.

## Ship Register
- Added actual survey completion/report timestamps and certificate issue date.
- Corrected status-history projection to compare prior state before update.
- Kept In-Service as a continuing phase while individual survey cycles complete.

## Security
- Hardened protected timeline/schedule reads with project membership.
- Restricted evidence submission to the exact project/RFI/corrective-action context.
- Removed authenticated access to broad global scheduler functions.

## UI
- Surveyor workspace now exposes formal assignment acceptance, scope acknowledgement, package acknowledgement, start gate and professional declaration.
- Owner / Ship Management workspaces now provide guided current-cycle In-Service RFI initiation.
