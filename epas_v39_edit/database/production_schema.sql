-- EPAS Production Workflow Schema
-- Apply after database/schema.sql and database/upgrade_schema.sql.
-- This migration is designed for Supabase/PostgreSQL and removes the need for
-- client-side demo state for the GM and Department Manager workflows.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Project governance / membership
-- ---------------------------------------------------------------------------
alter table projects add column if not exists classification_number text;
alter table projects add column if not exists register_number text;
alter table projects add column if not exists contract_number text;
alter table projects add column if not exists classification_request text;
alter table projects add column if not exists classification_scope text;
alter table projects add column if not exists applicable_rules text[] default '{}';
alter table projects add column if not exists start_date date;
alter table projects add column if not exists target_completion_date date;
alter table projects add column if not exists survey_type text;
alter table projects add column if not exists build_stage text;
alter table projects add column if not exists remarks text;
alter table projects add column if not exists activated_at timestamptz;
alter table projects add column if not exists activated_by uuid references profiles(id);
alter table stakeholders add column if not exists stakeholder_user_id uuid references profiles(id);

create table if not exists notification_outbox (
    id uuid primary key default gen_random_uuid(),
    project_id uuid references projects(id) on delete cascade,
    recipient_email text not null,
    subject text not null,
    body text not null,
    status text not null default 'queued' check (status in ('queued','sent','failed')),
    created_at timestamptz not null default now(),
    sent_at timestamptz,
    error_message text
);
create index if not exists idx_notification_outbox_status on notification_outbox(status, created_at);

create table if not exists project_members (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references projects(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    role text not null check (role in ('gm','dm','engineer','surveyor','designer','owner','ship_management','shipyard')),
    discipline text,
    active boolean not null default true,
    assigned_at timestamptz not null default now(),
    unique(project_id,user_id,role,discipline)
);

create index if not exists idx_project_members_user on project_members(user_id, active);
create index if not exists idx_project_members_project on project_members(project_id, active);

-- ---------------------------------------------------------------------------
-- Controlled workflow tasks / events / notifications
-- ---------------------------------------------------------------------------
alter table workflow_tasks add column if not exists due_at timestamptz;
alter table workflow_tasks add column if not exists priority text not null default 'normal';
alter table workflow_tasks add column if not exists entity_type text;
alter table workflow_tasks add column if not exists entity_id uuid;
alter table workflow_tasks add column if not exists completed_by uuid references profiles(id);
alter table workflow_tasks add column if not exists returned_by uuid references profiles(id);
alter table workflow_tasks add column if not exists returned_at timestamptz;
alter table workflow_tasks add column if not exists completed_note text;

create table if not exists workflow_events (
    id uuid primary key default gen_random_uuid(),
    project_id uuid references projects(id) on delete cascade,
    entity_type text not null,
    entity_id uuid not null,
    event_type text not null,
    from_status text,
    to_status text,
    actor_id uuid not null references profiles(id),
    note text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists idx_workflow_events_entity on workflow_events(entity_type, entity_id, created_at desc);

alter table notifications add column if not exists notification_type text not null default 'workflow';
alter table notifications add column if not exists severity text not null default 'info';
alter table notifications add column if not exists entity_type text;
alter table notifications add column if not exists entity_id uuid;
alter table notifications add column if not exists due_at timestamptz;

-- ---------------------------------------------------------------------------
-- Authorization / competency / availability
-- ---------------------------------------------------------------------------
create table if not exists resource_authorizations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references profiles(id) on delete cascade,
    discipline text not null,
    scope text,
    authorization_level text not null,
    valid_from date not null default current_date,
    valid_until date,
    active boolean not null default true,
    approved_by uuid references profiles(id),
    evidence_document_id uuid references documents(id),
    created_at timestamptz not null default now()
);
create index if not exists idx_resource_auth_user_disc on resource_authorizations(user_id, discipline, active);

create table if not exists resource_competencies (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references profiles(id) on delete cascade,
    discipline text not null,
    competency_area text not null,
    status text not null check (status in ('competent','conditional','expired','not_competent')),
    assessed_on date not null,
    valid_until date,
    assessor_id uuid references profiles(id),
    evidence_document_id uuid references documents(id),
    notes text
);
create index if not exists idx_resource_comp_user_disc on resource_competencies(user_id, discipline, status);

create table if not exists resource_availability_calendar (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references profiles(id) on delete cascade,
    work_date date not null,
    status text not null check (status in ('available','partial','leave','travel','unavailable')),
    workload_pct numeric(5,2) not null default 0 check (workload_pct between 0 and 100),
    location text,
    notes text,
    unique(user_id,work_date)
);
create index if not exists idx_resource_avail_user_date on resource_availability_calendar(user_id, work_date);

-- ---------------------------------------------------------------------------
-- Plan appraisal: controlled drawing -> revision -> observation -> approval
-- ---------------------------------------------------------------------------
alter table plan_drawings add column if not exists current_revision integer not null default 1;
alter table plan_drawings add column if not exists received_by uuid references profiles(id);
alter table plan_drawings add column if not exists approved_by uuid references profiles(id);
alter table plan_drawings add column if not exists approved_at timestamptz;
alter table plan_drawings add column if not exists due_at timestamptz;
alter table plan_drawings add column if not exists last_manager_review_at timestamptz;

create table if not exists plan_revisions (
    id uuid primary key default gen_random_uuid(),
    drawing_id uuid not null references plan_drawings(id) on delete cascade,
    revision_no integer not null,
    file_name text not null,
    storage_path text not null,
    submitted_by uuid not null references profiles(id),
    submission_note text,
    status text not null default 'submitted' check (status in ('submitted','under_review','changes_required','rejected','approved','superseded')),
    submitted_at timestamptz not null default now(),
    reviewed_at timestamptz,
    unique(drawing_id, revision_no)
);
create index if not exists idx_plan_revisions_drawing on plan_revisions(drawing_id, revision_no desc);

alter table plan_appraisal_observations add column if not exists clause_reference text;
alter table plan_appraisal_observations add column if not exists drawing_reference text;
alter table plan_appraisal_observations add column if not exists reviewer_note text;
alter table plan_appraisal_observations add column if not exists closed_by uuid references profiles(id);
alter table plan_appraisal_observations add column if not exists closed_at timestamptz;
alter table plan_appraisal_observations add column if not exists response_evidence_path text;

-- ---------------------------------------------------------------------------
-- Survey / corrective action / escalation / milestones
-- ---------------------------------------------------------------------------
create table if not exists corrective_actions (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references projects(id) on delete cascade,
    rfi_id uuid not null references rfis(id) on delete cascade,
    assigned_to uuid references profiles(id),
    assigned_by uuid not null references profiles(id),
    instruction text not null,
    status text not null default 'open' check (status in ('open','in_progress','submitted','verified','rejected','closed')),
    due_at timestamptz,
    evidence_path text,
    submitted_at timestamptz,
    verified_by uuid references profiles(id),
    verified_at timestamptz,
    created_at timestamptz not null default now()
);
create index if not exists idx_corrective_rfi_status on corrective_actions(rfi_id,status);

create table if not exists workflow_escalations (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references projects(id) on delete cascade,
    entity_type text not null,
    entity_id uuid not null,
    raised_by uuid not null references profiles(id),
    assigned_to uuid not null references profiles(id),
    reason text not null,
    recommendation text not null,
    severity text not null default 'medium' check (severity in ('low','medium','high','critical')),
    status text not null default 'open' check (status in ('open','acknowledged','resolved','rejected')),
    created_at timestamptz not null default now(),
    resolved_at timestamptz,
    resolved_note text
);

create table if not exists project_milestones (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references projects(id) on delete cascade,
    code text not null,
    title text not null,
    phase text,
    due_date date,
    status text not null default 'pending' check (status in ('pending','in_progress','completed','delayed','cancelled')),
    completed_at timestamptz,
    owner_id uuid references profiles(id),
    unique(project_id,code)
);

-- ---------------------------------------------------------------------------
-- Helper security functions
-- ---------------------------------------------------------------------------
create or replace function epas_my_profile()
returns profiles
language sql
security definer
set search_path = public
stable
as $$
  select p.* from profiles p where p.id = auth.uid();
$$;

create or replace function epas_has_role(p_role text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists(select 1 from profiles p where p.id = auth.uid() and p.role = p_role);
$$;

create or replace function epas_is_project_member(p_project_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select epas_has_role('gm') or exists(
    select 1 from project_members pm where pm.project_id = p_project_id and pm.user_id = auth.uid() and pm.active
  );
$$;

-- ---------------------------------------------------------------------------
-- Eligibility function: authorization + competency + availability/workload
-- ---------------------------------------------------------------------------
create or replace function epas_eligible_resources(p_role text, p_discipline text, p_work_date date default current_date)
returns table(user_id uuid, full_name text, authorization_level text, workload_pct numeric, eligibility_note text)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.full_name, a.authorization_level, coalesce(av.workload_pct,0),
    'Authorized + competent + available'::text
  from profiles p
  join lateral (
    select ra.* from resource_authorizations ra
    where ra.user_id=p.id and ra.discipline=p_discipline and ra.active
      and ra.valid_from <= p_work_date and (ra.valid_until is null or ra.valid_until >= p_work_date)
    order by ra.authorization_level desc limit 1
  ) a on true
  join lateral (
    select rc.* from resource_competencies rc
    where rc.user_id=p.id and rc.discipline=p_discipline and rc.status='competent'
      and rc.assessed_on <= p_work_date and (rc.valid_until is null or rc.valid_until >= p_work_date)
    order by rc.assessed_on desc limit 1
  ) c on true
  left join resource_availability_calendar av on av.user_id=p.id and av.work_date=p_work_date
  where p.role=p_role
    and coalesce(av.status,'available') in ('available','partial')
    and coalesce(av.workload_pct,0) < 90;
$$;

-- ---------------------------------------------------------------------------
-- Atomic project creation: validates GM role, creates active project,
-- vessel, team/membership, stakeholders, milestones and notifications.
-- ---------------------------------------------------------------------------
create or replace function epas_create_project(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_project projects;
  v_vessel vessels;
  v_item jsonb;
  v_code text;
  v_gm uuid := auth.uid();
begin
  if not epas_has_role('gm') then raise exception 'Only GM Classification may create projects'; end if;
  if coalesce(trim(p_payload->>'name'),'') = '' then raise exception 'Project name is required'; end if;
  if coalesce(trim(p_payload->>'vessel_type'),'') = '' then raise exception 'Vessel type is required'; end if;
  if coalesce(trim(p_payload->>'flag_state'),'') = '' then raise exception 'Flag state is required'; end if;

  v_code := coalesce(nullif(trim(p_payload->>'project_code'),''), 'EPAS-' || to_char(now(),'YYYY') || '-' || lpad((extract(epoch from clock_timestamp())::bigint % 100000)::text,5,'0'));

  insert into projects(
    project_code,name,vessel_type,flag_state,phases,status,created_by,
    classification_number,register_number,contract_number,classification_request,
    classification_scope,applicable_rules,start_date,target_completion_date,
    survey_type,build_stage,remarks,activated_at,activated_by
  ) values (
    v_code,p_payload->>'name',p_payload->>'vessel_type',p_payload->>'flag_state',
    coalesce(array(select jsonb_array_elements_text(p_payload->'phases')),'{}'),
    'active',v_gm,
    p_payload->>'classification_number',p_payload->>'register_number',p_payload->>'contract_number',p_payload->>'classification_request',
    p_payload->>'classification_scope',coalesce(array(select jsonb_array_elements_text(p_payload->'applicable_rules')),'{}'),
    nullif(p_payload->>'start_date','')::date,nullif(p_payload->>'target_completion_date','')::date,
    p_payload->>'survey_type',p_payload->>'build_stage',p_payload->>'remarks',now(),v_gm
  ) returning * into v_project;

  insert into vessels(project_id,name,imo_number,flag_state,loa_m,beam_m,draft_m,power_kw,speed_knots,build_year,owner_company,current_class)
  values(v_project.id,
    coalesce(p_payload->'vessel'->>'name',v_project.name),
    nullif(p_payload->'vessel'->>'imo_number',''),v_project.flag_state,
    nullif(p_payload->'vessel'->>'loa_m','')::numeric,nullif(p_payload->'vessel'->>'beam_m','')::numeric,
    nullif(p_payload->'vessel'->>'draft_m','')::numeric,nullif(p_payload->'vessel'->>'power_kw','')::numeric,
    nullif(p_payload->'vessel'->>'speed_knots','')::numeric,nullif(p_payload->'vessel'->>'build_year','')::int,
    p_payload->'vessel'->>'owner_company','Pending Classification') returning * into v_vessel;

  insert into project_members(project_id,user_id,role,discipline) values(v_project.id,v_gm,'gm',null);

  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'team','[]'::jsonb)) loop
    insert into project_members(project_id,user_id,role,discipline)
    values(v_project.id,(v_item->>'user_id')::uuid,v_item->>'role',nullif(v_item->>'discipline',''))
    on conflict do nothing;
    insert into team_assignments(project_id,user_id,role,discipline)
    values(v_project.id,(v_item->>'user_id')::uuid,v_item->>'role',nullif(v_item->>'discipline',''));
    insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
    values((v_item->>'user_id')::uuid,'New project assignment','You have been assigned to project '||v_project.project_code,v_project.id,'project','assignment','info','project',v_project.id);
  end loop;

  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'stakeholders','[]'::jsonb)) loop
    if coalesce(trim(v_item->>'company_name'),'') <> '' then
      insert into stakeholders(project_id,company_name,contact_name,contact_email,stakeholder_type,stakeholder_user_id)
      values(v_project.id,v_item->>'company_name',v_item->>'contact_name',v_item->>'contact_email',v_item->>'stakeholder_type',nullif(v_item->>'user_id','')::uuid);
      if nullif(v_item->>'user_id','') is not null then
        insert into project_members(project_id,user_id,role)
        values(v_project.id,(v_item->>'user_id')::uuid,v_item->>'stakeholder_type') on conflict do nothing;
        insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
        values((v_item->>'user_id')::uuid,'Project stakeholder access', 'You have been added as a stakeholder to project '||v_project.project_code,v_project.id,'projects','assignment','info','project',v_project.id);
      end if;
      if coalesce(trim(v_item->>'contact_email'),'') <> '' then
        insert into notification_outbox(project_id,recipient_email,subject,body)
        values(v_project.id,v_item->>'contact_email','EPAS Project Assignment','You have been added as a stakeholder to project '||v_project.project_code||'. Sign in to the EPAS portal to view permitted project information.');
      end if;
    end if;
  end loop;

  insert into project_milestones(project_id,code,title,phase,due_date,status,owner_id)
  select v_project.id, x.code, x.title, x.phase,
         case when v_project.target_completion_date is not null then v_project.target_completion_date else null end,
         'pending',v_gm
  from (values
    ('PA-01','Plan Appraisal Complete','plan_appraisal'),
    ('SUR-01','Survey Programme Complete','nsc_survey'),
    ('CERT-01','Certificate / Class Record','in_service')
  ) x(code,title,phase)
  where x.phase = any(v_project.phases);

  insert into workflow_events(project_id,entity_type,entity_id,event_type,to_status,actor_id,note)
  values(v_project.id,'project',v_project.id,'PROJECT_CREATED','active',v_gm,'Project created and activated by GM');

  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  values(v_gm,'Project activated',v_project.project_code||' is active and ready for execution.',v_project.id,'projects','workflow','success','project',v_project.id);

  return jsonb_build_object('project',to_jsonb(v_project),'vessel',to_jsonb(v_vessel));
end;
$$;

-- ---------------------------------------------------------------------------
-- Generic secure task creation helper
-- ---------------------------------------------------------------------------
create or replace function epas_create_task(
  p_project_id uuid,p_task_type text,p_to_user uuid,p_note text,
  p_entity_type text,p_entity_id uuid,p_due_at timestamptz default null,p_priority text default 'normal'
) returns workflow_tasks
language plpgsql security definer set search_path=public as $$
declare v_task workflow_tasks;
begin
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for this project'; end if;
  insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,entity_type,entity_id,due_at,priority)
  values(p_project_id,p_task_type,auth.uid(),p_to_user,'pending',p_note,p_entity_type,p_entity_id,p_due_at,p_priority)
  returning * into v_task;
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id,due_at)
  values(p_to_user,replace(p_task_type,'_',' '),coalesce(p_note,'New workflow action requires your attention.'),p_project_id,
         case when p_entity_type='plan_drawing' then 'plan_appraisal' else 'dm_dashboard' end,
         'task','info',p_entity_type,p_entity_id,p_due_at);
  return v_task;
end;
$$;

-- ---------------------------------------------------------------------------
-- GM -> DM Survey RFI handover
-- ---------------------------------------------------------------------------
create or replace function epas_gm_handover_rfi(p_rfi_id uuid,p_dm_id uuid)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_rfi rfis;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may allocate Survey RFI'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.id is null then raise exception 'RFI not found'; end if;
  if v_rfi.status <> 'pending_allocation' then raise exception 'RFI is not awaiting GM allocation'; end if;
  if not exists(select 1 from profiles where id=p_dm_id and role='dm') then raise exception 'Selected user is not a Department Manager'; end if;
  update rfis set assigned_dm_id=p_dm_id,status='allocated_to_dm',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  perform epas_create_task(v_rfi.project_id,'SURVEY_RFI_HANDOVER',p_dm_id,'GM has forwarded the Survey RFI for scope review and surveyor allocation.','rfi',p_rfi_id,null,case when v_rfi.priority='high' then 'high' else 'normal' end);
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v_rfi.project_id,'rfi',p_rfi_id,'GM_FORWARDED_TO_DM','pending_allocation','allocated_to_dm',auth.uid(),'GM forwarded Survey RFI to Department Manager');
  return v_rfi;
end;$$;

-- ---------------------------------------------------------------------------
-- DM -> authorized surveyor assignment
-- ---------------------------------------------------------------------------
create or replace function epas_dm_assign_surveyor(p_rfi_id uuid,p_surveyor_id uuid,p_scheduled_date date)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_disc text;
begin
  if not epas_has_role('dm') then raise exception 'Only Department Manager may assign surveyor'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_dm_id <> auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if v_rfi.status not in ('allocated_to_dm','sent_back_for_rework') then raise exception 'RFI is not ready for surveyor allocation'; end if;
  v_disc := case when v_rfi.survey_type ilike '%machinery%' then 'Machinery' when v_rfi.survey_type ilike '%electrical%' then 'Electrical' else 'Hull & Structure' end;
  if not exists(select 1 from epas_eligible_resources('surveyor',v_disc,current_date) e where e.user_id=p_surveyor_id) then
    raise exception 'Surveyor does not pass authorization, competency and availability checks';
  end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='rfi' and entity_id=p_rfi_id and to_user_id=auth.uid() and task_type in ('SURVEY_RFI_HANDOVER','FOLLOW_UP_RFI_DM_SCOPE_REVIEW') and status in ('accepted','in_progress');
  update rfis set assigned_surveyor_id=p_surveyor_id,scheduled_date=p_scheduled_date,status='survey_in_progress',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  perform epas_create_task(v_rfi.project_id,'SURVEY_EXECUTION',p_surveyor_id,'Conduct the scheduled survey and submit the survey report.','rfi',p_rfi_id,p_scheduled_date::timestamptz,'normal');
  return v_rfi;
end;$$;

create or replace function epas_submit_survey_report(p_rfi_id uuid,p_report_note text,p_observations jsonb default '[]'::jsonb)
returns survey_reports language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_report survey_reports; v_item jsonb; v_dm uuid;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may submit survey report'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_surveyor_id <> auth.uid() then raise exception 'RFI is assigned to another surveyor'; end if;
  if coalesce(trim(p_report_note),'')='' then raise exception 'Survey report note is required'; end if;
  insert into survey_reports(rfi_id,surveyor_id,report_note) values(p_rfi_id,auth.uid(),p_report_note) returning * into v_report;
  for v_item in select * from jsonb_array_elements(coalesce(p_observations,'[]'::jsonb)) loop
    insert into observations(rfi_id,obs_code,description,severity,status,raised_by)
    values(p_rfi_id,coalesce(v_item->>'obs_code','OBS-'||substr(gen_random_uuid()::text,1,8)),v_item->>'description',coalesce(v_item->>'severity','Minor'),'open',auth.uid());
  end loop;
  update rfis set status='observations_logged',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  v_dm := v_rfi.assigned_dm_id;
  perform epas_create_task(v_rfi.project_id,'SURVEY_DM_REVIEW',v_dm,'Survey report submitted. Review report and observations before forwarding to GM.','rfi',p_rfi_id,null,'high');
  return v_report;
end;$$;

-- ---------------------------------------------------------------------------
-- DM survey review -> GM
-- ---------------------------------------------------------------------------
create or replace function epas_dm_forward_survey(p_rfi_id uuid,p_remarks text)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_obs int;
declare v_gm uuid;
begin
  if not epas_has_role('dm') then raise exception 'Only Department Manager may review survey report'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_dm_id <> auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  select count(*) into v_obs from observations where rfi_id=p_rfi_id and status='open';
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='rfi' and entity_id=p_rfi_id and to_user_id=auth.uid() and task_type='SURVEY_DM_REVIEW' and status in ('accepted','in_progress');
  update rfis set status='pending_gm_approval',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  perform epas_create_task(v_rfi.project_id,'GM_SURVEY_FINAL_APPROVAL',v_gm,coalesce(p_remarks,'DM reviewed survey report and forwarded for GM approval.'),'rfi',p_rfi_id,null,'high');
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v_rfi.project_id,'rfi',p_rfi_id,'DM_FORWARDED_TO_GM','observations_logged','pending_gm_approval',auth.uid(),p_remarks);
  return v_rfi;
end;$$;

-- ---------------------------------------------------------------------------
-- GM survey decision: approve or return to DM. Return creates corrective task.
-- ---------------------------------------------------------------------------
create or replace function epas_gm_decide_rfi(p_rfi_id uuid,p_decision text,p_note text)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_obs int; v_dm uuid; v_action corrective_actions; v_gm uuid := auth.uid();
begin
  if not epas_has_role('gm') then raise exception 'Only GM may decide Survey RFI'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.status <> 'pending_gm_approval' then raise exception 'RFI is not awaiting GM approval'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='rfi' and entity_id=p_rfi_id and to_user_id=auth.uid() and status in ('pending','accepted','in_progress');
  if p_decision not in ('approved','sent_back') then raise exception 'Invalid GM decision'; end if;
  if p_decision='sent_back' and coalesce(trim(p_note),'')='' then raise exception 'GM send-back requires a reason'; end if;
  insert into gm_decisions(rfi_id,decided_by,decision,note) values(p_rfi_id,v_gm,p_decision,p_note);
  v_dm := v_rfi.assigned_dm_id;
  if p_decision='sent_back' then
    update rfis set status='sent_back_for_rework',updated_at=now() where id=p_rfi_id returning * into v_rfi;
    insert into corrective_actions(project_id,rfi_id,assigned_to,assigned_by,instruction,status,due_at)
    values(v_rfi.project_id,p_rfi_id,v_dm,v_gm,p_note,'open',now()+interval '3 days') returning * into v_action;
    perform epas_create_task(v_rfi.project_id,'DM_CORRECTIVE_ACTION',v_dm,p_note,'corrective_action',v_action.id,v_action.due_at,'high');
  else
    select count(*) into v_obs from observations where rfi_id=p_rfi_id and status='open';
    update rfis set status=case when v_obs>0 then 'approved_with_observations' else 'approved_no_observations' end,updated_at=now() where id=p_rfi_id returning * into v_rfi;
    perform epas_create_task(v_rfi.project_id,'DM_GM_FINAL_APPROVAL_ACK',v_dm,'GM approved the survey RFI. Proceed with certificate workflow / close-out.','rfi',p_rfi_id,null,'normal');
  end if;
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v_rfi.project_id,'rfi',p_rfi_id,'GM_DECISION','pending_gm_approval',v_rfi.status,v_gm,p_note);
  return v_rfi;
end;$$;

-- ---------------------------------------------------------------------------
-- DM corrective action -> follow-up RFI (returns to DM inbox, not DM->DM task)
-- ---------------------------------------------------------------------------
create or replace function epas_dm_issue_corrective_action(p_action_id uuid,p_assignee_id uuid,p_instruction text,p_due_date date)
returns corrective_actions language plpgsql security definer set search_path=public as $$
declare v_action corrective_actions;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may issue corrective action'; end if;
  select * into v_action from corrective_actions where id=p_action_id for update;
  if v_action.assigned_to <> auth.uid() or v_action.status <> 'open' then raise exception 'Corrective action is not awaiting this DM'; end if;
  if coalesce(trim(p_instruction),'')='' then raise exception 'Corrective instruction is required'; end if;
  if not exists(select 1 from profiles where id=p_assignee_id and role in ('surveyor','ship_management')) then raise exception 'Corrective action assignee must be a Surveyor or Ship Management user'; end if;
  update corrective_actions set assigned_to=p_assignee_id,assigned_by=auth.uid(),instruction=p_instruction,due_at=p_due_date::timestamptz,status='in_progress' where id=p_action_id returning * into v_action;
  perform epas_create_task(v_action.project_id,'CORRECTIVE_ACTION_EXECUTION',p_assignee_id,p_instruction,'corrective_action',v_action.id,p_due_date::timestamptz,'high');
  return v_action;
end;$$;

create or replace function epas_assignee_submit_corrective(p_action_id uuid,p_evidence_path text)
returns corrective_actions language plpgsql security definer set search_path=public as $$
declare v corrective_actions;
begin
  select * into v from corrective_actions where id=p_action_id for update;
  if v.assigned_to <> auth.uid() then raise exception 'Corrective action is assigned to another user'; end if;
  update corrective_actions set status='submitted',evidence_path=p_evidence_path,submitted_at=now() where id=p_action_id returning * into v;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='corrective_action' and entity_id=p_action_id and to_user_id=auth.uid() and status in ('pending','accepted','in_progress');
  perform epas_create_task(v.project_id,'DM_CORRECTIVE_ACTION_VERIFY',v.assigned_by,'Corrective action submitted for verification.','corrective_action',v.id,null,'high');
  return v;
end;$$;

create or replace function epas_dm_create_followup_rfi(p_action_id uuid)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_action corrective_actions; v_old rfis; v_new rfis;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may create follow-up RFI'; end if;
  select * into v_action from corrective_actions where id=p_action_id for update;
  if v_action.assigned_by <> auth.uid() then raise exception 'Corrective action is assigned to another DM'; end if;
  if v_action.status <> 'submitted' then raise exception 'Corrective action must be submitted before follow-up RFI'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='corrective_action' and entity_id=p_action_id and to_user_id=auth.uid() and task_type='DM_CORRECTIVE_ACTION_VERIFY' and status in ('accepted','in_progress','pending');
  select * into v_old from rfis where id=v_action.rfi_id;
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,assigned_dm_id,requested_date,priority)
  values(v_old.project_id,v_old.vessel_id,v_old.phase,v_old.survey_type,v_old.rfi_code||'-FU-'||substr(gen_random_uuid()::text,1,4),'allocated_to_dm',auth.uid(),auth.uid(),current_date,'high') returning * into v_new;
  update corrective_actions set status='closed',verified_by=auth.uid(),verified_at=now() where id=p_action_id;
  perform epas_create_task(v_new.project_id,'FOLLOW_UP_RFI_DM_SCOPE_REVIEW',auth.uid(),'Follow-up RFI created after corrective action. Review scope and continue the survey loop.','rfi',v_new.id,null,'high');
  return v_new;
end;$$;

-- ---------------------------------------------------------------------------
-- DM escalation to GM
-- ---------------------------------------------------------------------------
create or replace function epas_dm_escalate(p_project_id uuid,p_entity_type text,p_entity_id uuid,p_reason text,p_recommendation text,p_severity text default 'medium')
returns workflow_escalations language plpgsql security definer set search_path=public as $$
declare v_gm uuid; v_row workflow_escalations;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may escalate'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not assigned to this project'; end if;
  if coalesce(trim(p_reason),'')='' or coalesce(trim(p_recommendation),'')='' then raise exception 'Reason and recommendation are required'; end if;
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  insert into workflow_escalations(project_id,entity_type,entity_id,raised_by,assigned_to,reason,recommendation,severity)
  values(p_project_id,p_entity_type,p_entity_id,auth.uid(),v_gm,p_reason,p_recommendation,p_severity) returning * into v_row;
  perform epas_create_task(p_project_id,'GM_ESCALATION_REVIEW',v_gm,p_reason||' | Recommendation: '||p_recommendation,p_entity_type,p_entity_id,null,p_severity);
  return v_row;
end;$$;

-- ---------------------------------------------------------------------------
-- Plan appraisal: GM -> DM, DM -> Engineer, Engineer -> DM, DM -> GM,
-- GM -> Designer, Designer -> DM -> Engineer revision loop.
-- ---------------------------------------------------------------------------
create or replace function epas_gm_assign_plan_manager(p_drawing_id uuid,p_manager_id uuid)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may assign Plan Appraisal Manager'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.id is null then raise exception 'Drawing not found'; end if;
  if not exists(select 1 from profiles where id=p_manager_id and role='dm') then raise exception 'Selected user is not a Department Manager'; end if;
  update plan_drawings set manager_id=p_manager_id,status='assigned_manager',received_by=auth.uid(),updated_at=now() where id=p_drawing_id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_MANAGER_HANDOVER',p_manager_id,'GM forwarded drawing revision '||v_d.current_revision||' for technical review and engineer allocation.','plan_drawing',v_d.id,null,'high');
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v_d.project_id,'plan_drawing',v_d.id,'GM_FORWARDED_TO_DM', 'submitted','assigned_manager',auth.uid(),'Plan appraisal drawing forwarded to DM');
  return v_d;
end;$$;

create or replace function epas_dm_assign_engineer(p_drawing_id uuid,p_engineer_id uuid)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_eligible boolean;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may assign engineer'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.manager_id <> auth.uid() then raise exception 'Drawing belongs to another DM'; end if;
  select exists(select 1 from epas_eligible_resources('engineer',v_d.discipline,current_date) e where e.user_id=p_engineer_id) into v_eligible;
  if not v_eligible then raise exception 'Engineer does not pass authorization, competency and availability checks'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and task_type in ('PLAN_APPRAISAL_MANAGER_HANDOVER','PLAN_APPRAISAL_REVISION_DM_REVIEW') and status in ('accepted','in_progress');
  update plan_drawings set engineer_id=p_engineer_id,status='assigned_engineer',updated_at=now() where id=p_drawing_id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_ENGINEERING',p_engineer_id,'Appraise drawing '||v_d.drawing_no||' Rev '||v_d.current_revision||'.','plan_drawing',v_d.id,null,'high');
  return v_d;
end;$$;

create or replace function epas_engineer_submit_review(p_drawing_id uuid,p_decision text,p_note text)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_task workflow_tasks; v_obs int;
begin
  if not epas_has_role('engineer') then raise exception 'Only Engineer may submit technical appraisal'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.engineer_id <> auth.uid() then raise exception 'Drawing is assigned to another engineer'; end if;
  if p_decision not in ('accepted','observation') then raise exception 'Invalid engineer decision'; end if;
  if p_decision='observation' then
    update plan_drawings set status='observation_raised',updated_at=now() where id=p_drawing_id returning * into v_d;
  else
    select count(*) into v_obs from plan_appraisal_observations where drawing_id=p_drawing_id and status='open';
    update plan_drawings set status='manager_review',updated_at=now(),last_manager_review_at=null where id=p_drawing_id returning * into v_d;
  end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and status in ('pending','accepted','in_progress');
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_MANAGER_REVIEW',v_d.manager_id,'Engineer completed technical appraisal: '||coalesce(p_note,''),'plan_drawing',v_d.id,null,'high');
  insert into workflow_events(project_id,entity_type,entity_id,event_type,to_status,actor_id,note)
  values(v_d.project_id,'plan_drawing',v_d.id,'ENGINEER_SUBMITTED_REVIEW',v_d.status,auth.uid(),p_note);
  return v_d;
end;$$;

create or replace function epas_dm_review_plan(p_drawing_id uuid,p_decision text,p_note text)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_gm uuid; v_des uuid;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may review appraisal'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.manager_id <> auth.uid() then raise exception 'Drawing belongs to another DM'; end if;
  if p_decision not in ('approved','changes_required','rejected_amended') then raise exception 'Invalid DM decision'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and task_type='PLAN_APPRAISAL_MANAGER_REVIEW' and status in ('accepted','in_progress');
  if p_decision='changes_required' then
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
  return v_d;
end;$$;

create or replace function epas_gm_plan_decision(p_drawing_id uuid,p_decision text,p_note text)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_des uuid;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may approve plan appraisal'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.status <> 'pending_gm_approval' then raise exception 'Drawing is not awaiting GM approval'; end if;
  if p_decision not in ('approved','send_to_designer') then raise exception 'Invalid GM plan decision'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid() where entity_type='plan_drawing' and entity_id=p_drawing_id and to_user_id=auth.uid() and status in ('pending','accepted','in_progress');
  if p_decision='approved' then
    update plan_drawings set status='approved',approved_by=auth.uid(),approved_at=now(),updated_at=now() where id=p_drawing_id returning * into v_d;
    update plan_revisions set status=case when revision_no=v_d.current_revision then 'approved' else 'superseded' end,reviewed_at=now() where drawing_id=v_d.id;
    insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
    values(v_d.project_id,'plan_drawing',v_d.id,'GM_APPROVED','pending_gm_approval','approved',auth.uid(),p_note);
    return v_d;
  end if;
  select designer_id into v_des from plan_drawings where id=p_drawing_id;
  if v_des is null then raise exception 'Drawing has no Designer assigned; correction cannot be routed'; end if;
  update plan_drawings set status='designer_response',updated_at=now() where id=p_drawing_id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_DESIGNER_RESPONSE',v_des,p_note,'plan_drawing',v_d.id,null,'high');
  return v_d;
end;$$;

-- Designer revision always returns to DM first.
create or replace function epas_designer_submit_revision(p_drawing_id uuid,p_file_name text,p_storage_path text,p_note text)
returns plan_drawings language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_rev int;
begin
  if not epas_has_role('designer') then raise exception 'Only Designer may submit revision'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.designer_id <> auth.uid() then raise exception 'Drawing belongs to another designer'; end if;
  v_rev := v_d.current_revision + 1;
  insert into plan_revisions(drawing_id,revision_no,file_name,storage_path,submitted_by,submission_note,status)
  values(v_d.id,v_rev,p_file_name,p_storage_path,auth.uid(),p_note,'submitted');
  update plan_drawings set current_revision=v_rev,revision=v_rev,status='submitted',updated_at=now(),current_file_name=p_file_name where id=v_d.id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_REVISION_DM_REVIEW',v_d.manager_id,'New drawing revision '||v_rev||' submitted by Designer. DM must review the new version before engineer reallocation.','plan_drawing',v_d.id,null,'high');
  return v_d;
end;$$;


-- ---------------------------------------------------------------------------
-- Secure task state transitions. UI may only act on tasks assigned to auth.uid().
-- ---------------------------------------------------------------------------
create or replace function epas_accept_task(p_task_id uuid)
returns workflow_tasks language plpgsql security definer set search_path=public as $$
declare v workflow_tasks;
begin
  update workflow_tasks set status='accepted',accepted_at=now()
  where id=p_task_id and to_user_id=auth.uid() and status='pending'
  returning * into v;
  if v.id is null then raise exception 'Task is not pending or is assigned to another user'; end if;
  return v;
end;$$;

create or replace function epas_start_task(p_task_id uuid)
returns workflow_tasks language plpgsql security definer set search_path=public as $$
declare v workflow_tasks;
begin
  update workflow_tasks set status='in_progress'
  where id=p_task_id and to_user_id=auth.uid() and status in ('pending','accepted')
  returning * into v;
  if v.id is null then raise exception 'Task cannot be started'; end if;
  return v;
end;$$;

create or replace function epas_complete_task(p_task_id uuid,p_note text default '')
returns workflow_tasks language plpgsql security definer set search_path=public as $$
declare v workflow_tasks;
begin
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where id=p_task_id and to_user_id=auth.uid() and status in ('accepted','in_progress')
  returning * into v;
  if v.id is null then raise exception 'Task cannot be completed'; end if;
  return v;
end;$$;


-- ---------------------------------------------------------------------------
-- GM certificate issuance: final controlled action after approval gate.
-- ---------------------------------------------------------------------------
create or replace function epas_issue_certificate(p_rfi_id uuid,p_cert_type text,p_validity_months integer)
returns certificates language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_vessel vessels; v_cert certificates; v_open int; v_prefix text; v_number text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may issue certificates'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.status not in ('approved_no_observations','approved_with_observations') then raise exception 'RFI is not eligible for certificate issuance'; end if;
  select * into v_vessel from vessels where id=v_rfi.vessel_id;
  select count(*) into v_open from observations where rfi_id=p_rfi_id and status='open';
  if v_open > 0 and p_cert_type <> 'interim_certificate' then raise exception 'Open observations require an Interim Certificate'; end if;
  if v_open = 0 and p_cert_type = 'interim_certificate' then raise exception 'No open observations; issue the full certificate'; end if;
  if p_validity_months <= 0 then raise exception 'Validity must be positive'; end if;
  v_prefix := case p_cert_type when 'class_certificate' then 'CC' when 'interim_certificate' then 'ICC' when 'nsc_certificate' then 'NCC' else null end;
  if v_prefix is null then raise exception 'Invalid certificate type'; end if;
  v_number := v_prefix||'-'||to_char(current_date,'YYYY')||'-'||upper(replace(coalesce(v_rfi.rfi_code,'RFI'),' ','-'));
  if exists(select 1 from certificates where cert_number=v_number) then v_number := v_number||'-'||substr(gen_random_uuid()::text,1,6); end if;
  insert into certificates(vessel_id,project_id,rfi_id,cert_type,cert_number,issue_date,expiry_date,status,pending_observations,issued_by)
  values(v_vessel.id,v_rfi.project_id,v_rfi.id,p_cert_type,v_number,current_date,(current_date + make_interval(months=>p_validity_months))::date,'active',
    coalesce((select jsonb_agg(description) from observations where rfi_id=p_rfi_id and status='open'),'[]'::jsonb),auth.uid()) returning * into v_cert;
  update rfis set status='certificate_issued',updated_at=now() where id=p_rfi_id;
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note)
  values(v_rfi.project_id,'rfi',p_rfi_id,'CERTIFICATE_ISSUED',v_rfi.status,'certificate_issued',auth.uid(),v_number);
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  select pm.user_id,'Certificate issued',v_number||' has been issued for project '||v_rfi.project_id::text,v_rfi.project_id,'certificates','certificate','success','rfi',p_rfi_id
  from project_members pm where pm.project_id=v_rfi.project_id and pm.active and pm.user_id <> auth.uid();
  return v_cert;
end;$$;

-- ---------------------------------------------------------------------------
-- RLS: deny-by-default for production workflow tables. GM sees project data;
-- other users only see their project membership/tasks/assigned records.
-- ---------------------------------------------------------------------------
alter table notification_outbox enable row level security;
alter table project_members enable row level security;
alter table workflow_events enable row level security;
alter table resource_authorizations enable row level security;
alter table resource_competencies enable row level security;
alter table resource_availability_calendar enable row level security;
alter table plan_revisions enable row level security;
alter table corrective_actions enable row level security;
alter table workflow_escalations enable row level security;
alter table project_milestones enable row level security;

-- Drop broad policies created by the earlier upgrade migration where names match.
do $$ declare r record; begin
  for r in select schemaname,tablename,policyname from pg_policies where schemaname='public' and policyname in (
    'plan_drawings_authenticated','plan_obs_authenticated','plan_events_authenticated','tasks_own','tasks_insert_actor','tasks_update_recipient','notifications_insert_authenticated'
  ) loop execute format('drop policy if exists %I on %I.%I',r.policyname,r.schemaname,r.tablename); end loop;
end $$;

create policy notification_outbox_gm_select on notification_outbox for select to authenticated using (epas_has_role('gm'));

create policy project_members_select on project_members for select to authenticated using (user_id=auth.uid() or epas_has_role('gm'));
create policy workflow_events_select on workflow_events for select to authenticated using (epas_is_project_member(project_id));
create policy auth_select_scoped on resource_authorizations for select to authenticated using (user_id=auth.uid() or epas_has_role('gm') or epas_has_role('dm'));
create policy comp_select_scoped on resource_competencies for select to authenticated using (user_id=auth.uid() or epas_has_role('gm') or epas_has_role('dm'));
create policy avail_select_scoped on resource_availability_calendar for select to authenticated using (user_id=auth.uid() or epas_has_role('gm') or epas_has_role('dm'));
create policy plan_revisions_select on plan_revisions for select to authenticated using (exists(select 1 from plan_drawings d where d.id=plan_revisions.drawing_id and epas_is_project_member(d.project_id)));
create policy corrective_select on corrective_actions for select to authenticated using (assigned_to=auth.uid() or assigned_by=auth.uid() or epas_has_role('gm'));
create policy escalation_select on workflow_escalations for select to authenticated using (raised_by=auth.uid() or assigned_to=auth.uid() or epas_has_role('gm'));
create policy milestone_select on project_milestones for select to authenticated using (epas_is_project_member(project_id));

-- Restrict task reads to recipient/sender/project GM. Writes are performed through
-- SECURITY DEFINER RPCs, not direct table mutation from the browser.
create policy workflow_tasks_select_prod on workflow_tasks for select to authenticated using (
  to_user_id=auth.uid() or from_user_id=auth.uid() or epas_has_role('gm')
);
create policy notifications_select_prod on notifications for select to authenticated using (user_id=auth.uid());
create policy notifications_update_prod on notifications for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());

-- Base tables: project membership filtering for the two production roles.
create policy projects_select_prod on projects for select to authenticated using (created_by=auth.uid() or epas_is_project_member(id));
create policy vessels_select_prod on vessels for select to authenticated using (epas_is_project_member(project_id));
create policy team_select_prod on team_assignments for select to authenticated using (epas_is_project_member(project_id));
create policy stakeholder_select_prod on stakeholders for select to authenticated using (epas_is_project_member(project_id));
create policy rfis_select_prod on rfis for select to authenticated using (epas_is_project_member(project_id));
create policy observations_select_prod on observations for select to authenticated using (exists(select 1 from rfis r where r.id=observations.rfi_id and epas_is_project_member(r.project_id)));
create policy plan_drawings_select_prod on plan_drawings for select to authenticated using (epas_is_project_member(project_id));
create policy plan_obs_select_prod on plan_appraisal_observations for select to authenticated using (exists(select 1 from plan_drawings d where d.id=plan_appraisal_observations.drawing_id and epas_is_project_member(d.project_id)));

-- RPC execute permissions
revoke all on function epas_create_project(jsonb) from public;
revoke all on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) from public;
revoke all on function epas_gm_handover_rfi(uuid,uuid) from public;
revoke all on function epas_dm_assign_surveyor(uuid,uuid,date) from public;
revoke all on function epas_dm_forward_survey(uuid,text) from public;
revoke all on function epas_gm_decide_rfi(uuid,text,text) from public;
revoke all on function epas_dm_issue_corrective_action(uuid,uuid,text,date) from public;
revoke all on function epas_assignee_submit_corrective(uuid,text) from public;
revoke all on function epas_dm_create_followup_rfi(uuid) from public;
revoke all on function epas_submit_survey_report(uuid,text,jsonb) from public;
revoke all on function epas_dm_escalate(uuid,text,uuid,text,text,text) from public;
revoke all on function epas_gm_assign_plan_manager(uuid,uuid) from public;
revoke all on function epas_dm_assign_engineer(uuid,uuid) from public;
revoke all on function epas_engineer_submit_review(uuid,text,text) from public;
revoke all on function epas_dm_review_plan(uuid,text,text) from public;
revoke all on function epas_gm_plan_decision(uuid,text,text) from public;
revoke all on function epas_designer_submit_revision(uuid,text,text,text) from public;
revoke all on function epas_accept_task(uuid) from public;
revoke all on function epas_start_task(uuid) from public;
revoke all on function epas_complete_task(uuid,text) from public;
revoke all on function epas_issue_certificate(uuid,text,integer) from public;
grant execute on function epas_my_profile() to authenticated;
grant execute on function epas_has_role(text) to authenticated;
grant execute on function epas_is_project_member(uuid) to authenticated;
grant execute on function epas_eligible_resources(text,text,date) to authenticated;
grant execute on function epas_create_project(jsonb) to authenticated;
grant execute on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) to authenticated;
grant execute on function epas_gm_handover_rfi(uuid,uuid) to authenticated;
grant execute on function epas_dm_assign_surveyor(uuid,uuid,date) to authenticated;
grant execute on function epas_submit_survey_report(uuid,text,jsonb) to authenticated;
grant execute on function epas_dm_forward_survey(uuid,text) to authenticated;
grant execute on function epas_gm_decide_rfi(uuid,text,text) to authenticated;
grant execute on function epas_dm_issue_corrective_action(uuid,uuid,text,date) to authenticated;
grant execute on function epas_assignee_submit_corrective(uuid,text) to authenticated;
grant execute on function epas_dm_create_followup_rfi(uuid) to authenticated;
grant execute on function epas_dm_escalate(uuid,text,uuid,text,text,text) to authenticated;
grant execute on function epas_gm_assign_plan_manager(uuid,uuid) to authenticated;
grant execute on function epas_dm_assign_engineer(uuid,uuid) to authenticated;
grant execute on function epas_engineer_submit_review(uuid,text,text) to authenticated;
grant execute on function epas_dm_review_plan(uuid,text,text) to authenticated;
grant execute on function epas_gm_plan_decision(uuid,text,text) to authenticated;
grant execute on function epas_designer_submit_revision(uuid,text,text,text) to authenticated;
grant execute on function epas_accept_task(uuid) to authenticated;
grant execute on function epas_start_task(uuid) to authenticated;
grant execute on function epas_complete_task(uuid,text) to authenticated;
grant execute on function epas_issue_certificate(uuid,text,integer) to authenticated;

comment on schema public is 'EPAS production workflow: GM and DM actions are authenticated, role-controlled and persisted in PostgreSQL; no client-side demo state is required.';

-- ---------------------------------------------------------------------------
-- Private Storage bucket for controlled project documents.
-- Run this only if the project has not already created the bucket in Storage.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id,name,public)
values ('project-documents','project-documents',false)
on conflict (id) do update set public=false;

do $$ begin
  create policy epas_project_documents_select on storage.objects
    for select to authenticated
    using (bucket_id='project-documents' and (split_part(name,'/',1)='projects' and split_part(name,'/',2) ~* '^[0-9a-f-]{36}$' and epas_is_project_member(split_part(name,'/',2)::uuid)));
exception when duplicate_object then null; end $$;

do $$ begin
  create policy epas_project_documents_insert on storage.objects
    for insert to authenticated
    with check (bucket_id='project-documents' and (split_part(name,'/',1)='projects' and split_part(name,'/',2) ~* '^[0-9a-f-]{36}$' and epas_is_project_member(split_part(name,'/',2)::uuid)));
exception when duplicate_object then null; end $$;

do $$ begin
  create policy epas_project_documents_update on storage.objects
    for update to authenticated
    using (bucket_id='project-documents' and (split_part(name,'/',1)='projects' and split_part(name,'/',2) ~* '^[0-9a-f-]{36}$' and epas_is_project_member(split_part(name,'/',2)::uuid)))
    with check (bucket_id='project-documents' and (split_part(name,'/',1)='projects' and split_part(name,'/',2) ~* '^[0-9a-f-]{36}$' and epas_is_project_member(split_part(name,'/',2)::uuid)));
exception when duplicate_object then null; end $$;

-- Controlled document metadata visibility.
alter table documents enable row level security;
do $$ begin
  create policy documents_select_prod on documents for select to authenticated
    using (epas_is_project_member(project_id));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy documents_insert_gm on documents for insert to authenticated
    with check (epas_has_role('gm') and uploaded_by=auth.uid() and epas_is_project_member(project_id));
exception when duplicate_object then null; end $$;

-- Profile privacy: GM/DM can resolve internal assignees; everyone can resolve self.
alter table profiles enable row level security;
do $$ begin
  create policy profiles_select_prod on profiles for select to authenticated
    using (id=auth.uid() or epas_has_role('gm') or (epas_has_role('dm') and role in ('dm','engineer','surveyor')));
exception when duplicate_object then null; end $$;
