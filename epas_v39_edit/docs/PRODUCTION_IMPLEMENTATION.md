# EPAS GM + Department Manager Production Workflow

## Purpose
This release converts the GM and Department Manager workflows from the supplied flowcharts into an authenticated, database-backed workflow. It deliberately removes the previous demo actor selector and simulated stage advancement.

## Production architecture
- Streamlit: UI only.
- Supabase Auth: identity and session.
- `profiles.role`: role routing.
- PostgreSQL/RLS: project/task visibility.
- SECURITY DEFINER RPCs: atomic state transitions and business rules.
- Supabase Storage: controlled document files (the Designer module calls the revision RPC with a storage path).
- `workflow_tasks`: role-to-role handover.
- `workflow_events`: immutable workflow history.
- `notifications`: in-app workflow notifications.
- `resource_authorizations`, `resource_competencies`, `resource_availability_calendar`: allocation eligibility.

## GM capabilities
1. Create and activate a project atomically.
2. Generate project milestones.
3. Assign DM / Engineer / Surveyor team members.
4. View active project portfolio.
5. Forward Plan Appraisal drawings to DM.
6. Review final Plan Appraisal submissions and approve / return to Designer.
7. Forward Survey RFIs to DM.
8. Review DM survey reports and observations.
9. Approve or return survey work.
10. Issue full or interim certificates under observation gating.
11. Review escalations from DM.
12. Read and acknowledge workflow notifications.

## DM capabilities
1. Receive authenticated work items in DM Inbox.
2. Review Plan Appraisal drawing revisions.
3. Check engineer authorization, competency, availability and workload.
4. Assign a specific eligible engineer.
5. Review engineer appraisal and return for changes / reject-amend / approve.
6. Forward approved appraisal to GM.
7. Receive revised Designer versions back into DM first.
8. Review Survey RFI scope and type.
9. Check surveyor specialization, authorization, competency and availability.
10. Assign a specific eligible surveyor and schedule the survey.
11. Review survey report and observations.
12. Forward survey package to GM.
13. Receive GM send-back as a controlled corrective-action task.
14. Assign corrective action to Surveyor / Ship Management.
15. Verify corrective evidence and create a follow-up RFI.
16. Monitor milestones and open workload.
17. Escalate delay / issue to GM with documented recommendation and severity.

## No-demo rule
The production entry point never imports the demo seed store, never selects an actor, and never calls `dev_advance_stage()`. A missing Supabase configuration is an error, not a fallback.

## Supabase deployment order
1. Execute `database/schema.sql` on a new Supabase project.
2. Execute `database/upgrade_schema.sql`.
3. Execute `database/production_schema.sql`.
4. Create Auth users in Supabase Auth.
5. Insert matching `profiles` rows with roles.
6. Insert authorization, competency and availability records for Engineers and Surveyors.
7. Create the private Storage bucket `project-documents`.
8. Apply Storage RLS so project members can only access authorized project paths.
9. Configure `.streamlit/secrets.toml` with `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
10. Run `streamlit run app.py`.

## Important production rule
Do not expose a role selector. Role comes only from the authenticated `profiles` record and is enforced again in PostgreSQL RPCs/RLS.

## Stakeholder email notifications
The application generates in-app notifications immediately. For stakeholder email, `notification_outbox` stores a durable queue. Run `services/email_worker.py` as a separate worker/cron with the Supabase **service-role key** and SMTP credentials. Never put the service-role key in Streamlit secrets.
