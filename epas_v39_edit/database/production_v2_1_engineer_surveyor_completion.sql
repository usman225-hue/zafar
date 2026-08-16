-- EPAS v2.1 — Engineer + Surveyor Workflow Completion
-- Applies after production_v2_0_professional_completion.sql
-- Closes audit residuals 1–4:
-- 1) Marked-up drawing + appraisal report artifacts
-- 2) Explicit Engineer decision taxonomy
-- 3) Explicit Engineer -> Surveyor verification branch
-- 4) First-class NSC / In-Service branch in Surveyor workspace and workflow

begin;
create extension if not exists pgcrypto;

-- ================================================================
-- 1. Controlled Engineer appraisal artifacts
-- ================================================================
create table if not exists plan_appraisal_artifacts (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  drawing_id uuid not null references plan_drawings(id) on delete cascade,
  revision_id uuid references plan_revisions(id) on delete set null,
  task_id uuid references workflow_tasks(id) on delete set null,
  artifact_type text not null check (artifact_type in ('MARKED_UP_DRAWING','APPRAISAL_REPORT')),
  file_name text not null,
  storage_path text not null unique,
  sha256 text not null,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes > 0),
  uploaded_by uuid not null references profiles(id),
  uploaded_at timestamptz not null default now(),
  status text not null default 'submitted' check (status in ('submitted','accepted','superseded','rejected')),
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists idx_plan_appraisal_artifacts_drawing on plan_appraisal_artifacts(drawing_id,artifact_type,uploaded_at desc);
create index if not exists idx_plan_appraisal_artifacts_project on plan_appraisal_artifacts(project_id,uploaded_at desc);

alter table plan_drawings add column if not exists engineer_decision text;
alter table plan_drawings add column if not exists engineer_decision_note text;
alter table plan_drawings add column if not exists engineer_decision_at timestamptz;
alter table plan_drawings add column if not exists engineer_needs_surveyor_verification boolean not null default false;
alter table plan_drawings add column if not exists surveyor_verification_status text;
alter table plan_drawings add column if not exists surveyor_verification_by uuid references profiles(id);
alter table plan_drawings add column if not exists surveyor_verification_at timestamptz;
alter table plan_drawings add column if not exists surveyor_verification_note text;

-- ================================================================
-- 2. Explicit decision vocabulary
-- ================================================================
drop function if exists epas_engineer_submit_review_v21(uuid,text,text,jsonb,boolean);
create or replace function epas_engineer_submit_review_v21(
  p_drawing_id uuid,
  p_decision text,
  p_note text,
  p_observations jsonb default '[]'::jsonb,
  p_needs_surveyor_verification boolean default false
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare
  v plan_drawings;
  v_item jsonb;
  v_old text;
  v_obs_code text;
  v_surveyor uuid;
  v_task workflow_tasks;
  v_project_vessel uuid;
begin
  if not epas_has_role('engineer') then raise exception 'Only Engineer may submit technical appraisal'; end if;
  if p_decision not in ('APPROVED','APPROVED_AS_AMENDED','INFORMATION','REJECTED') then
    raise exception 'Invalid Engineer decision. Use APPROVED, APPROVED_AS_AMENDED, INFORMATION, or REJECTED';
  end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Engineer technical conclusion is required'; end if;
  select * into v from plan_drawings where id=p_drawing_id for update;
  if v.id is null then raise exception 'Plan drawing not found'; end if;
  if v.engineer_id<>auth.uid() then raise exception 'Drawing is assigned to another Engineer'; end if;
  if v.status not in ('assigned_engineer','under_engineer_review','review_resubmitted','surveyor_verification_pending') then
    raise exception 'Drawing is not in an Engineer review state';
  end if;

  v_old:=v.status;

  if p_decision='APPROVED' and jsonb_array_length(coalesce(p_observations,'[]'::jsonb))>0 then
    raise exception 'APPROVED cannot contain observations; use APPROVED_AS_AMENDED or REJECTED';
  end if;
  if p_decision='APPROVED_AS_AMENDED' and jsonb_array_length(coalesce(p_observations,'[]'::jsonb))=0 then
    raise exception 'APPROVED_AS_AMENDED requires at least one amendment/observation';
  end if;
  if p_decision='REJECTED' and p_needs_surveyor_verification then
    raise exception 'Rejected technical conclusion cannot request surveyor verification';
  end if;

  if jsonb_array_length(coalesce(p_observations,'[]'::jsonb))>0 then
    for v_item in select * from jsonb_array_elements(p_observations) loop
      if coalesce(trim(v_item->>'description'),'')='' then raise exception 'Every observation requires a description'; end if;
      v_obs_code:=coalesce(nullif(trim(v_item->>'obs_code'),''),'PA-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(gen_random_uuid()::text,1,6)));
      insert into plan_appraisal_observations(obs_code,drawing_id,description,severity,status,raised_by,clause_reference,drawing_reference,reviewer_note)
      values(v_obs_code,v.id,v_item->>'description',coalesce(v_item->>'severity','Minor'),'open',auth.uid(),v_item->>'clause_reference',v_item->>'drawing_reference',p_note);
    end loop;
  end if;

  -- Pick an eligible Surveyor only when the Engineer explicitly requests verification.
  if p_needs_surveyor_verification then
    select pm.user_id into v_surveyor
    from project_members pm
    join profiles p on p.id=pm.user_id
    where pm.project_id=v.project_id and pm.active and pm.role='surveyor'
      and exists(select 1 from resource_authorizations ra where ra.user_id=pm.user_id and ra.role='surveyor' and ra.status='active')
      and exists(select 1 from resource_availability_calendar av where av.user_id=pm.user_id and av.work_date=current_date and av.status in ('available','partial'))
    order by coalesce((select avg(av.workload_pct) from resource_availability_calendar av where av.user_id=pm.user_id and av.work_date>=current_date-7 and av.work_date<=current_date+7),0),p.full_name
    limit 1;
    if v_surveyor is null then
      select pm.user_id into v_surveyor
      from project_members pm join profiles p on p.id=pm.user_id
      where pm.project_id=v.project_id and pm.active and pm.role='surveyor'
      order by p.full_name limit 1;
    end if;
    if v_surveyor is null then raise exception 'No Surveyor is available for verification'; end if;

    update plan_drawings set
      status='surveyor_verification_pending',
      engineer_decision=p_decision,
      engineer_decision_note=p_note,
      engineer_decision_at=now(),
      engineer_needs_surveyor_verification=true,
      surveyor_verification_status='pending',
      updated_at=now()
    where id=v.id returning * into v;

    perform epas_create_task(v.project_id,'PLAN_APPRAISAL_SURVEYOR_VERIFICATION',v_surveyor,
      'Engineer requested Surveyor verification for plan appraisal drawing '||v.drawing_no||'. Verify the specified technical point(s) and return a controlled verification result.',
      'plan_drawing',v.id,null,'high');
  else
    update plan_drawings set
      status='manager_review',
      engineer_decision=p_decision,
      engineer_decision_note=p_note,
      engineer_decision_at=now(),
      engineer_needs_surveyor_verification=false,
      surveyor_verification_status=null,
      updated_at=now()
    where id=v.id returning * into v;
    perform epas_create_task(v.project_id,'PLAN_APPRAISAL_MANAGER_REVIEW',v.manager_id,
      'Engineer technical appraisal completed. Review the Engineer decision and controlled appraisal package.',
      'plan_drawing',v.id,null,'high');
  end if;

  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where entity_type='plan_drawing' and entity_id=v.id and to_user_id=auth.uid()
    and task_type in ('PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK')
    and status in ('pending','accepted','in_progress');

  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v.project_id,'plan_drawing',v.id,'ENGINEER_DECISION_SUBMITTED',v_old,v.status,auth.uid(),p_note);
  perform epas_audit(v.project_id,'ENGINEER_DECISION_SUBMITTED','plan_drawing',v.id,v_old,v.status,p_note,
    jsonb_build_object('decision',p_decision,'needs_surveyor_verification',p_needs_surveyor_verification));
  return v;
end;$$;
grant execute on function epas_engineer_submit_review_v21(uuid,text,text,jsonb,boolean) to authenticated;

-- ================================================================
-- 3. Controlled Engineer artifact upload registration
-- ================================================================
create or replace function epas_engineer_register_appraisal_artifact(
  p_drawing_id uuid,
  p_artifact_type text,
  p_file_name text,
  p_storage_path text,
  p_sha256 text,
  p_mime_type text,
  p_size_bytes bigint
) returns plan_appraisal_artifacts
language plpgsql security definer set search_path=public as $$
declare
  v_d plan_drawings;
  v_task uuid;
  v_rev uuid;
  v plan_appraisal_artifacts;
  v_expected text;
begin
  if not epas_has_role('engineer') then raise exception 'Only Engineer may register appraisal artifacts'; end if;
  if p_artifact_type not in ('MARKED_UP_DRAWING','APPRAISAL_REPORT') then raise exception 'Invalid appraisal artifact type'; end if;
  if p_mime_type <> 'application/pdf' then raise exception 'Controlled appraisal artifacts must be PDF'; end if;
  if p_size_bytes is null or p_size_bytes<=0 or p_size_bytes>52428800 then raise exception 'Artifact must be between 1 byte and 50 MB'; end if;
  if coalesce(length(p_sha256),0)<>64 then raise exception 'SHA-256 is required'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id;
  if v_d.id is null then raise exception 'Plan drawing not found'; end if;
  if v_d.engineer_id<>auth.uid() then raise exception 'Drawing is assigned to another Engineer'; end if;
  if v_d.status not in ('assigned_engineer','under_engineer_review','review_resubmitted','surveyor_verification_pending','manager_review') then
    raise exception 'Drawing is not in an Engineer appraisal state';
  end if;
  v_expected:='projects/'||v_d.project_id::text||'/plan-appraisal/engineer-artifacts/'||v_d.id::text||'/'||p_artifact_type||'/'||p_file_name;
  if p_storage_path<>v_expected then raise exception 'Invalid controlled artifact storage path'; end if;
  select id into v_task from workflow_tasks where entity_type='plan_drawing' and entity_id=v_d.id and to_user_id=auth.uid()
    and task_type in ('PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK') and status in ('pending','accepted','in_progress')
    order by created_at desc limit 1;
  select id into v_rev from plan_revisions where drawing_id=v_d.id and revision_no=v_d.current_revision;
  insert into plan_appraisal_artifacts(project_id,drawing_id,revision_id,task_id,artifact_type,file_name,storage_path,sha256,mime_type,size_bytes,uploaded_by,metadata)
  values(v_d.project_id,v_d.id,v_rev,v_task,p_artifact_type,p_file_name,p_storage_path,p_sha256,p_mime_type,p_size_bytes,auth.uid(),jsonb_build_object('drawing_no',v_d.drawing_no,'revision',v_d.current_revision))
  returning * into v;
  perform epas_audit(v_d.project_id,'ENGINEER_APPRAISAL_ARTIFACT_REGISTERED','plan_appraisal_artifact',v.id,null,'submitted',p_file_name,
    jsonb_build_object('artifact_type',p_artifact_type,'sha256',p_sha256,'size_bytes',p_size_bytes));
  return v;
end;$$;
grant execute on function epas_engineer_register_appraisal_artifact(uuid,text,text,text,text,text,bigint) to authenticated;

-- ================================================================
-- 4. Surveyor verification branch
-- ================================================================
create or replace function epas_surveyor_verify_plan_appraisal(
  p_drawing_id uuid,
  p_result text,
  p_note text
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare
  v plan_drawings;
  v_task workflow_tasks;
  v_old text;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may perform plan appraisal verification'; end if;
  if p_result not in ('VERIFIED','NOT_VERIFIED') then raise exception 'Verification result must be VERIFIED or NOT_VERIFIED'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Surveyor verification note is required'; end if;
  select * into v from plan_drawings where id=p_drawing_id for update;
  if v.id is null then raise exception 'Plan drawing not found'; end if;
  if v.surveyor_verification_status<>'pending' then raise exception 'No pending Surveyor verification exists'; end if;
  select * into v_task from workflow_tasks where entity_type='plan_drawing' and entity_id=v.id and task_type='PLAN_APPRAISAL_SURVEYOR_VERIFICATION'
    and to_user_id=auth.uid() and status in ('pending','accepted','in_progress') order by created_at desc limit 1;
  if v_task.id is null then raise exception 'Verification task is not assigned to this Surveyor'; end if;
  v_old:=v.status;
  if p_result='VERIFIED' then
    update plan_drawings set status='manager_review',surveyor_verification_status='verified',surveyor_verification_by=auth.uid(),surveyor_verification_at=now(),surveyor_verification_note=p_note,updated_at=now() where id=v.id returning * into v;
    perform epas_create_task(v.project_id,'PLAN_APPRAISAL_MANAGER_REVIEW',v.manager_id,'Engineer appraisal and Surveyor verification completed. Review the controlled package.','plan_drawing',v.id,null,'high');
  else
    update plan_drawings set status='under_engineer_review',surveyor_verification_status='not_verified',surveyor_verification_by=auth.uid(),surveyor_verification_at=now(),surveyor_verification_note=p_note,updated_at=now() where id=v.id returning * into v;
    perform epas_create_task(v.project_id,'PLAN_APPRAISAL_ENGINEER_FEEDBACK',v.engineer_id,'Surveyor verification was not confirmed. Review the Surveyor note and resubmit the appraisal.','plan_drawing',v.id,null,'high');
  end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note where id=v_task.id;
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v.project_id,'plan_drawing',v.id,'SURVEYOR_PLAN_VERIFICATION',v_old,v.status,auth.uid(),p_note);
  perform epas_audit(v.project_id,'SURVEYOR_PLAN_VERIFICATION','plan_drawing',v.id,v_old,v.status,p_note,jsonb_build_object('result',p_result));
  return v;
end;$$;
grant execute on function epas_surveyor_verify_plan_appraisal(uuid,text,text) to authenticated;

-- ================================================================
-- First-class Surveyor branch/read model
-- ================================================================
create or replace function epas_surveyor_plan_verification_queue()
returns table(task_id uuid,drawing_id uuid,project_id uuid,drawing_no text,title text,revision integer,engineer_decision text,decision_note text,verification_status text,note text,due_at timestamptz)
language sql security definer set search_path=public stable as $$
  select t.id,d.id,d.project_id,d.drawing_no,d.title,d.current_revision,d.engineer_decision,d.engineer_decision_note,d.surveyor_verification_status,t.note,t.due_at
  from workflow_tasks t join plan_drawings d on d.id=t.entity_id
  where epas_has_role('surveyor') and t.to_user_id=auth.uid() and t.task_type='PLAN_APPRAISAL_SURVEYOR_VERIFICATION'
    and t.status in ('pending','accepted','in_progress')
  order by coalesce(t.sla_due_at,t.due_at) nulls last,t.created_at;
$$;
grant execute on function epas_surveyor_plan_verification_queue() to authenticated;

-- Artifact RLS: internal appraisal artifacts are visible only to project members
alter table plan_appraisal_artifacts enable row level security;
drop policy if exists plan_appraisal_artifacts_select_v21 on plan_appraisal_artifacts;
create policy plan_appraisal_artifacts_select_v21 on plan_appraisal_artifacts for select to authenticated
using (exists(select 1 from project_members pm join profiles pr on pr.id=pm.user_id where pm.project_id=plan_appraisal_artifacts.project_id and pm.user_id=auth.uid() and pm.active and pr.role in ('gm','dm','engineer','surveyor')));
revoke insert,update,delete on plan_appraisal_artifacts from anon,authenticated;

commit;
