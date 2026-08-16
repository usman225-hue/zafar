# EPAS v2.6 — Final Workflow Acceptance & Production Hardening

EPAS v2.6 is the cumulative workflow-enforcement release after v2.5.

## Authoritative stakeholder RFI rules

| Role | NSC Survey RFI | In-Service Survey RFI |
|---|---:|---:|
| Shipyard | Yes | No |
| Owner | No | Yes |
| Ship Management | No | Yes |

These rules are enforced by the `rfi_creation_policy` table and the server-side RFI creation RPCs.

## Final controlled survey gate

A Surveyor cannot start a survey until all of the following are true:

1. The formal survey assignment has been accepted.
2. The current survey scope version has been acknowledged.
3. The controlled drawing package has been acknowledged.
4. All mandatory pre-survey checklist items are complete.
5. Any drawing revision impact has an explicit DM decision.
6. The exact execution basis is frozen and hashed.

The execution basis records the exact scope, assignment version, drawing package version, checklist version and file fingerprints used for the survey.

## In-Service recurrence

An individual In-Service survey cycle can complete without completing the In-Service project phase. The schedule engine creates the next survey due date from an explicit schedule basis and configured interval. A silent 12-month interval is no longer accepted.

The schedule also stores the active RFI for the current cycle and provides a guided Owner / Ship Management action to initiate the correct In-Service RFI.

## Certificate governance

Certificate issuance requires:

- a frozen certificate decision package;
- a package SHA-256 fingerprint;
- a DM acknowledgement tied to the exact package version/fingerprint;
- the correct open-observation state for the certificate type.

## Security hardening

The release adds project-membership checks for protected read RPCs, project-scoped evidence authorization, phase-specific notification policy and a service-role-only scheduler tick.

## Operational scheduler

The database includes `epas_scheduler_tick()` for a service-role scheduler. Configure the environment's scheduler (for example Supabase Cron) to execute the function on the desired cadence.

Example configuration:

```sql
select cron.schedule(
  'epas-survey-lifecycle-hourly',
  '5 * * * *',
  $$select public.epas_scheduler_tick();$$
);
```

The scheduler function rejects non-`service_role` callers.

## Live acceptance still required

Static tests validate the implementation structure. A real deployment must still execute the seven/eight-role acceptance matrix against the live Supabase project, including RLS, Storage access, cross-project isolation and the complete recurring In-Service cycle.
