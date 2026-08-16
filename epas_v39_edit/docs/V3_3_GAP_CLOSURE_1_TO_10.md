# EPAS v3.3 Gap Closure Matrix — Issues 1 to 10

| # | Audit issue | v3.3 action | Status |
|---|---|---|---|
| 1 | Live security acceptance missing | Added live acceptance harness + acceptance evidence table for RLS, Storage, session isolation, stakeholder phase isolation, Cron, recurrence | IMPLEMENTED; live evidence requires deployed environment |
| 2 | v3.2 facade delegated to older layers | Added v3.3 authoritative application RPC facade and revoked direct authenticated access to lower-version survey-control entry points | CLOSED at application boundary |
| 3 | N+1 task/drawing/RFI queries | Added batch drawing/RFI RPCs and rewired Engineer/Surveyor/DM workspaces | CLOSED for audited active paths |
| 4 | `select(*)` overuse | Narrowed active production projections for tasks, documents, certificates, audit, scheduler and governance reads | CLOSED for audited production paths |
| 5 | Certificate upload transactionality | Certificate upload uses cleanup-on-registration-failure and v3.3 controlled registration RPC | CLOSED |
| 6 | Broad cache invalidation | Added targeted prefix invalidation while preserving bounded session-local safety | CLOSED for new v3.3 mutation paths |
| 7 | Large upload memory/security risk | Single upload buffer, strict size validation, optional fail-closed ClamAV scan, cleanup path and no duplicate client copies | CLOSED in application layer; load-test live |
| 8 | Stakeholder fleet/project query load | Added authorized project, fleet and vessel bundles with server-side role/phase filtering | CLOSED for audited stakeholder surfaces |
| 9 | Scheduler wrapper delegated to older layer | Added service-role-only v3.3 scheduler wrapper and v3.3 Cron deployment | CLOSED at application boundary; Cron execution needs live evidence |
| 10 | Final security/audit proof incomplete | Added live acceptance script, audit evidence table, malware scan hook, release validator and deployment checklist | IMPLEMENTED; live evidence requires deployment |

## Validation

- Python compile: PASS
- Regression tests: 192 passed, 1 skipped (browser/Streamlit runtime unavailable in build environment)
- v3.3 production release validator: PASS
