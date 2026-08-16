# EPAS v2.6 Role Acceptance Matrix

| Role | Must be able to do | Must not be able to do |
|---|---|---|
| GM | Govern project, approve plan/survey, freeze certificate package, issue certificate, run manual schedule control | Bypass audit/package gates |
| DM | Allocate eligible Engineer/Surveyor, select drawings, decide revision impact, verify corrective action, acknowledge certificate package | Assign ineligible Surveyor or close observations outside controlled verification |
| Engineer | Accept task, appraise drawing, upload marked-up drawing/report, decide technical result, request Surveyor verification | Approve as GM/DM or issue certificates |
| Surveyor | Accept assignment, acknowledge scope/package, complete checklist, start survey, declare and submit report, perform assigned verification | Browse all project drawings or act on another Surveyor's assignment |
| Designer | Submit/revise drawings and track revision status | View confidential internal appraisal notes |
| Shipyard | Initiate and track NSC RFI, receive released information | Create In-Service RFI or view internal In-Service records |
| Owner | Initiate scheduled/unscheduled In-Service RFI, track vessel/certificate/survey status | Create NSC RFI or view internal appraisal notes |
| Ship Management | Initiate In-Service RFI, execute assigned corrective actions, submit exact evidence | Create NSC RFI or access unrelated corrective actions |

The database records the static acceptance cases in `workflow_acceptance_cases_v26`.
