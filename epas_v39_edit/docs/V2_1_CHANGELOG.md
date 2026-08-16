# EPAS v2.1 Change Log

## Engineer
- Added controlled Marked-Up Drawing artifact.
- Added controlled Technical Appraisal Report artifact.
- Added SHA-256, MIME and size validation.
- Added explicit four-value Engineer decision taxonomy.
- Added amendment/observation validation rules.
- Added explicit Surveyor verification request.

## Surveyor
- Added dedicated Plan Appraisal Verification queue.
- Added VERIFIED / NOT_VERIFIED transaction.
- Added first-class NSC vs In-Service visual branch.
- Added explicit pre-survey path descriptions.

## Security
- Artifact registration is RPC-controlled.
- Artifact table is RLS-enabled.
- Direct artifact writes are revoked from authenticated clients.
- Verification task ownership is checked server-side.

## Business rule preserved
- Shipyard: NSC Survey RFI only.
- Owner: In-Service Survey RFI only.
- Ship Management: In-Service Survey RFI only.
