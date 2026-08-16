# EPAS v2.4 — Role Flow Audit

## GM

Project scope → phase gates → RFI intake → DM/resource governance → technical/survey decision → certificate decision package → closure/governance.

**Audit:** phase orchestration, certificate basis and recurring survey visibility are now explicit.

## DM

RFI intake → scope review → resource eligibility → Surveyor assignment → relevant approved drawing handover → survey/report review → corrective-action verification → follow-up → GM.

**Audit:** exact drawing package and controlled scope amendment are now explicit.

## Engineer

Assigned drawing → controlled drawing/revision → appraisal → marked-up drawing/report → technical decision → optional Surveyor verification → DM.

**Audit:** v2.1 items remain integrated.

## Surveyor

Assigned survey → NSC/In-Service branch → pre-survey checklist → immutable approved drawing package → execution → report → observations → verification/follow-up.

**Audit:** package revision/hash is now frozen.

## Shipyard

Shipyard membership → NSC RFI → GM intake → survey cycle tracking → controlled/released outputs.

**Constraint:** no In-Service RFI creation.

## Owner

Owner membership → In-Service RFI → GM/DM processing → survey status → certificate / next survey schedule.

**Constraint:** no NSC RFI creation.

## Ship Management

In-Service RFI → survey coordination; corrective-action assignment → evidence → DM verification.

**Constraint:** no NSC RFI creation.

## Designer

Drawing submission → DM/Engineer appraisal → correction request → revision lineage → approval/release.

## Cross-role information boundary

External stakeholders do not receive internal appraisal, resource, audit or unreleased document data. Surveyors receive only the drawing revisions explicitly handed over to their assigned survey.

## Remaining operational acceptance

The architecture is complete for the identified gaps, but production acceptance still requires live Supabase/RLS/Storage testing and browser execution with separate role accounts.
