# EPAS v2.7 Role Flow Audit

This audit maps the Streamlit role surface and database workflow to the supplied role diagrams.

| Role | Primary initiation / work | Core controlled transitions | External data boundary |
|---|---|---|---|
| GM | Project setup, intake, plan/RFI decision, certificate and closure governance | Project → Plan/Survey gates → GM decisions → certificate | Internal project governance plus controlled releases |
| Department Manager | Resource assignment, technical/Survey scope control, drawing handover, verification | Eligible resource → assignment → package → verification → certificate acknowledgement | Internal project operations |
| Engineer | Plan appraisal, marked-up drawing, appraisal report, technical decision | Assigned task → review → decision → optional Surveyor verification | Internal technical review only |
| Surveyor | Assignment acceptance, scope/package acknowledgement, checklist, survey, declaration/report | Accept → acknowledge → checklist → freeze basis → execute → report | Assigned survey/package only |
| Designer | Drawing submission and correction/revision cycle | Submit → review → correction → revision | Own submissions + released outcomes |
| Shipyard | NSC RFI initiation only | NSC RFI → GM/DM → Surveyor → NSC | No In-Service authority |
| Owner | In-Service cycle initiation and vessel status/forecast | Due cycle → guided In-Service RFI → survey → certificate | No NSC initiation; no internal appraisal |
| Ship Management | In-Service cycle initiation + corrective action execution | Due cycle → RFI → corrective action → evidence → verification | No NSC initiation; assigned corrective-action scope |

## Persistent In-Service rule

A completed In-Service survey cycle does not complete the project In-Service phase. The phase remains `ACTIVE/IN_PROGRESS`; `survey_schedules.cycle_number` advances and the next due window becomes actionable.

## Handover rule

Only Plan Appraisal approved drawings selected by DM are included in the Surveyor package. The handover freezes revision/file/hash metadata and Surveyor acknowledgement is bound to a package fingerprint.
