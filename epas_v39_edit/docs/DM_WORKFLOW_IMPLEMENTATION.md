# Department Manager Workflow Implementation

This module maps the supplied DM flowchart to the application.

| Flowchart node | Application implementation |
|---|---|
| DM Dashboard / Inbox | `components/dm_dashboard.py` |
| New Work Item | `database/upgrade_queries.py::list_tasks_for_user` |
| GM forwards Plan Appraisal drawing | `assign_plan_manager()` + `PLAN_APPRAISAL_MANAGER_HANDOVER` |
| DM receives new version | DM Dashboard Plan Appraisal tab |
| Check Engineer availability & workload | `eligible_engineers()` / `engineer_eligibility()` |
| Assign Authorized Engineer | `assign_engineer()` |
| Engineer works appraisal | `components/workflow_inbox.py` |
| DM reviews appraisal | `manager_review_decision()` |
| Appraisal Requires Changes | `manager_return_to_engineer()` |
| Design Rejected / Amended | `manager_review_decision()` → GM designer-correction task |
| GM sends to Designer | `gm_send_to_designer()` |
| Designer resubmits | Workflow Inbox + revision control |
| Survey RFI handover | `handover_rfi_to_dm()` |
| DM reviews RFI scope & type | DM Dashboard Survey RFIs tab |
| Surveyor availability & specialization | `eligible_surveyors()` / `surveyor_eligibility()` |
| Assign Authorized Surveyor | `assign_surveyor()` |
| Surveyor conducts/submits | `components/surveyor_dashboard.py` |
| DM reviews report & observations | `SURVEY_DM_REVIEW` task |
| Forward to GM | `dm_review_and_forward_survey()` |
| GM send back | GM RFI Queue + `route_gm_return_to_dm()` |
| Corrective action | `SURVEY_CORRECTIVE_ACTION` task |
| Follow-up RFI | `create_followup_rfi()` |
| Monitor workload / delays | DM Dashboard monitoring section |

## Important production conversion

The current demo actor selectors are only for end-to-end testing. In production they must be replaced by Supabase Auth identities and server-side RLS. The state transitions and task handovers are already separated from the actor selector so that conversion can be made without redesigning the workflow UI.
