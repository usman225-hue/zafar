# EPAS v1.5 Deployment Runbook

## 1. Database migration

Run in this order on the target Supabase project:

1. `database/schema.sql`
2. `database/upgrade_schema.sql`
3. `database/production_schema.sql`
4. `database/production_v1_4.sql`
5. `database/production_v1_4_1.sql`
6. `database/production_v1_5.sql`

Do not skip earlier migrations on a fresh database.

## 2. Storage

Create a private bucket named `project-documents`.

Expected project path patterns:
- `projects/<project_id>/documents/<category>/<file>`
- `projects/<project_id>/plan-appraisal/intake/<file>`
- `projects/<project_id>/plan-appraisal/corrections/<file>`
- `projects/<project_id>/survey-reports/<rfi_id>/<file>`
- `projects/<project_id>/corrective-actions/<action_id>/<file>`
- `projects/<project_id>/certificates/<certificate_no>.pdf`

## 3. Scheduler

Run `epas_run_sla_monitor_v15()` every 15 minutes using Supabase pg_cron or an external trusted scheduler.

The function is intentionally NOT exposed to normal authenticated browser users.

## 4. Email

Run the existing `services/email_worker.py` as a trusted service using a service-role connection or protected backend credentials. The browser must never hold a service-role key.

## 5. Role acceptance testing

Test with real authenticated accounts:

GM, DM, Engineer, Surveyor, Designer, Ship Management, Owner, Shipyard.

## 6. Security tests

Confirm:
- Owner cannot read internal documents.
- Shipyard cannot read internal documents.
- Designer cannot assign Engineer.
- Ship Management cannot edit survey reports.
- Engineer cannot issue certificates.
- Surveyor cannot approve surveys.
- DM cannot issue certificates.
- GM can approve/reject and close projects.
- Released documents can be downloaded only by intended project stakeholders.


## v1.5.1 critical hardening migration
After `production_v1_5.sql` and `production_v1_4_1.sql`, apply:
`database/production_v1_5_1_security_and_release.sql`

This migration:
- removes legacy permissive RLS policies and direct browser mutations;
- makes workflow task/document/observation/RFI/certificate/governance reads role-aware;
- enforces RPC-only mutations for business tables;
- adds controlled stakeholder milestone release;
- secures certificate PDF access;
- guards internal resource/health/closure endpoints;
- revokes legacy overloaded RPC signatures;
- strengthens resource conflict/utilization calculations.

Before production use, run live Supabase acceptance tests with separate authenticated GM, DM,
Engineer, Surveyor, Designer, Ship Management, Owner and Shipyard accounts, including negative
permission tests and private Storage URL checks.
