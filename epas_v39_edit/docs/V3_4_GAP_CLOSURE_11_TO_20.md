# EPAS v3.4 Gap Closure — Audit Points 11–20

## 11 Cache keys
Central `make_key()` creates stable, versioned cache keys. High-frequency bundle and batch helpers use it.

## 12 Upload memory
Upload validation now checks declared size before materializing the file and materializes the byte buffer exactly once in the authoritative upload path. UI prechecks use metadata only.

## 13 Certificate upload
Certificate PDF registration uses the canonical transactional helper with orphan cleanup and true SHA-256/size registration.

## 14 Survey report
Survey report submission uses the canonical v3.4 path, actual PDF SHA-256, strict PDF validation and orphan cleanup. Surveyor UI shows controlled file readiness and the server remains authoritative.

## 15 GM
GM now has a decision-first summary: Plan approvals, Survey decisions, overdue work and escalations.

## 16 DM
DM now has a queue-first summary for assignments, overdue work, open actions, survey due items and certificates.

## 17 Engineer
Engineer review cards now consolidate revision, observation count, task state and due date into one technical package summary.

## 18 Surveyor
Surveyor has an explicit start-readiness checklist covering assignment, scope, drawing package, checklist, revision impact and execution basis.

## 19 Designer
Designer revision history is rendered as a clearer revision timeline with state and submission time.

## 20 Owner / stakeholder
Owner, Ship Management and Shipyard receive role-specific fleet/project snapshot metrics and explicit server-side phase-boundary messaging.
