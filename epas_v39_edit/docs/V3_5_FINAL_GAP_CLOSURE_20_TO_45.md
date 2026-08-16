# EPAS v3.5 — Final gap closure (audit points 20–45)

## Owner
Dedicated fleet cockpit: fleet total, surveys due, overdue, expiring certificates, open released actions, and vessel table.

## Ship Management
Consolidated corrective-action queue: requirement, deficiency, responsible party, due date, action, evidence status and verification status.

## Shipyard
Dedicated NSC-only operations cockpit and server-side NSC phase filtering.

## Coordination
Cross-role coordination timeline and project phase workflow summary: Plan → NSC → persistent In-Service → recurring cycles.

## Recurrence
In-Service remains ACTIVE after each cycle; the next cycle is maintained by the self-contained v3.5 scheduler and idempotent cycle model.

## Security
Role/phase data minimization, RLS reassertion, privilege inventory, audit-chain verification, and restricted internal gate access are included.

## File security
Existing signature/MIME/size/SHA-256 validation remains authoritative; ClamAV can be required with `EPAS_REQUIRE_ANTIVIRUS=1`.

## Performance
Bounded session cache, consolidated stakeholder bundles, query indexes, and a load-test harness for 10/30-user verification are included.

## UX / accessibility
Role-native dashboards, workflow state visibility, responsive layout, keyboard focus and reduced-motion rules are retained and expanded.

## Final live checks
The package includes non-destructive acceptance and load-test harnesses, but live Supabase RLS/Storage/Cron and concurrent-user testing must still be executed in the deployed environment.
