-- EPAS Production v1.4 - Critical Workflow & Security Hardening
-- Apply AFTER database/production_schema.sql.

create extension if not exists pgcrypto;

-- ================================================================
-- 1) Governance tables / audit / risk / decisions / SLA metadata
-- ================================================================
alter table workflow_tasks add column if not exists started_at timestamptz;
alter table workflow_tasks add column if not exists sla_minutes integer;
alter table workflow_tasks add column if not exists last_reminder_at timestamptz;
alter table workflow_tasks add column if not exists overdue_at timestamptz;

alter table audit_log add column if not exists entity_type text;
alter table audit_log add column if not exists entity_id uuid;
alter table audit_log add column if not exists from_status text;
alter table audit_log add column if not exists to_status text;
alter table audit_log add column if not exists reason text;
alter table audit_log add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table workflow_escalations add column if not exists acknowledged_at timestamptz;
alter table workflow_escalations add column if not exists acknowledged_by uuid references profiles(id);
alter table workflow_escalations add column if not exists decision text;
alter table workflow_escalations add column if not exists decision_by uuid references profiles(id);
alter table workflow_escalations add column if not exists decision_at timestamptz;

create table if not exists project_risks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  risk_code text not null,
  title text not null,
  description text not null,
  probability text not null check (probability in ('low','medium','high')),
  impact text not null check (impact in ('low','medium','high')),
  severity text not null check (severity in ('low','medium','high','critical')),
  owner_id uuid references profiles(id),
  mitigation text,
  target_date date,
  status text not null default 'open' check (status in ('open','mitigated','accepted','closed')),
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id,risk_code)
);
create index if not exists idx_project_risks_project_status on project_risks(project_id,status);

create table if not exists project_decisions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  decision_code text not null,
  subject text not null,
  decision text not null,
  reason text,
  decision_by uuid not null references profiles(id),
  decision_at timestamptz not null default now(),
  entity_type text,
  entity_id uuid,
  unique(project_id,decision_code)
);
create index if not exists idx_project_decisions_project on project_decisions(project_id,decision_at desc);

-- ================================================================
-- 2) Secure audit helper. Captures actor/role/time/entity/state/reason and
-- selected request metadata when the Supabase request context exposes it.
-- ================================================================
create or replace function epas_audit(
  p_project_id uuid,
  p_action text,
  p_entity_type text default null,
  p_entity_id uuid default null,
  p_from_status text default null,
  p_to_status text default null,
  p_reason text default null,
  p_details jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path=public as $$
declare v_role text; v_meta jsonb := coalesce(p_details,'{}'::jsonb);
begin
  select role into v_role from profiles where id=auth.uid();
  begin
    v_meta := v_meta || jsonb_build_object(
      'user_agent', current_setting('request.headers', true)::jsonb ->> 'user-agent',
      'x_forwarded_for', current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for',
      'request_id', current_setting('request.headers', true)::jsonb ->> 'x-request-id'
    );
  exception when others then null;
  end;
  insert into audit_log(project_id,actor_id,action,details,entity_type,entity_id,from_status,to_status,reason,metadata)
  values(p_project_id,auth.uid(),p_action,
         jsonb_build_object('role',v_role,'reason',p_reason) || coalesce(p_details,'{}'::jsonb),
         p_entity_type,p_entity_id,p_from_status,p_to_status,p_reason,v_meta);
end;$$;

-- ================================================================
-- 3) RPC-only mutation boundary for critical workflow tables.
-- Remove EVERY existing client write policy on the five target tables.
-- Keep read policies only. Direct writes are denied; SECURITY DEFINER RPCs
-- remain able to perform state transitions.
-- ================================================================
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='public'
      and tablename in ('workflow_tasks','plan_drawings','plan_appraisal_observations','document_revisions','notifications')
      and (cmd in ('INSERT','UPDATE','DELETE','ALL'))
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- Also explicitly revoke browser table mutation privileges. RPCs are the only
-- supported mutation path. SELECT remains available through RLS policies.
revoke insert, update, delete on workflow_tasks from anon, authenticated;
revoke insert, update, delete on plan_drawings from anon, authenticated;
revoke insert, update, delete on plan_appraisal_observations from anon, authenticated;
revoke insert, update, delete on document_revisions from anon, authenticated;
revoke insert, update, delete on notifications from anon, authenticated;

-- Remove direct notification update policy from the previous migration and
-- recreate only scoped SELECT.
drop policy if exists notifications_update_prod on notifications;
drop policy if exists notifications_select_prod on notifications;
drop policy if exists notifications_select_v14 on notifications;
create policy notifications_select_v14 on notifications for select to authenticated
  using (user_id=auth.uid());

-- Workflow task reads: recipient/sender plus GM and project DM.
drop policy if exists workflow_tasks_select_prod on workflow_tasks;
drop policy if exists workflow_tasks_select_v14 on workflow_tasks;
create policy workflow_tasks_select_v14 on workflow_tasks for select to authenticated using (
  to_user_id=auth.uid()
  or from_user_id=auth.uid()
  or epas_has_role('gm')
  or (epas_has_role('dm') and epas_is_project_member(project_id))
);

-- Plan drawing/revision/observation reads remain project scoped.
drop policy if exists plan_drawings_select_prod on plan_drawings;
drop policy if exists plan_drawings_select_v14 on plan_drawings;
create policy plan_drawings_select_v14 on plan_drawings for select to authenticated
  using (epas_is_project_member(project_id) or manager_id=auth.uid() or engineer_id=auth.uid() or designer_id=auth.uid());

drop policy if exists plan_obs_select_prod on plan_appraisal_observations;
drop policy if exists plan_obs_select_v14 on plan_appraisal_observations;
create policy plan_obs_select_v14 on plan_appraisal_observations for select to authenticated
  using (exists(select 1 from plan_drawings d where d.id=plan_appraisal_observations.drawing_id and
               (epas_is_project_member(d.project_id) or d.engineer_id=auth.uid() or d.designer_id=auth.uid())));

drop policy if exists plan_revisions_select on plan_revisions;
drop policy if exists plan_revisions_select_v14 on plan_revisions;
create policy plan_revisions_select_v14 on plan_revisions for select to authenticated
  using (exists(select 1 from plan_drawings d where d.id=plan_revisions.drawing_id and
               (epas_is_project_member(d.project_id) or d.engineer_id=auth.uid() or d.designer_id=auth.uid())));

-- Document revisions read policy remains scoped; no INSERT/UPDATE/DELETE policy.
drop policy if exists revisions_project_users on document_revisions;
drop policy if exists revisions_select_v14 on document_revisions;
create policy revisions_select_v14 on document_revisions for select to authenticated
  using (exists(select 1 from documents d where d.id=document_revisions.document_id and epas_is_project_member(d.project_id)));

-- ================================================================
-- 4) Notification mutation RPCs
-- ================================================================
create or replace function epas_mark_notification_read(p_notification_id uuid)
returns notifications
language plpgsql security definer set search_path=public as $$
declare v notifications;
begin
  update notifications set read_at=coalesce(read_at,now())
  where id=p_notification_id and user_id=auth.uid()
  returning * into v;
  if v.id is null then raise exception 'Notification not found or not owned by current user'; end if;
  perform epas_audit(v.project_id,'NOTIFICATION_READ','notification',v.id,null,null,null,'{}'::jsonb);
  return v;
end;$$;

create or replace function epas_mark_all_notifications_read()
returns integer
language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  update notifications set read_at=now() where user_id=auth.uid() and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;$$;

-- ================================================================
-- 5) Secure task state transitions with audit + SLA handling
-- ================================================================
create or replace function epas_accept_task(p_task_id uuid)
returns workflow_tasks
language plpgsql security definer set search_path=public as $$
declare v workflow_tasks;
begin
  update workflow_tasks set status='accepted',accepted_at=now(),last_reminder_at=null
  where id=p_task_id and to_user_id=auth.uid() and status='pending'
  returning * into v;
  if v.id is null then raise exception 'Task is not pending or is assigned to another user'; end if;
  perform epas_audit(v.project_id,'TASK_ACCEPTED','workflow_task',v.id,'pending','accepted',v.note,jsonb_build_object('task_type',v.task_type));
  return v;
end;$$;

create or replace function epas_start_task(p_task_id uuid)
returns workflow_tasks
language plpgsql security definer set search_path=public as $$
declare v workflow_tasks; v_old text;
begin
  select status into v_old from workflow_tasks where id=p_task_id and to_user_id=auth.uid();
  update workflow_tasks set status='in_progress',started_at=coalesce(started_at,now())
  where id=p_task_id and to_user_id=auth.uid() and status in ('pending','accepted')
  returning * into v;
  if v.id is null then raise exception 'Task cannot be started'; end if;
  perform epas_audit(v.project_id,'TASK_STARTED','workflow_task',v.id,v_old,'in_progress',v.note,jsonb_build_object('task_type',v.task_type));
  return v;
end;$$;

create or replace function epas_complete_task(p_task_id uuid,p_note text default '')
returns workflow_tasks
language plpgsql security definer set search_path=public as $$
declare v workflow_tasks; v_old text;
begin
  select status into v_old from workflow_tasks where id=p_task_id and to_user_id=auth.uid();
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where id=p_task_id and to_user_id=auth.uid() and status in ('accepted','in_progress')
  returning * into v;
  if v.id is null then raise exception 'Task cannot be completed'; end if;
  perform epas_audit(v.project_id,'TASK_COMPLETED','workflow_task',v.id,v_old,'completed',p_note,jsonb_build_object('task_type',v.task_type));
  return v;
end;$$;

-- ================================================================
-- 6) Restrict generic task creator to internal server-side use.
-- It remains callable by existing SECURITY DEFINER workflow functions but is
-- not directly executable by authenticated browser clients.
-- ================================================================
revoke execute on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) from public,authenticated;

-- ================================================================
-- 7) GM rejected/amended decision -> Designer / DM correction loop
-- ================================================================
create or replace function epas_gm_amended_design_decision(
  p_drawing_id uuid,
  p_decision text,
  p_note text
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare v plan_drawings; v_des uuid; v_dm uuid; v_old text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may decide an amended/rejected design'; end if;
  if p_decision not in ('send_to_designer','return_to_dm') then raise exception 'Decision must be send_to_designer or return_to_dm'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'GM decision note is required'; end if;
  select * into v from plan_drawings where id=p_drawing_id for update;
  if v.status <> 'rejected' then raise exception 'Drawing is not awaiting GM amended-design decision'; end if;
  v_old := v.status;
  select designer_id, manager_id into v_des,v_dm from plan_drawings where id=p_drawing_id;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid()
    and task_type='PLAN_APPRAISAL_GM_DESIGN_DECISION' and status in ('pending','accepted','in_progress');
  if p_decision='send_to_designer' then
    if v_des is null then raise exception 'Drawing has no Designer account linked'; end if;
    update plan_drawings set status='designer_response',updated_at=now() where id=p_drawing_id returning * into v;
    perform epas_create_task(v.project_id,'PLAN_APPRAISAL_DESIGNER_RESPONSE',v_des,p_note,'plan_drawing',v.id,null,'high');
  else
    if v_dm is null then raise exception 'Drawing has no Department Manager'; end if;
    update plan_drawings set status='manager_review',updated_at=now() where id=p_drawing_id returning * into v;
    perform epas_create_task(v.project_id,'PLAN_APPRAISAL_MANAGER_REVIEW',v_dm,p_note,'plan_drawing',v.id,null,'high');
  end if;
  insert into project_decisions(project_id,decision_code,subject,decision,reason,decision_by,entity_type,entity_id)
  values(v.project_id,'PA-GM-'||substr(v.id::text,1,8)||'-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISS'),'GM Plan Appraisal Decision',p_decision,p_note,auth.uid(),'plan_drawing',v.id);
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v.project_id,'plan_drawing',v.id,'GM_AMENDED_DESIGN_DECISION',v_old,v.status,auth.uid(),p_note);
  perform epas_audit(v.project_id,'GM_AMENDED_DESIGN_DECISION','plan_drawing',v.id,v_old,v.status,p_note,jsonb_build_object('decision',p_decision));
  return v;
end;$$;

-- ================================================================
-- 8) Engineer execution: real observation register + decision package
-- ================================================================
create or replace function epas_engineer_submit_review(
  p_drawing_id uuid,
  p_decision text,
  p_note text,
  p_observations jsonb default '[]'::jsonb
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare v plan_drawings; v_item jsonb; v_count integer; v_obs_code text; v_old text;
begin
  if not epas_has_role('engineer') then raise exception 'Only Engineer may submit technical appraisal'; end if;
  select * into v from plan_drawings where id=p_drawing_id for update;
  if v.engineer_id <> auth.uid() then raise exception 'Drawing is assigned to another engineer'; end if;
  if p_decision not in ('accepted','observation') then raise exception 'Invalid engineer decision'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Engineer technical conclusion is required'; end if;
  v_old := v.status;
  if p_decision='observation' then
    if jsonb_array_length(coalesce(p_observations,'[]'::jsonb)) = 0 then raise exception 'At least one observation is required when the decision is Observation'; end if;
    for v_item in select * from jsonb_array_elements(p_observations) loop
      if coalesce(trim(v_item->>'description'),'')='' then raise exception 'Every observation requires a description'; end if;
      v_obs_code := coalesce(nullif(trim(v_item->>'obs_code'),''),'PA-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(gen_random_uuid()::text,1,6)));
      insert into plan_appraisal_observations(obs_code,drawing_id,description,severity,status,raised_by,clause_reference,drawing_reference,reviewer_note)
      values(v_obs_code,v.id,v_item->>'description',coalesce(v_item->>'severity','Minor'),'open',auth.uid(),v_item->>'clause_reference',v_item->>'drawing_reference',p_note);
    end loop;
    update plan_drawings set status='observation_raised',updated_at=now() where id=v.id returning * into v;
  else
    select count(*) into v_count from plan_appraisal_observations where drawing_id=v.id and status='open';
    if v_count > 0 then raise exception 'Drawing has open observations; engineer cannot submit an Accepted conclusion until they are addressed'; end if;
    update plan_drawings set status='manager_review',updated_at=now(),last_manager_review_at=null where id=v.id returning * into v;
  end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where entity_type='plan_drawing' and entity_id=v.id and to_user_id=auth.uid()
    and task_type in ('PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK')
    and status in ('pending','accepted','in_progress');
  perform epas_create_task(v.project_id,'PLAN_APPRAISAL_MANAGER_REVIEW',v.manager_id,'Engineer technical appraisal completed. Review conclusion and observations.','plan_drawing',v.id,null,'high');
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v.project_id,'plan_drawing',v.id,'ENGINEER_SUBMITTED_REVIEW',v_old,v.status,auth.uid(),p_note);
  perform epas_audit(v.project_id,'ENGINEER_SUBMITTED_REVIEW','plan_drawing',v.id,v_old,v.status,p_note,jsonb_build_object('decision',p_decision));
  return v;
end;$$;

-- ================================================================
-- 9) Plan appraisal observation closure / response
-- ================================================================
create or replace function epas_respond_plan_observation(p_observation_id uuid,p_response text,p_evidence_path text default null)
returns plan_appraisal_observations
language plpgsql security definer set search_path=public as $$
declare v plan_appraisal_observations; v_d plan_drawings;
begin
  select o.* into v from plan_appraisal_observations o where o.id=p_observation_id for update;
  if v.id is null then raise exception 'Plan appraisal observation not found'; end if;
  select d.* into v_d from plan_drawings d where d.id=v.drawing_id;
  if not (v_d.designer_id=auth.uid() or v_d.engineer_id=auth.uid() or v_d.manager_id=auth.uid() or epas_has_role('gm')) then raise exception 'Not authorized for this observation'; end if;
  if coalesce(trim(p_response),'')='' then raise exception 'Observation response is required'; end if;
  update plan_appraisal_observations set response=p_response,responded_at=now(),response_evidence_path=p_evidence_path where id=v.id returning * into v;
  perform epas_audit(v_d.project_id,'PLAN_OBSERVATION_RESPONDED','plan_observation',v.id,v.status,v.status,p_response,jsonb_build_object('evidence_path',p_evidence_path));
  return v;
end;$$;

create or replace function epas_close_plan_observation(p_observation_id uuid,p_note text)
returns plan_appraisal_observations
language plpgsql security definer set search_path=public as $$
declare v plan_appraisal_observations; v_d plan_drawings; v_open int;
begin
  if not (epas_has_role('dm') or epas_has_role('gm')) then raise exception 'Only DM or GM may close a plan appraisal observation'; end if;
  select o.* into v from plan_appraisal_observations o where o.id=p_observation_id for update;
  select d.* into v_d from plan_drawings d where d.id=v.drawing_id;
  if v_d.manager_id<>auth.uid() and not epas_has_role('gm') then raise exception 'Observation belongs to another manager'; end if;
  if v.status <> 'open' then raise exception 'Observation is already closed'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Closure note is required'; end if;
  update plan_appraisal_observations set status='cleared',closed_by=auth.uid(),closed_at=now(),reviewer_note=p_note where id=v.id returning * into v;
  select count(*) into v_open from plan_appraisal_observations where drawing_id=v.drawing_id and status='open';
  perform epas_audit(v_d.project_id,'PLAN_OBSERVATION_CLOSED','plan_observation',v.id,'open','cleared',p_note,jsonb_build_object('remaining_open',v_open));
  return v;
end;$$;

-- ================================================================
-- 10) Survey observation lifecycle: respond / clear, not just create/open.
-- ================================================================
create or replace function epas_clear_survey_observation(p_observation_id uuid,p_note text)
returns observations
language plpgsql security definer set search_path=public as $$
declare v observations; v_rfi rfis;
begin
  if not (epas_has_role('dm') or epas_has_role('gm')) then raise exception 'Only DM or GM may clear survey observations'; end if;
  select o.* into v from observations o where o.id=p_observation_id for update;
  select r.* into v_rfi from rfis r where r.id=v.rfi_id;
  if not epas_is_project_member(v_rfi.project_id) then raise exception 'Not authorized for this RFI'; end if;
  if v.status <> 'open' then raise exception 'Observation is already cleared'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Closure note is required'; end if;
  update observations set status='cleared',cleared_at=now() where id=v.id returning * into v;
  perform epas_audit(v_rfi.project_id,'SURVEY_OBSERVATION_CLEARED','survey_observation',v.id,'open','cleared',p_note,'{}'::jsonb);
  return v;
end;$$;

-- ================================================================
-- 11) Designer revision control: controlled path + revision audit.
-- ================================================================
create or replace function epas_designer_submit_revision(p_drawing_id uuid,p_file_name text,p_storage_path text,p_note text)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v plan_drawings; v_rev int; v_old text; v_prefix text;
begin
  if not epas_has_role('designer') then raise exception 'Only Designer may submit revision'; end if;
  select * into v from plan_drawings where id=p_drawing_id for update;
  if v.designer_id <> auth.uid() then raise exception 'Drawing belongs to another designer'; end if;
  if coalesce(trim(p_file_name),'')='' or coalesce(trim(p_storage_path),'')='' then raise exception 'Revision file name and storage path are required'; end if;
  v_prefix := 'projects/'||v.project_id::text||'/plan-appraisal/'||v.id::text||'/';
  if p_storage_path <> v_prefix||p_file_name then raise exception 'Invalid controlled revision storage path'; end if;
  v_rev := v.current_revision + 1;
  v_old := v.status;
  insert into plan_revisions(drawing_id,revision_no,file_name,storage_path,submitted_by,submission_note,status)
  values(v.id,v_rev,p_file_name,p_storage_path,auth.uid(),p_note,'submitted');
  update plan_revisions set status='superseded' where drawing_id=v.id and revision_no < v_rev and status='submitted';
  update plan_drawings set current_revision=v_rev,revision=v_rev,status='submitted',updated_at=now(),current_file_name=p_file_name where id=v.id returning * into v;
  perform epas_create_task(v.project_id,'PLAN_APPRAISAL_REVISION_DM_REVIEW',v.manager_id,'Revision '||v_rev||' submitted by Designer. Review the new version before engineer reallocation.','plan_drawing',v.id,null,'high');
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v.project_id,'plan_drawing',v.id,'DESIGNER_REVISION_SUBMITTED',v_old,'submitted',auth.uid(),p_note);
  perform epas_audit(v.project_id,'DESIGNER_REVISION_SUBMITTED','plan_drawing',v.id,v_old,'submitted',p_note,jsonb_build_object('revision',v_rev,'storage_path',p_storage_path));
  return v;
end;$$;

-- ================================================================
-- 12) Controlled project document upload metadata. Storage upload occurs in
-- the client first, then this RPC is the only DB mutation for the metadata.
-- ================================================================
create or replace function epas_register_project_document(
  p_project_id uuid,p_category text,p_file_name text,p_storage_path text,p_version integer default 1
) returns documents
language plpgsql security definer set search_path=public as $$
declare v documents; v_prefix text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may register project governance documents'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  if p_category not in ('contract','class_rules','timeline','drawing') then raise exception 'Invalid document category'; end if;
  v_prefix := 'projects/'||p_project_id::text||'/documents/'||p_category||'/';
  if p_storage_path <> v_prefix||p_file_name then raise exception 'Invalid controlled document storage path'; end if;
  insert into documents(project_id,category,file_name,version,status,storage_path,uploaded_by)
  values(p_project_id,p_category,p_file_name,p_version,'pending_review',p_storage_path,auth.uid()) returning * into v;
  perform epas_audit(p_project_id,'DOCUMENT_REGISTERED','document',v.id,null,'pending_review',null,jsonb_build_object('category',p_category,'file_name',p_file_name,'storage_path',p_storage_path));
  return v;
end;$$;

-- ================================================================
-- 13) GM escalation decision
-- ================================================================
create or replace function epas_gm_escalation_decide(p_escalation_id uuid,p_decision text,p_note text)
returns workflow_escalations
language plpgsql security definer set search_path=public as $$
declare v workflow_escalations; v_old text; v_dm uuid;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may decide escalations'; end if;
  if p_decision not in ('acknowledge','return_to_dm','resolve','reject') then raise exception 'Invalid escalation decision'; end if;
  if p_decision in ('return_to_dm','resolve','reject') and coalesce(trim(p_note),'')='' then raise exception 'Decision note is required'; end if;
  select * into v from workflow_escalations where id=p_escalation_id for update;
  if v.assigned_to<>auth.uid() then raise exception 'Escalation is assigned to another GM'; end if;
  if v.status not in ('open','acknowledged') then raise exception 'Escalation is already closed'; end if;
  v_old := v.status;
  if p_decision='acknowledge' then
    update workflow_escalations set status='acknowledged',acknowledged_at=now(),acknowledged_by=auth.uid(),decision='acknowledge' where id=v.id returning * into v;
  elsif p_decision='resolve' then
    update workflow_escalations set status='resolved',resolved_at=now(),resolved_note=p_note,decision='resolve',decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
  elsif p_decision='reject' then
    update workflow_escalations set status='rejected',resolved_at=now(),resolved_note=p_note,decision='reject',decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
  else
    select assigned_dm_id into v_dm from rfis where id=v.entity_id and v.entity_type='rfi';
    if v_dm is null then select manager_id into v_dm from plan_drawings where id=v.entity_id and v.entity_type='plan_drawing'; end if;
    if v_dm is null then select user_id into v_dm from project_members where project_id=v.project_id and role='dm' and active order by assigned_at limit 1; end if;
    if v_dm is null then raise exception 'No Department Manager available for escalation return'; end if;
    update workflow_escalations set status='resolved',resolved_at=now(),resolved_note=p_note,decision='return_to_dm',decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
    perform epas_create_task(v.project_id,'GM_ESCALATION_RETURN',v_dm,p_note,v.entity_type,v.entity_id,null,'high');
  end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where entity_type=v.entity_type and entity_id=v.entity_id and to_user_id=auth.uid() and task_type='GM_ESCALATION_REVIEW' and status in ('pending','accepted','in_progress');
  perform epas_audit(v.project_id,'GM_ESCALATION_DECISION','escalation',v.id,v_old,v.status,p_note,jsonb_build_object('decision',p_decision));
  return v;
end;$$;

-- ================================================================
-- 14) Project health + DM resource workload/SLA functions
-- ================================================================
create or replace function epas_project_health(p_project_id uuid)
returns table(
  project_id uuid, total_milestones integer, completed_milestones integer, delayed_milestones integer,
  plan_drawings integer, approved_drawings integer, plan_open_observations integer,
  rfis integer, rfis_approved integer, survey_open_observations integer,
  open_tasks integer, overdue_tasks integer, open_escalations integer, open_risks integer,
  completion_pct numeric, health_status text
)
language sql security definer set search_path=public stable as $$
  with m as (
    select count(*) total, count(*) filter(where status='completed') completed, count(*) filter(where status='delayed' or (due_date<current_date and status not in ('completed','cancelled'))) delayed
    from project_milestones where project_id=p_project_id
  ),
  d as (
    select count(*) total, count(*) filter(where status='approved') approved from plan_drawings where project_id=p_project_id
  ),
  po as (
    select count(*) total from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id where d.project_id=p_project_id and o.status='open'
  ),
  r as (select count(*) total, count(*) filter(where status in ('approved_no_observations','approved_with_observations','certificate_issued','closed')) approved from rfis where project_id=p_project_id),
  so as (select count(*) total from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id and o.status='open'),
  t as (select count(*) filter(where status not in ('completed','returned')) open, count(*) filter(where status not in ('completed','returned') and due_at<now()) overdue from workflow_tasks where project_id=p_project_id),
  e as (select count(*) total from workflow_escalations where project_id=p_project_id and status in ('open','acknowledged')),
  k as (select count(*) total from project_risks where project_id=p_project_id and status='open')
  select p_project_id,m.total,m.completed,m.delayed,d.total,d.approved,po.total,r.total,r.approved,so.total,t.open,t.overdue,e.total,k.total,
    round((case when (m.total+r.total+d.total)=0 then 0 else 100.0*(m.completed+r.approved+d.approved)/(m.total+r.total+d.total) end)::numeric,1),
    case when t.overdue>0 or e.total>0 or k.total>0 then 'attention' when m.delayed>0 or so.total>0 or po.total>0 then 'watch' else 'healthy' end
  from m,d,po,r,so,t,e,k;
$$;

create or replace function epas_resource_workload(p_project_id uuid)
returns table(
  user_id uuid, full_name text, role text, discipline text, workload_pct numeric, capacity_pct numeric,
  assigned_tasks integer, overdue_tasks integer, due_7d integer, same_due_date_conflicts integer, availability_status text
)
language sql security definer set search_path=public stable as $$
  select pm.user_id,p.full_name,pm.role,pm.discipline,
    coalesce(av.workload_pct,0),100-coalesce(av.workload_pct,0),
    count(t.id) filter(where t.status not in ('completed','returned')),
    count(t.id) filter(where t.status not in ('completed','returned') and t.due_at<now()),
    count(t.id) filter(where t.status not in ('completed','returned') and t.due_at between now() and now()+interval '7 days'),
    count(t2.id) filter(where t2.status not in ('completed','returned') and t2.due_at::date=t.due_at::date and t2.id<>t.id),
    coalesce(av.status,'available')
  from project_members pm
  join profiles p on p.id=pm.user_id
  left join resource_availability_calendar av on av.user_id=pm.user_id and av.work_date=current_date
  left join workflow_tasks t on t.to_user_id=pm.user_id and t.project_id=p_project_id
  left join workflow_tasks t2 on t2.to_user_id=pm.user_id and t2.project_id=p_project_id
  where pm.project_id=p_project_id and pm.active and pm.role in ('dm','engineer','surveyor')
  group by pm.user_id,p.full_name,pm.role,pm.discipline,av.workload_pct,av.status;
$$;

-- ================================================================
-- 15) RLS for new governance tables
-- ================================================================
alter table project_risks enable row level security;
alter table project_decisions enable row level security;
drop policy if exists project_risks_select_v14 on project_risks;
create policy project_risks_select_v14 on project_risks for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists project_decisions_select_v14 on project_decisions;
create policy project_decisions_select_v14 on project_decisions for select to authenticated using (epas_is_project_member(project_id));

-- ================================================================
-- 16) Grants: only public-facing RPCs are executable by authenticated users.
-- ================================================================
revoke all on function epas_mark_notification_read(uuid) from public;
revoke all on function epas_mark_all_notifications_read() from public;
revoke all on function epas_gm_amended_design_decision(uuid,text,text) from public;
revoke all on function epas_engineer_submit_review(uuid,text,text,jsonb) from public;
revoke all on function epas_respond_plan_observation(uuid,text,text) from public;
revoke all on function epas_close_plan_observation(uuid,text) from public;
revoke all on function epas_clear_survey_observation(uuid,text) from public;
revoke all on function epas_designer_submit_revision(uuid,text,text,text) from public;
revoke all on function epas_register_project_document(uuid,text,text,text,integer) from public;
revoke all on function epas_gm_escalation_decide(uuid,text,text) from public;
revoke all on function epas_project_health(uuid) from public;
revoke all on function epas_resource_workload(uuid) from public;

grant execute on function epas_mark_notification_read(uuid) to authenticated;
grant execute on function epas_mark_all_notifications_read() to authenticated;
grant execute on function epas_gm_amended_design_decision(uuid,text,text) to authenticated;
grant execute on function epas_engineer_submit_review(uuid,text,text,jsonb) to authenticated;
grant execute on function epas_respond_plan_observation(uuid,text,text) to authenticated;
grant execute on function epas_close_plan_observation(uuid,text) to authenticated;
grant execute on function epas_clear_survey_observation(uuid,text) to authenticated;
grant execute on function epas_designer_submit_revision(uuid,text,text,text) to authenticated;
grant execute on function epas_register_project_document(uuid,text,text,text,integer) to authenticated;
grant execute on function epas_gm_escalation_decide(uuid,text,text) to authenticated;
grant execute on function epas_project_health(uuid) to authenticated;
grant execute on function epas_resource_workload(uuid) to authenticated;

-- Existing public workflow RPCs: retain their execute grants; task creation helper stays revoked.
revoke execute on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) from authenticated;

-- ================================================================
-- 17) Generic row-change audit trigger. This is the final safety net for
-- INSERT/UPDATE/DELETE mutations executed by trusted RPCs. It records the
-- actor, role, timestamps, entity, old/new state and request metadata.
-- ================================================================
create or replace function epas_audit_row_change()
returns trigger
language plpgsql security definer set search_path=public as $$
declare v_project_id uuid; v_role text; v_entity_id uuid; v_from text; v_to text; v_meta jsonb := '{}'::jsonb;
begin
  select role into v_role from profiles where id=auth.uid();
  if TG_OP='DELETE' then
    v_entity_id := (to_jsonb(OLD)->>'id')::uuid;
    v_project_id := nullif(to_jsonb(OLD)->>'project_id','')::uuid;
    v_from := to_jsonb(OLD)->>'status';
    v_to := null;
  else
    v_entity_id := (to_jsonb(NEW)->>'id')::uuid;
    v_project_id := nullif(to_jsonb(NEW)->>'project_id','')::uuid;
    v_from := case when TG_OP='UPDATE' then to_jsonb(OLD)->>'status' else null end;
    v_to := to_jsonb(NEW)->>'status';
  end if;
  begin
    v_meta := jsonb_build_object(
      'role',v_role,
      'operation',TG_OP,
      'table',TG_TABLE_NAME,
      'user_agent',current_setting('request.headers',true)::jsonb ->> 'user-agent',
      'x_forwarded_for',current_setting('request.headers',true)::jsonb ->> 'x-forwarded-for',
      'request_id',current_setting('request.headers',true)::jsonb ->> 'x-request-id'
    );
  exception when others then
    v_meta := jsonb_build_object('role',v_role,'operation',TG_OP,'table',TG_TABLE_NAME);
  end;
  insert into audit_log(project_id,actor_id,action,details,entity_type,entity_id,from_status,to_status,reason,metadata)
  values(v_project_id,auth.uid(),TG_TABLE_NAME||'_'||lower(TG_OP),
         case when TG_OP='DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end,
         TG_TABLE_NAME,v_entity_id,v_from,v_to,null,v_meta);
  if TG_OP='DELETE' then return OLD; else return NEW; end if;
end;$$;

DO $$
declare t text;
begin
  foreach t in array ARRAY['workflow_tasks','plan_drawings','plan_appraisal_observations','document_revisions','notifications','rfis','observations','corrective_actions','workflow_escalations','project_milestones','certificates','projects','project_risks','project_decisions'] loop
    execute format('drop trigger if exists epas_audit_%s on %I', lower(t), t);
    execute format('create trigger epas_audit_%s after insert or update or delete on %I for each row execute function epas_audit_row_change()', lower(t), t);
  end loop;
end $$;

-- ================================================================
-- 18) GM risk register RPCs
-- ================================================================
create or replace function epas_gm_add_risk(
  p_project_id uuid,p_title text,p_description text,p_probability text,p_impact text,
  p_severity text,p_mitigation text,p_owner_id uuid,p_target_date date
) returns project_risks
language plpgsql security definer set search_path=public as $$
declare v project_risks; v_code text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may add project risks'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_description),'')='' then raise exception 'Risk title and description are required'; end if;
  v_code := 'RISK-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS');
  insert into project_risks(project_id,risk_code,title,description,probability,impact,severity,owner_id,mitigation,target_date,created_by)
  values(p_project_id,v_code,p_title,p_description,p_probability,p_impact,p_severity,p_owner_id,p_mitigation,p_target_date,auth.uid()) returning * into v;
  return v;
end;$$;

create or replace function epas_gm_record_decision(
  p_project_id uuid,p_subject text,p_decision text,p_reason text,p_entity_type text default null,p_entity_id uuid default null
) returns project_decisions
language plpgsql security definer set search_path=public as $$
declare v project_decisions; v_code text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may record management decisions'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  if coalesce(trim(p_subject),'')='' or coalesce(trim(p_decision),'')='' then raise exception 'Decision subject and decision are required'; end if;
  v_code := 'DEC-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS');
  insert into project_decisions(project_id,decision_code,subject,decision,reason,decision_by,entity_type,entity_id)
  values(p_project_id,v_code,p_subject,p_decision,p_reason,auth.uid(),p_entity_type,p_entity_id) returning * into v;
  return v;
end;$$;

revoke all on function epas_gm_add_risk(uuid,text,text,text,text,text,text,uuid,date) from public;
revoke all on function epas_gm_record_decision(uuid,text,text,text,text,uuid) from public;
grant execute on function epas_gm_add_risk(uuid,text,text,text,text,text,text,uuid,date) to authenticated;
grant execute on function epas_gm_record_decision(uuid,text,text,text,text,uuid) to authenticated;

-- ================================================================
-- 19) Harden corrective-action assignment and evidence submission
-- ================================================================
create or replace function epas_dm_issue_corrective_action(p_action_id uuid,p_assignee_id uuid,p_instruction text,p_due_date date)
returns corrective_actions language plpgsql security definer set search_path=public as $$
declare v corrective_actions;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may issue corrective action'; end if;
  select * into v from corrective_actions where id=p_action_id for update;
  if v.assigned_to <> auth.uid() or v.status <> 'open' then raise exception 'Corrective action is not awaiting this DM'; end if;
  if coalesce(trim(p_instruction),'')='' then raise exception 'Corrective instruction is required'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v.project_id and pm.user_id=p_assignee_id and pm.active and pm.role in ('surveyor','ship_management')) then
    raise exception 'Corrective action assignee must be an active Surveyor or Ship Management member of this project';
  end if;
  update corrective_actions set assigned_to=p_assignee_id,assigned_by=auth.uid(),instruction=p_instruction,due_at=p_due_date::timestamptz,status='in_progress' where id=p_action_id returning * into v;
  perform epas_create_task(v.project_id,'CORRECTIVE_ACTION_EXECUTION',p_assignee_id,p_instruction,'corrective_action',v.id,p_due_date::timestamptz,'high');
  perform epas_audit(v.project_id,'CORRECTIVE_ACTION_ASSIGNED','corrective_action',v.id,'open','in_progress',p_instruction,jsonb_build_object('assignee',p_assignee_id));
  return v;
end;$$;

create or replace function epas_assignee_submit_corrective(p_action_id uuid,p_evidence_path text)
returns corrective_actions language plpgsql security definer set search_path=public as $$
declare v corrective_actions; v_prefix text;
begin
  select * into v from corrective_actions where id=p_action_id for update;
  if v.assigned_to <> auth.uid() then raise exception 'Corrective action is assigned to another user'; end if;
  if v.status <> 'in_progress' then raise exception 'Corrective action is not in progress'; end if;
  if coalesce(trim(p_evidence_path),'')='' then raise exception 'Evidence path is required'; end if;
  v_prefix := 'projects/'||v.project_id::text||'/corrective-actions/'||v.id::text||'/';
  if left(p_evidence_path,length(v_prefix)) <> v_prefix then raise exception 'Evidence must be stored in the controlled corrective-action folder'; end if;
  update corrective_actions set status='submitted',evidence_path=p_evidence_path,submitted_at=now() where id=p_action_id returning * into v;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='corrective_action' and entity_id=p_action_id and to_user_id=auth.uid() and task_type='CORRECTIVE_ACTION_EXECUTION' and status in ('pending','accepted','in_progress');
  perform epas_create_task(v.project_id,'DM_CORRECTIVE_ACTION_VERIFY',v.assigned_by,'Corrective action submitted for verification.','corrective_action',v.id,null,'high');
  perform epas_audit(v.project_id,'CORRECTIVE_ACTION_SUBMITTED','corrective_action',v.id,'in_progress','submitted',null,jsonb_build_object('evidence_path',p_evidence_path));
  return v;
end;$$;

-- ================================================================
-- 20) Harden generic internal task creation: valid recipient must be a project
-- member and task types must use the documented role-to-role direction.
-- ================================================================
create or replace function epas_create_task(
  p_project_id uuid,p_task_type text,p_to_user uuid,p_note text,
  p_entity_type text,p_entity_id uuid,p_due_at timestamptz default null,p_priority text default 'normal'
) returns workflow_tasks
language plpgsql security definer set search_path=public as $$
declare v_task workflow_tasks; v_from_role text; v_to_role text;
begin
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for this project'; end if;
  select role into v_from_role from profiles where id=auth.uid();
  select role into v_to_role from profiles where id=p_to_user;
  if v_to_role is null then raise exception 'Recipient profile not found'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=p_to_user and pm.active)
     and not (v_to_role='gm' and epas_has_role('gm')) then
    raise exception 'Workflow recipient is not an active member of the project';
  end if;
  if p_task_type in ('PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK') and v_to_role<>'engineer' then raise exception 'Plan engineering tasks require an Engineer recipient'; end if;
  if p_task_type in ('PLAN_APPRAISAL_MANAGER_HANDOVER','PLAN_APPRAISAL_MANAGER_REVIEW','PLAN_APPRAISAL_REVISION_DM_REVIEW','DM_CORRECTIVE_ACTION_VERIFY','FOLLOW_UP_RFI_DM_SCOPE_REVIEW','GM_ESCALATION_RETURN') and v_to_role<>'dm' then raise exception 'This workflow task requires a Department Manager recipient'; end if;
  if p_task_type in ('SURVEY_EXECUTION') and v_to_role<>'surveyor' then raise exception 'Survey execution requires a Surveyor recipient'; end if;
  if p_task_type in ('PLAN_APPRAISAL_DESIGNER_RESPONSE') and v_to_role<>'designer' then raise exception 'Designer response requires a Designer recipient'; end if;
  if p_task_type in ('CORRECTIVE_ACTION_EXECUTION') and v_to_role not in ('surveyor','ship_management') then raise exception 'Corrective execution requires Surveyor or Ship Management recipient'; end if;
  if p_task_type in ('GM_PLAN_FINAL_APPROVAL','PLAN_APPRAISAL_GM_DESIGN_DECISION','GM_SURVEY_FINAL_APPROVAL','GM_ESCALATION_REVIEW') and v_to_role<>'gm' then raise exception 'This workflow task requires GM recipient'; end if;
  insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,entity_type,entity_id,due_at,priority,sla_minutes)
  values(p_project_id,p_task_type,auth.uid(),p_to_user,'pending',p_note,p_entity_type,p_entity_id,p_due_at,p_priority,
         case when p_priority='critical' then 1440 when p_priority='high' then 2880 else 10080 end)
  returning * into v_task;
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id,due_at)
  values(p_to_user,replace(p_task_type,'_',' '),coalesce(p_note,'New workflow action requires your attention.'),p_project_id,
         case when p_entity_type='plan_drawing' then 'plan_appraisal' when p_entity_type='rfi' then 'survey_rfi' else 'dm_dashboard' end,
         'task',case when p_priority in ('high','critical') then p_priority else 'info' end,p_entity_type,p_entity_id,p_due_at);
  perform epas_audit(p_project_id,'WORKFLOW_TASK_CREATED','workflow_task',v_task.id,null,'pending',p_note,jsonb_build_object('task_type',p_task_type,'from_role',v_from_role,'to_role',v_to_role));
  return v_task;
end;$$;

revoke execute on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) from public,authenticated;

-- ================================================================
-- 21) Milestone completion RPC so the DM/GM UI never writes milestone state
-- directly. This also closes the audit gap for management milestone actions.
-- ================================================================
create or replace function epas_complete_milestone(p_milestone_id uuid,p_note text default '')
returns project_milestones
language plpgsql security definer set search_path=public as $$
declare v project_milestones;
begin
  select * into v from project_milestones where id=p_milestone_id for update;
  if v.id is null then raise exception 'Milestone not found'; end if;
  if v.owner_id<>auth.uid() and not epas_has_role('gm') then raise exception 'Milestone is not owned by current user'; end if;
  if v.status='completed' then return v; end if;
  update project_milestones set status='completed',completed_at=now() where id=v.id returning * into v;
  perform epas_audit(v.project_id,'MILESTONE_COMPLETED','project_milestone',v.id,'in_progress','completed',p_note,'{}'::jsonb);
  return v;
end;$$;
revoke all on function epas_complete_milestone(uuid,text) from public;
grant execute on function epas_complete_milestone(uuid,text) to authenticated;

-- ================================================================
-- 22) Enforce DM membership on GM handovers.
-- ================================================================
create or replace function epas_gm_handover_rfi(p_rfi_id uuid,p_dm_id uuid)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_rfi rfis;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may allocate Survey RFI'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.id is null then raise exception 'RFI not found'; end if;
  if v_rfi.status <> 'pending_allocation' then raise exception 'RFI is not awaiting GM allocation'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_rfi.project_id and pm.user_id=p_dm_id and pm.role='dm' and pm.active) then raise exception 'Selected Department Manager is not an active member of this project'; end if;
  update rfis set assigned_dm_id=p_dm_id,status='allocated_to_dm',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  perform epas_create_task(v_rfi.project_id,'SURVEY_RFI_HANDOVER',p_dm_id,'GM has forwarded the Survey RFI for scope review and surveyor allocation.','rfi',p_rfi_id,null,case when v_rfi.priority='high' then 'high' else 'normal' end);
  perform epas_audit(v_rfi.project_id,'GM_FORWARDED_SURVEY_RFI','rfi',p_rfi_id,'pending_allocation','allocated_to_dm',null,jsonb_build_object('dm_id',p_dm_id));
  return v_rfi;
end;$$;

create or replace function epas_gm_assign_plan_manager(p_drawing_id uuid,p_manager_id uuid)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may assign Plan Appraisal Manager'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.id is null then raise exception 'Drawing not found'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_d.project_id and pm.user_id=p_manager_id and pm.role='dm' and pm.active) then raise exception 'Selected Department Manager is not an active member of this project'; end if;
  update plan_drawings set manager_id=p_manager_id,status='assigned_manager',received_by=auth.uid(),updated_at=now() where id=p_drawing_id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_MANAGER_HANDOVER',p_manager_id,'GM forwarded drawing revision '||v_d.current_revision||' for technical review and engineer allocation.','plan_drawing',v_d.id,null,'high');
  perform epas_audit(v_d.project_id,'GM_FORWARDED_PLAN_DRAWING','plan_drawing',v_d.id,'submitted','assigned_manager',null,jsonb_build_object('dm_id',p_manager_id));
  return v_d;
end;$$;

-- ================================================================
-- 23) Initial Designer drawing intake. This is the first node of the Plan
-- Appraisal branch: Designer submits -> GM receives -> GM forwards to DM.
-- ================================================================
create or replace function epas_designer_submit_initial_drawing(
  p_project_id uuid,p_drawing_no text,p_title text,p_discipline text,
  p_file_name text,p_storage_path text,p_note text
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare v_doc documents; v_draw plan_drawings; v_prefix text; v_gm uuid;
begin
  if not epas_has_role('designer') then raise exception 'Only Designer may submit initial drawing'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.role='designer' and pm.active) then raise exception 'Designer is not an active member of this project'; end if;
  if coalesce(trim(p_drawing_no),'')='' or coalesce(trim(p_title),'')='' then raise exception 'Drawing number and title are required'; end if;
  if p_discipline not in ('Hull & Structure','Machinery','Electrical','Stability','Safety Equipment','Fire & LSA') then raise exception 'Invalid drawing discipline'; end if;
  if coalesce(trim(p_file_name),'')='' or coalesce(trim(p_storage_path),'')='' then raise exception 'Drawing PDF and storage path are required'; end if;
  v_prefix := 'projects/'||p_project_id::text||'/plan-appraisal/intake/';
  if p_storage_path <> v_prefix||p_file_name then raise exception 'Invalid controlled intake storage path'; end if;
  if exists(select 1 from plan_drawings d where d.project_id=p_project_id and d.drawing_no=p_drawing_no and d.status not in ('approved')) then raise exception 'A live drawing with this drawing number already exists'; end if;
  insert into documents(project_id,category,file_name,version,status,storage_path,uploaded_by)
  values(p_project_id,'drawing',p_file_name,1,'pending_review',p_storage_path,auth.uid()) returning * into v_doc;
  insert into plan_drawings(project_id,document_id,drawing_no,title,discipline,revision,status,designer_id,current_revision,current_file_name)
  values(p_project_id,v_doc.id,p_drawing_no,p_title,p_discipline,1,'submitted',auth.uid(),1,p_file_name) returning * into v_draw;
  insert into plan_revisions(drawing_id,revision_no,file_name,storage_path,submitted_by,submission_note,status)
  values(v_draw.id,1,p_file_name,p_storage_path,auth.uid(),p_note,'submitted');
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  perform epas_create_task(v_draw.project_id,'PLAN_APPRAISAL_GM_INTAKE',v_gm,'New drawing submitted by Designer for GM intake and Plan Appraisal handover.','plan_drawing',v_draw.id,null,'high');
  perform epas_audit(v_draw.project_id,'DESIGNER_INITIAL_DRAWING_SUBMITTED','plan_drawing',v_draw.id,null,'submitted',p_note,jsonb_build_object('drawing_no',p_drawing_no,'revision',1));
  return v_draw;
end;$$;
revoke all on function epas_designer_submit_initial_drawing(uuid,text,text,text,text,text,text) from public;
grant execute on function epas_designer_submit_initial_drawing(uuid,text,text,text,text,text,text) to authenticated;

-- Update GM plan-manager handover to close the Designer/GM intake task as part
-- of the same atomic transition.
create or replace function epas_gm_assign_plan_manager(p_drawing_id uuid,p_manager_id uuid)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_old text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may assign Plan Appraisal Manager'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.id is null then raise exception 'Drawing not found'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_d.project_id and pm.user_id=p_manager_id and pm.role='dm' and pm.active) then raise exception 'Selected Department Manager is not an active member of this project'; end if;
  v_old:=v_d.status;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note='GM completed drawing intake and forwarded to DM.'
  where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and task_type='PLAN_APPRAISAL_GM_INTAKE' and status in ('pending','accepted','in_progress');
  update plan_drawings set manager_id=p_manager_id,status='assigned_manager',received_by=auth.uid(),updated_at=now() where id=p_drawing_id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_MANAGER_HANDOVER',p_manager_id,'GM forwarded drawing revision '||v_d.current_revision||' for technical review and engineer allocation.','plan_drawing',v_d.id,null,'high');
  perform epas_audit(v_d.project_id,'GM_FORWARDED_PLAN_DRAWING','plan_drawing',v_d.id,v_old,'assigned_manager',null,jsonb_build_object('dm_id',p_manager_id));
  return v_d;
end;$$;

-- Re-check authorization/competency/availability before a DM sends an existing
-- Engineer back for rework. The resource gate is enforced on every allocation,
-- not only the first assignment.
create or replace function epas_dm_review_plan(p_drawing_id uuid,p_decision text,p_note text)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_gm uuid; v_ok boolean;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may review appraisal'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.manager_id <> auth.uid() then raise exception 'Drawing belongs to another DM'; end if;
  if p_decision not in ('approved','changes_required','rejected_amended') then raise exception 'Invalid DM decision'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'DM technical review note is required'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and task_type='PLAN_APPRAISAL_MANAGER_REVIEW' and status in ('accepted','in_progress');
  if p_decision='changes_required' then
    select exists(select 1 from epas_eligible_resources('engineer',v_d.discipline,current_date) e where e.user_id=v_d.engineer_id) into v_ok;
    if not v_ok then raise exception 'Assigned Engineer no longer passes authorization, competency and availability. Reallocate before requesting rework'; end if;
    update plan_drawings set status='assigned_engineer',updated_at=now() where id=p_drawing_id returning * into v_d;
    perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_ENGINEER_FEEDBACK',v_d.engineer_id,p_note,'plan_drawing',v_d.id,null,'high');
  elsif p_decision='rejected_amended' then
    update plan_drawings set status='rejected',updated_at=now() where id=p_drawing_id returning * into v_d;
    select id into v_gm from profiles where role='gm' order by created_at limit 1;
    perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_GM_DESIGN_DECISION',v_gm,p_note,'plan_drawing',v_d.id,null,'high');
  else
    update plan_drawings set status='pending_gm_approval',last_manager_review_at=now(),updated_at=now() where id=p_drawing_id returning * into v_d;
    select id into v_gm from profiles where role='gm' order by created_at limit 1;
    perform epas_create_task(v_d.project_id,'GM_PLAN_FINAL_APPROVAL',v_gm,p_note,'plan_drawing',v_d.id,null,'high');
  end if;
  perform epas_audit(v_d.project_id,'DM_PLAN_REVIEW','plan_drawing',v_d.id,'manager_review',v_d.status,p_note,jsonb_build_object('decision',p_decision));
  return v_d;
end;$$;

-- Allocation RPCs only accept eligible resources who are also active members of
-- the same project.
create or replace function epas_dm_assign_engineer(p_drawing_id uuid,p_engineer_id uuid)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_eligible boolean;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may assign engineer'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.manager_id <> auth.uid() then raise exception 'Drawing belongs to another DM'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_d.project_id and pm.user_id=p_engineer_id and pm.role='engineer' and pm.active) then raise exception 'Engineer is not an active member of this project'; end if;
  select exists(select 1 from epas_eligible_resources('engineer',v_d.discipline,current_date) e where e.user_id=p_engineer_id) into v_eligible;
  if not v_eligible then raise exception 'Engineer does not pass authorization, competency and availability checks'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and task_type in ('PLAN_APPRAISAL_MANAGER_HANDOVER','PLAN_APPRAISAL_REVISION_DM_REVIEW') and status in ('accepted','in_progress');
  update plan_drawings set engineer_id=p_engineer_id,status='assigned_engineer',updated_at=now() where id=p_drawing_id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_ENGINEERING',p_engineer_id,'Appraise drawing '||v_d.drawing_no||' Rev '||v_d.current_revision||'.','plan_drawing',v_d.id,null,'high');
  perform epas_audit(v_d.project_id,'DM_ASSIGNED_ENGINEER','plan_drawing',v_d.id,null,'assigned_engineer',null,jsonb_build_object('engineer_id',p_engineer_id,'discipline',v_d.discipline));
  return v_d;
end;$$;

create or replace function epas_dm_assign_surveyor(p_rfi_id uuid,p_surveyor_id uuid,p_scheduled_date date)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_disc text;
begin
  if not epas_has_role('dm') then raise exception 'Only Department Manager may assign surveyor'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_dm_id <> auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if v_rfi.status not in ('allocated_to_dm','sent_back_for_rework') then raise exception 'RFI is not ready for surveyor allocation'; end if;
  v_disc := case when v_rfi.survey_type ilike '%machinery%' then 'Machinery' when v_rfi.survey_type ilike '%electrical%' then 'Electrical' else 'Hull & Structure' end;
  if not exists(select 1 from project_members pm where pm.project_id=v_rfi.project_id and pm.user_id=p_surveyor_id and pm.role='surveyor' and pm.active) then raise exception 'Surveyor is not an active member of this project'; end if;
  if not exists(select 1 from epas_eligible_resources('surveyor',v_disc,current_date) e where e.user_id=p_surveyor_id) then raise exception 'Surveyor does not pass authorization, competency and availability checks'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='rfi' and entity_id=p_rfi_id and to_user_id=auth.uid() and task_type in ('SURVEY_RFI_HANDOVER','FOLLOW_UP_RFI_DM_SCOPE_REVIEW') and status in ('accepted','in_progress');
  update rfis set assigned_surveyor_id=p_surveyor_id,scheduled_date=p_scheduled_date,status='survey_in_progress',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  perform epas_create_task(v_rfi.project_id,'SURVEY_EXECUTION',p_surveyor_id,'Conduct the scheduled survey and submit the survey report.','rfi',p_rfi_id,p_scheduled_date::timestamptz,'normal');
  perform epas_audit(v_rfi.project_id,'DM_ASSIGNED_SURVEYOR','rfi',p_rfi_id,'allocated_to_dm','survey_in_progress',null,jsonb_build_object('surveyor_id',p_surveyor_id,'discipline',v_disc));
  return v_rfi;
end;$$;

-- Governance documents are also registered through RPC in v1.4.
drop policy if exists documents_insert_gm on documents;
revoke insert, update, delete on documents from anon, authenticated;

-- ================================================================
-- 24) Final browser-write lockdown for production workflow base tables.
-- GM/DM/worker actions use SECURITY DEFINER RPCs; browser clients only read
-- rows permitted by RLS.
-- ================================================================
do $$
declare r record;
begin
  for r in
    select schemaname,tablename,policyname
    from pg_policies
    where schemaname='public'
      and tablename in ('projects','rfis','certificates','vessels','team_assignments','stakeholders','documents','observations','corrective_actions','workflow_escalations','project_milestones','project_members','workflow_events')
      and cmd in ('INSERT','UPDATE','DELETE','ALL')
  loop
    execute format('drop policy if exists %I on %I.%I',r.policyname,r.schemaname,r.tablename);
  end loop;
end $$;

revoke insert, update, delete on projects,rfis,certificates,vessels,team_assignments,stakeholders,documents,observations,corrective_actions,workflow_escalations,project_milestones,project_members,workflow_events from anon,authenticated;

-- Read policies after mutation lockdown.
drop policy if exists projects_select_prod on projects;
create policy projects_select_v14 on projects for select to authenticated using (created_by=auth.uid() or epas_is_project_member(id));
drop policy if exists vessels_select_prod on vessels;
create policy vessels_select_v14 on vessels for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists team_select_prod on team_assignments;
create policy team_select_v14 on team_assignments for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists stakeholder_select_prod on stakeholders;
create policy stakeholder_select_v14 on stakeholders for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists rfis_select_prod on rfis;
create policy rfis_select_v14 on rfis for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists observations_select_prod on observations;
create policy observations_select_v14 on observations for select to authenticated using (exists(select 1 from rfis r where r.id=observations.rfi_id and epas_is_project_member(r.project_id)));
drop policy if exists corrective_select on corrective_actions;
create policy corrective_select_v14 on corrective_actions for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists escalation_select on workflow_escalations;
create policy escalation_select_v14 on workflow_escalations for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists milestone_select on project_milestones;
create policy milestone_select_v14 on project_milestones for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists project_members_select_v14 on project_members;
create policy project_members_select_v14 on project_members for select to authenticated using (user_id=auth.uid() or epas_has_role('gm') or (epas_has_role('dm') and epas_is_project_member(project_id)));
drop policy if exists workflow_events_select_v14 on workflow_events;
create policy workflow_events_select_v14 on workflow_events for select to authenticated using (epas_is_project_member(project_id));

drop policy if exists documents_select_prod on documents;
create policy documents_select_v14 on documents for select to authenticated using (epas_is_project_member(project_id));

drop policy if exists certificates_select_prod on certificates;
create policy certificates_select_v14 on certificates for select to authenticated using (epas_is_project_member(project_id));

-- ================================================================
-- 25) Controlled certificate PDF metadata registration
-- ================================================================
create or replace function epas_register_certificate_pdf(p_certificate_id uuid,p_storage_path text)
returns certificates
language plpgsql security definer set search_path=public as $$
declare v certificates; v_prefix text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may register certificate PDF'; end if;
  select * into v from certificates where id=p_certificate_id for update;
  if v.id is null then raise exception 'Certificate not found'; end if;
  if not epas_is_project_member(v.project_id) then raise exception 'Not authorized for project'; end if;
  v_prefix := 'projects/'||v.project_id::text||'/certificates/';
  if p_storage_path <> v_prefix||v.cert_number||'.pdf' then raise exception 'Invalid controlled certificate path'; end if;
  update certificates set pdf_storage_path=p_storage_path where id=v.id returning * into v;
  perform epas_audit(v.project_id,'CERTIFICATE_PDF_REGISTERED','certificate',v.id,null,'active',null,jsonb_build_object('storage_path',p_storage_path));
  return v;
end;$$;
revoke all on function epas_register_certificate_pdf(uuid,text) from public;
grant execute on function epas_register_certificate_pdf(uuid,text) to authenticated;

-- Revision history is also immutable from the browser. Revisions are created
-- only by trusted Designer/GM workflow RPCs.
revoke insert, update, delete on plan_revisions from anon, authenticated;

-- Audit log itself is immutable and project-scoped.
alter table audit_log enable row level security;
revoke insert, update, delete on audit_log from anon, authenticated;
drop policy if exists audit_log_select_v14 on audit_log;
create policy audit_log_select_v14 on audit_log for select to authenticated using (epas_is_project_member(project_id));

-- ================================================================
-- 26) SLA monitor function. Schedule from Supabase pg_cron / external worker
-- every 15 minutes in the deployment environment.
-- ================================================================
create or replace function epas_run_sla_monitor()
returns integer
language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  update workflow_tasks
     set overdue_at=now()
   where status not in ('completed','returned')
     and due_at is not null
     and due_at < now()
     and overdue_at is null;
  get diagnostics v_count=row_count;

  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id,due_at)
  select t.to_user_id,'Workflow task overdue',
         'Task '||replace(t.task_type,'_',' ')||' is overdue and requires immediate action.',
         t.project_id,
         case when t.entity_type='plan_drawing' then 'plan_appraisal' when t.entity_type='rfi' then 'survey_rfi' else 'dm_dashboard' end,
         'sla','high','workflow_task',t.id,t.due_at
    from workflow_tasks t
   where t.status not in ('completed','returned')
     and t.overdue_at is not null
     and t.overdue_at >= now()-interval '15 minutes';
  return v_count;
end;$$;
revoke all on function epas_run_sla_monitor() from public,authenticated;

-- Optional Supabase pg_cron configuration (enable pg_cron first):
-- select cron.schedule('epas-sla-monitor','*/15 * * * *','select epas_run_sla_monitor();');

create or replace function epas_resource_workload(p_project_id uuid)
returns table(
  user_id uuid, full_name text, role text, discipline text, workload_pct numeric, capacity_pct numeric,
  assigned_tasks integer, overdue_tasks integer, due_7d integer, same_due_date_conflicts integer, availability_status text
)
language sql security definer set search_path=public stable as $$
  select pm.user_id,p.full_name,pm.role,pm.discipline,
    coalesce(av.workload_pct,0)::numeric,
    (100-coalesce(av.workload_pct,0))::numeric,
    (select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.project_id=p_project_id and t.status not in ('completed','returned')),
    (select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.project_id=p_project_id and t.status not in ('completed','returned') and t.due_at<now()),
    (select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.project_id=p_project_id and t.status not in ('completed','returned') and t.due_at between now() and now()+interval '7 days'),
    (select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.project_id=p_project_id and t.status not in ('completed','returned') and t.due_at is not null and exists(select 1 from workflow_tasks x where x.id<>t.id and x.to_user_id=t.to_user_id and x.project_id=t.project_id and x.status not in ('completed','returned') and x.due_at::date=t.due_at::date)),
    coalesce(av.status,'available')
  from project_members pm
  join profiles p on p.id=pm.user_id
  left join resource_availability_calendar av on av.user_id=pm.user_id and av.work_date=current_date
  where pm.project_id=p_project_id and pm.active and pm.role in ('dm','engineer','surveyor');
$$;

-- Harden Surveyor execution: one controlled report submission per active survey
-- task, complete the task atomically and hand over to DM.
create or replace function epas_submit_survey_report(p_rfi_id uuid,p_report_note text,p_observations jsonb default '[]'::jsonb)
returns survey_reports language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_report survey_reports; v_item jsonb; v_dm uuid; v_old text; v_count integer;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may submit survey report'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_surveyor_id <> auth.uid() then raise exception 'RFI is assigned to another surveyor'; end if;
  if v_rfi.status <> 'survey_in_progress' then raise exception 'RFI is not currently in Survey execution'; end if;
  if coalesce(trim(p_report_note),'')='' then raise exception 'Survey report note is required'; end if;
  select count(*) into v_count from survey_reports where rfi_id=p_rfi_id;
  if v_count>0 then raise exception 'A survey report has already been submitted for this RFI'; end if;
  insert into survey_reports(rfi_id,surveyor_id,report_note) values(p_rfi_id,auth.uid(),p_report_note) returning * into v_report;
  for v_item in select * from jsonb_array_elements(coalesce(p_observations,'[]'::jsonb)) loop
    if coalesce(trim(v_item->>'description'),'')='' then raise exception 'Every survey observation requires a description'; end if;
    insert into observations(rfi_id,obs_code,description,severity,status,raised_by)
    values(p_rfi_id,coalesce(nullif(v_item->>'obs_code',''),'OBS-'||substr(gen_random_uuid()::text,1,8)),v_item->>'description',coalesce(v_item->>'severity','Minor'),'open',auth.uid());
  end loop;
  v_old:=v_rfi.status;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_report_note
   where entity_type='rfi' and entity_id=p_rfi_id and to_user_id=auth.uid() and task_type='SURVEY_EXECUTION' and status in ('accepted','in_progress');
  update rfis set status='observations_logged',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  v_dm:=v_rfi.assigned_dm_id;
  perform epas_create_task(v_rfi.project_id,'SURVEY_DM_REVIEW',v_dm,'Survey report submitted. Review report and observations before forwarding to GM.','rfi',p_rfi_id,null,'high');
  perform epas_audit(v_rfi.project_id,'SURVEY_REPORT_SUBMITTED','rfi',p_rfi_id,v_old,'observations_logged',p_report_note,jsonb_build_object('observation_count',jsonb_array_length(coalesce(p_observations,'[]'::jsonb))));
  return v_report;
end;$$;

-- Project-scoped eligibility wrapper. Existing public eligibility function remains
-- for compatibility; v1.4 allocation UIs should use this function.
create or replace function epas_project_eligible_resources(p_project_id uuid,p_role text,p_discipline text,p_work_date date default current_date)
returns table(user_id uuid, full_name text, authorization_level text, workload_pct numeric, eligibility_note text)
language sql security definer set search_path=public stable as $$
  select e.user_id,e.full_name,e.authorization_level,e.workload_pct,e.eligibility_note
  from epas_eligible_resources(p_role,p_discipline,p_work_date) e
  where exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=e.user_id and pm.role=p_role and pm.active);
$$;
revoke all on function epas_project_eligible_resources(uuid,text,text,date) from public;
grant execute on function epas_project_eligible_resources(uuid,text,text,date) to authenticated;
