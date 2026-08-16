-- EPAS Production v1.5
-- Critical workflow completion: released-document workflow, certificate lifecycle,
-- survey observation lifecycle, SLA/business-day engine, resource conflict windows,
-- controlled corrective evidence, designer revision traceability, project closure,
-- escalation action linkage and document access audit.
-- Apply AFTER production_v1_4_1.sql.

create extension if not exists pgcrypto;

-- ================================================================
-- A. Controlled stakeholder document release + access audit
-- ================================================================
create table if not exists document_releases (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  audience_role text not null check (audience_role in ('designer','owner','ship_management','shipyard','all_stakeholders')),
  status text not null default 'released' check (status in ('released','withdrawn')),
  release_note text,
  released_by uuid not null references profiles(id),
  released_at timestamptz not null default now(),
  withdrawn_by uuid references profiles(id),
  withdrawn_at timestamptz
);
create unique index if not exists uq_document_releases_active
  on document_releases(document_id,audience_role) where status='released';
create index if not exists idx_document_releases_project on document_releases(project_id,status,released_at desc);

create table if not exists document_access_audit (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  actor_id uuid not null references profiles(id),
  actor_role text not null,
  action text not null check (action in ('view','download','release','withdraw')),
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists idx_document_access_audit_doc on document_access_audit(document_id,created_at desc);
create index if not exists idx_document_access_audit_project on document_access_audit(project_id,created_at desc);

-- ================================================================
-- B. Document provenance / integrity
-- ================================================================
alter table documents add column if not exists sha256 text;
alter table documents add column if not exists mime_type text;
alter table documents add column if not exists file_size_bytes bigint;
alter table documents add column if not exists release_status text not null default 'internal';
alter table documents add column if not exists stakeholder_visible boolean not null default false;

alter table plan_revisions add column if not exists parent_revision_id uuid references plan_revisions(id);
alter table plan_revisions add column if not exists correction_task_id uuid references workflow_tasks(id);
alter table plan_revisions add column if not exists source_decision_id uuid;
alter table plan_revisions add column if not exists sha256 text;
alter table plan_revisions add column if not exists mime_type text;
alter table plan_revisions add column if not exists file_size_bytes bigint;

alter table plan_appraisal_observations add column if not exists rule_reference text;
alter table plan_appraisal_observations add column if not exists drawing_reference text;
alter table plan_appraisal_observations add column if not exists response_by uuid references profiles(id);
alter table plan_appraisal_observations add column if not exists closure_note text;
alter table plan_appraisal_observations add column if not exists closed_by uuid references profiles(id);
alter table plan_appraisal_observations add column if not exists closed_at timestamptz;

-- ================================================================
-- C. Survey report / observation lifecycle
-- ================================================================
alter table survey_reports add column if not exists survey_date date;
alter table survey_reports add column if not exists location text;
alter table survey_reports add column if not exists attendance text;
alter table survey_reports add column if not exists evidence_path text;
alter table survey_reports add column if not exists declaration text;
alter table survey_reports add column if not exists evidence_sha256 text;
alter table survey_reports add column if not exists evidence_size_bytes bigint;
alter table survey_reports add column if not exists mime_type text;

alter table observations add column if not exists location text;
alter table observations add column if not exists rule_reference text;
alter table observations add column if not exists deficiency_category text;
alter table observations add column if not exists responsible_party text;
alter table observations add column if not exists target_date date;
alter table observations add column if not exists corrective_action text;
alter table observations add column if not exists evidence_path text;
alter table observations add column if not exists evidence_sha256 text;
alter table observations add column if not exists cleared_by uuid references profiles(id);
alter table observations add column if not exists clearance_note text;
alter table observations add column if not exists verified_at timestamptz;
create index if not exists idx_observations_rfi_status on observations(rfi_id,status);

-- ================================================================
-- D. Controlled corrective evidence
-- ================================================================
alter table corrective_actions add column if not exists completion_note text;
alter table corrective_actions add column if not exists evidence_sha256 text;
alter table corrective_actions add column if not exists evidence_mime_type text;
alter table corrective_actions add column if not exists evidence_size_bytes bigint;
alter table corrective_actions add column if not exists rejected_note text;
alter table corrective_actions add column if not exists verified_note text;

-- ================================================================
-- E. SLA / working-day engine
-- ================================================================
create table if not exists sla_policies (
  id uuid primary key default gen_random_uuid(),
  task_type text not null unique,
  business_days integer not null check (business_days > 0),
  warning_business_days_remaining numeric(6,2) not null default 1,
  priority text not null default 'normal',
  active boolean not null default true
);

insert into sla_policies(task_type,business_days,warning_business_days_remaining,priority) values
('PLAN_APPRAISAL_GM_INTAKE',1,0.5,'high'),
('PLAN_APPRAISAL_MANAGER_HANDOVER',1,0.5,'high'),
('PLAN_APPRAISAL_REVISION_DM_REVIEW',2,1,'high'),
('PLAN_APPRAISAL_ENGINEERING',5,1,'high'),
('PLAN_APPRAISAL_ENGINEER_FEEDBACK',3,1,'high'),
('PLAN_APPRAISAL_MANAGER_REVIEW',2,1,'high'),
('PLAN_APPRAISAL_DESIGNER_RESPONSE',5,1,'high'),
('PLAN_APPRAISAL_GM_DESIGN_DECISION',2,1,'high'),
('GM_PLAN_FINAL_APPROVAL',2,1,'high'),
('SURVEY_RFI_HANDOVER',1,0.5,'high'),
('SURVEY_EXECUTION',3,1,'high'),
('SURVEY_DM_REVIEW',2,1,'high'),
('GM_SURVEY_FINAL_APPROVAL',2,1,'high'),
('CORRECTIVE_ACTION_EXECUTION',5,1,'high'),
('DM_CORRECTIVE_ACTION_VERIFY',2,1,'high'),
('FOLLOW_UP_RFI_DM_SCOPE_REVIEW',1,0.5,'high'),
('GM_ESCALATION_REVIEW',1,0.5,'critical'),
('GM_ESCALATION_RETURN',1,0.5,'high'),
('DM_GM_FINAL_APPROVAL_ACK',1,0.5,'normal')
on conflict (task_type) do update set
  business_days=excluded.business_days,
  warning_business_days_remaining=excluded.warning_business_days_remaining,
  priority=excluded.priority;

create or replace function epas_add_business_days(p_start timestamptz,p_days integer)
returns timestamptz
language plpgsql immutable as $$
declare v_ts timestamptz := p_start; v_left integer := greatest(coalesce(p_days,0),0);
begin
  while v_left > 0 loop
    v_ts := v_ts + interval '1 day';
    if extract(isodow from v_ts) between 1 and 5 then v_left := v_left - 1; end if;
  end loop;
  return v_ts;
end;$$;

create or replace function epas_task_sla_days(p_task_type text)
returns integer
language sql stable security definer set search_path=public as $$
  select coalesce((select business_days from sla_policies where task_type=p_task_type and active),3);
$$;

alter table workflow_tasks add column if not exists warning_at timestamptz;
alter table workflow_tasks add column if not exists planned_start_at timestamptz;
alter table workflow_tasks add column if not exists planned_end_at timestamptz;

-- Rebuild generic task creator: secure internal workflow primitive, not a client endpoint.
create or replace function epas_create_task(
  p_project_id uuid,p_task_type text,p_to_user uuid,p_note text,
  p_entity_type text,p_entity_id uuid,p_due_at timestamptz default null,p_priority text default 'normal'
) returns workflow_tasks
language plpgsql security definer set search_path=public as $$
declare v_task workflow_tasks; v_from_role text; v_to_role text; v_due timestamptz; v_sla int; v_warn timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for this project'; end if;
  select role into v_from_role from profiles where id=auth.uid();
  select role into v_to_role from profiles where id=p_to_user;
  if v_to_role is null then raise exception 'Recipient profile not found'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=p_to_user and pm.active)
     and not (v_to_role='gm') then
    raise exception 'Workflow recipient is not an active member of the project';
  end if;
  if p_task_type in ('PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK') and v_to_role<>'engineer' then raise exception 'Plan engineering tasks require Engineer'; end if;
  if p_task_type in ('PLAN_APPRAISAL_MANAGER_HANDOVER','PLAN_APPRAISAL_MANAGER_REVIEW','PLAN_APPRAISAL_REVISION_DM_REVIEW',
                     'DM_CORRECTIVE_ACTION_VERIFY','FOLLOW_UP_RFI_DM_SCOPE_REVIEW','GM_ESCALATION_RETURN') and v_to_role<>'dm' then
    raise exception 'Workflow task requires Department Manager';
  end if;
  if p_task_type='SURVEY_EXECUTION' and v_to_role<>'surveyor' then raise exception 'Survey execution requires Surveyor'; end if;
  if p_task_type='PLAN_APPRAISAL_DESIGNER_RESPONSE' and v_to_role<>'designer' then raise exception 'Designer response requires Designer'; end if;
  if p_task_type='CORRECTIVE_ACTION_EXECUTION' and v_to_role not in ('surveyor','ship_management') then raise exception 'Corrective action requires Surveyor or Ship Management'; end if;
  if p_task_type in ('GM_PLAN_FINAL_APPROVAL','PLAN_APPRAISAL_GM_DESIGN_DECISION','GM_SURVEY_FINAL_APPROVAL','GM_ESCALATION_REVIEW') and v_to_role<>'gm' then
    raise exception 'Workflow task requires GM';
  end if;
  v_sla := epas_task_sla_days(p_task_type);
  v_due := coalesce(p_due_at,epas_add_business_days(now(),v_sla));
  v_warn := epas_add_business_days(now(),greatest(v_sla-1,0));
  insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,entity_type,entity_id,due_at,priority,sla_minutes,planned_start_at,planned_end_at,warning_at)
  values(p_project_id,p_task_type,auth.uid(),p_to_user,'pending',p_note,p_entity_type,p_entity_id,v_due,
         p_priority,v_sla*8*60,now(),v_due,v_warn)
  returning * into v_task;
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id,due_at)
  values(p_to_user,replace(p_task_type,'_',' '),coalesce(p_note,'New workflow action requires your attention.'),p_project_id,
         case when p_entity_type='plan_drawing' then 'plan_appraisal' when p_entity_type='rfi' then 'survey_rfi' else 'dm_dashboard' end,
         'task',case when p_priority in ('high','critical') then p_priority else 'info' end,p_entity_type,p_entity_id,v_due);
  insert into notification_outbox(project_id,recipient_email,subject,body)
  select p_project_id,p.email,'EPAS workflow action: '||replace(p_task_type,'_',' '),
         coalesce(p_note,'A new workflow action requires your attention.')||E'\nDue: '||to_char(v_due,'DD Mon YYYY HH24:MI TZ')
  from profiles p where p.id=p_to_user and coalesce(p.email,'')<>'';
  perform epas_audit(p_project_id,'WORKFLOW_TASK_CREATED','workflow_task',v_task.id,null,'pending',p_note,
                     jsonb_build_object('task_type',p_task_type,'from_role',v_from_role,'to_role',v_to_role,'due_at',v_due,'sla_business_days',v_sla));
  return v_task;
end;$$;

-- ================================================================
-- F. Resource conflict engine
-- ================================================================
create or replace function epas_project_eligible_resources_v15(
  p_project_id uuid,p_role text,p_discipline text,
  p_window_start date default current_date,p_window_end date default current_date
)
returns table(
  user_id uuid, full_name text, authorization_level text, workload_pct numeric,
  availability_status text, open_tasks integer, overdue_tasks integer,
  due_7d integer, overlapping_tasks integer, eligibility_note text
)
language sql security definer set search_path=public stable as $$
  with base as (
    select p.id,p.full_name,a.authorization_level,
           coalesce(av.workload_pct,0) workload_pct,
           coalesce(av.status,'available') availability_status
    from profiles p
    join lateral (
      select ra.* from resource_authorizations ra
      where ra.user_id=p.id and ra.discipline=p_discipline and ra.active
        and ra.valid_from <= p_window_start and (ra.valid_until is null or ra.valid_until >= p_window_start)
      order by ra.authorization_level desc limit 1
    ) a on true
    join lateral (
      select rc.* from resource_competencies rc
      where rc.user_id=p.id and rc.discipline=p_discipline and rc.status='competent'
        and rc.assessed_on <= p_window_start and (rc.valid_until is null or rc.valid_until >= p_window_start)
      order by rc.assessed_on desc limit 1
    ) c on true
    left join resource_availability_calendar av on av.user_id=p.id and av.work_date=p_window_start
    where p.role=p_role and coalesce(av.status,'available') in ('available','partial')
      and coalesce(av.workload_pct,0) < 90
  )
  select b.id,b.full_name,b.authorization_level,b.workload_pct,b.availability_status,
         count(t.id) filter(where t.status not in ('completed','returned')),
         count(t.id) filter(where t.status not in ('completed','returned') and t.due_at<now()),
         count(t.id) filter(where t.status not in ('completed','returned') and t.due_at between now() and now()+interval '7 days'),
         count(t.id) filter(where t.status not in ('completed','returned')
           and coalesce(t.planned_start_at,t.created_at) <= p_window_end::timestamptz
           and coalesce(t.planned_end_at,t.due_at) >= p_window_start::timestamptz),
         case when count(t.id) filter(where t.status not in ('completed','returned')
           and coalesce(t.planned_start_at,t.created_at) <= p_window_end::timestamptz
           and coalesce(t.planned_end_at,t.due_at) >= p_window_start::timestamptz) > 2
           then 'Not eligible: overlapping workload conflict'
           else 'Eligible: authorization + competency + availability + workload + conflict check' end
  from base b
  left join workflow_tasks t on t.to_user_id=b.id and t.status not in ('completed','returned')
  group by b.id,b.full_name,b.authorization_level,b.workload_pct,b.availability_status;
$$;

create or replace function epas_resource_workload(p_project_id uuid)
returns table(
  user_id uuid,full_name text,role text,discipline text,workload_pct numeric,capacity_pct numeric,
  assigned_tasks integer,overdue_tasks integer,due_7d integer,same_due_date_conflicts integer,
  overlapping_tasks integer,availability_status text
)
language sql security definer set search_path=public stable as $$
  select pm.user_id,p.full_name,pm.role,pm.discipline,
    coalesce(av.workload_pct,0),100-coalesce(av.workload_pct,0),
    count(t.id) filter(where t.status not in ('completed','returned')),
    count(t.id) filter(where t.status not in ('completed','returned') and t.due_at<now()),
    count(t.id) filter(where t.status not in ('completed','returned') and t.due_at between now() and now()+interval '7 days'),
    count(t.id) filter(where t.status not in ('completed','returned') and t.due_at::date in (
      select x.due_at::date from workflow_tasks x where x.to_user_id=pm.user_id and x.status not in ('completed','returned') and x.id<>t.id
    )),
    count(t.id) filter(where t.status not in ('completed','returned') and
      coalesce(t.planned_start_at,t.created_at) <= now()+interval '7 days' and
      coalesce(t.planned_end_at,t.due_at) >= now()),
    coalesce(av.status,'available')
  from project_members pm
  join profiles p on p.id=pm.user_id
  left join resource_availability_calendar av on av.user_id=pm.user_id and av.work_date=current_date
  left join workflow_tasks t on t.to_user_id=pm.user_id and t.project_id=p_project_id
  where pm.project_id=p_project_id and pm.active and pm.role in ('dm','engineer','surveyor')
  group by pm.user_id,p.full_name,pm.role,pm.discipline,av.workload_pct,av.status;
$$;

-- ================================================================
-- G. Full survey observation/report lifecycle
-- ================================================================
create or replace function epas_submit_survey_report(
  p_rfi_id uuid,p_report_note text,p_observations jsonb default '[]'::jsonb,
  p_evidence_path text default null,p_evidence_sha256 text default null,
  p_mime_type text default null,p_size_bytes bigint default null,
  p_location text default null,p_survey_date date default current_date,
  p_attendance text default null,p_declaration text default null
) returns survey_reports
language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_report survey_reports; v_item jsonb; v_dm uuid; v_code text;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may submit survey report'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_surveyor_id<>auth.uid() then raise exception 'RFI is assigned to another surveyor'; end if;
  if v_rfi.status not in ('survey_in_progress','sent_back_for_rework') then raise exception 'RFI is not in a survey-execution state'; end if;
  if coalesce(trim(p_report_note),'')='' then raise exception 'Survey report is required'; end if;
  if coalesce(trim(p_declaration),'')='' then raise exception 'Surveyor declaration is required'; end if;
  if p_evidence_path is not null and position(('projects/'||v_rfi.project_id::text||'/survey-reports/'||v_rfi.id::text||'/') in p_evidence_path)<>1 then
    raise exception 'Survey evidence must use the controlled survey-report path';
  end if;
  insert into survey_reports(
    rfi_id,surveyor_id,report_note,survey_date,location,attendance,evidence_path,
    declaration,evidence_sha256,evidence_size_bytes,mime_type
  )
  values(
    p_rfi_id,auth.uid(),p_report_note,p_survey_date,p_location,p_attendance,p_evidence_path,
    p_declaration,p_evidence_sha256,p_size_bytes,p_mime_type
  ) returning * into v_report;

  for v_item in select * from jsonb_array_elements(coalesce(p_observations,'[]'::jsonb)) loop
    v_code:=coalesce(nullif(v_item->>'obs_code',''),'OBS-'||to_char(current_date,'YYYYMMDD')||'-'||substr(gen_random_uuid()::text,1,8));
    insert into observations(
      rfi_id,obs_code,description,severity,status,raised_by,location,rule_reference,
      deficiency_category,responsible_party,target_date,corrective_action
    )
    values(
      p_rfi_id,v_code,coalesce(v_item->>'description',''),coalesce(v_item->>'severity','Minor'),'open',auth.uid(),
      nullif(v_item->>'location',''),nullif(v_item->>'rule_reference',''),
      nullif(v_item->>'deficiency_category',''),nullif(v_item->>'responsible_party',''),
      nullif(v_item->>'target_date','')::date,nullif(v_item->>'corrective_action','')
    );
  end loop;

  update rfis set status='observations_logged',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  v_dm:=v_rfi.assigned_dm_id;
  perform epas_create_task(v_rfi.project_id,'SURVEY_DM_REVIEW',v_dm,
    'Survey report submitted. Review the report, evidence and complete observation register before forwarding to GM.',
    'rfi',p_rfi_id,null,'high');
  perform epas_audit(v_rfi.project_id,'SURVEY_REPORT_SUBMITTED','rfi',p_rfi_id,'survey_in_progress','observations_logged',
    'Controlled survey report submitted',
    jsonb_build_object('observation_count',jsonb_array_length(coalesce(p_observations,'[]'::jsonb)),
                       'evidence_sha256',p_evidence_sha256,'evidence_size_bytes',p_size_bytes));
  return v_report;
end;$$;

grant execute on function epas_submit_survey_report(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;

create or replace function epas_clear_survey_observation(p_observation_id uuid,p_note text)
returns observations
language plpgsql security definer set search_path=public as $$
declare v observations; v_project uuid;
begin
  select o.* into v from observations o where o.id=p_observation_id for update;
  if v.id is null then raise exception 'Survey observation not found'; end if;
  select r.project_id into v_project from rfis r where r.id=v.rfi_id;
  if not (epas_has_role('dm') or epas_has_role('gm')) then raise exception 'Only DM or GM may verify survey observation closure'; end if;
  if not epas_is_project_member(v_project) then raise exception 'Not authorized for project'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Closure verification note is required'; end if;
  update observations set status='cleared',cleared_at=now(),cleared_by=auth.uid(),clearance_note=p_note,verified_at=now()
  where id=v.id returning * into v;
  perform epas_audit(v_project,'SURVEY_OBSERVATION_CLEARED','observation',v.id,'open','cleared',p_note,jsonb_build_object('obs_code',v.obs_code));
  return v;
end;$$;

-- ================================================================
-- H. Controlled corrective-action evidence
-- ================================================================
create or replace function epas_assignee_submit_corrective(
  p_action_id uuid,p_evidence_path text,p_evidence_sha256 text default null,
  p_mime_type text default null,p_size_bytes bigint default null,p_completion_note text default null
) returns corrective_actions
language plpgsql security definer set search_path=public as $$
declare v corrective_actions;
begin
  select * into v from corrective_actions where id=p_action_id for update;
  if v.assigned_to<>auth.uid() then raise exception 'Corrective action is assigned to another user'; end if;
  if v.status not in ('open','in_progress','rejected') then raise exception 'Corrective action cannot be submitted in current status'; end if;
  if coalesce(trim(p_evidence_path),'')='' then raise exception 'Controlled evidence path is required'; end if;
  if position(('projects/'||v.project_id::text||'/corrective-actions/'||v.id::text||'/') in p_evidence_path)<>1 then
    raise exception 'Evidence must be stored in the controlled corrective-action path';
  end if;
  update corrective_actions set status='submitted',evidence_path=p_evidence_path,evidence_sha256=p_evidence_sha256,
    evidence_mime_type=p_mime_type,evidence_size_bytes=p_size_bytes,completion_note=p_completion_note,submitted_at=now(),rejected_note=null
  where id=p_action_id returning * into v;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=coalesce(p_completion_note,'')
  where entity_type='corrective_action' and entity_id=p_action_id and to_user_id=auth.uid() and status in ('pending','accepted','in_progress');
  perform epas_create_task(v.project_id,'DM_CORRECTIVE_ACTION_VERIFY',v.assigned_by,'Corrective action submitted with controlled evidence for DM verification.','corrective_action',v.id,null,'high');
  perform epas_audit(v.project_id,'CORRECTIVE_ACTION_SUBMITTED','corrective_action',v.id,'in_progress','submitted',p_completion_note,jsonb_build_object('evidence_sha256',p_evidence_sha256,'evidence_size_bytes',p_size_bytes));
  return v;
end;$$;

-- ================================================================
-- I. Designer revision traceability
-- ================================================================
create or replace function epas_designer_submit_revision(
  p_drawing_id uuid,p_file_name text,p_storage_path text,p_note text,
  p_sha256 text default null,p_mime_type text default 'application/pdf',p_size_bytes bigint default null
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_rev int; v_parent uuid; v_task uuid; v_dec uuid;
begin
  if not epas_has_role('designer') then raise exception 'Only Designer may submit revision'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.designer_id<>auth.uid() then raise exception 'Drawing belongs to another Designer'; end if;
  if v_d.status not in ('designer_response','rejected') then raise exception 'Drawing is not awaiting Designer correction'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Revision response note is required'; end if;
  if p_storage_path <> ('projects/'||v_d.project_id::text||'/plan-appraisal/corrections/'||p_file_name) then
    raise exception 'Invalid controlled correction storage path';
  end if;
  select id into v_task from workflow_tasks
    where entity_type='plan_drawing' and entity_id=v_d.id
      and task_type='PLAN_APPRAISAL_DESIGNER_RESPONSE'
      and to_user_id=auth.uid() and status in ('pending','accepted','in_progress')
    order by created_at desc limit 1;
  if v_task is null then raise exception 'No active Designer correction task exists for this drawing'; end if;
  select id into v_parent from plan_revisions where drawing_id=v_d.id and revision_no=v_d.current_revision;
  select id into v_dec from project_decisions where entity_type='plan_drawing' and entity_id=v_d.id order by decision_at desc limit 1;
  v_rev:=v_d.current_revision+1;
  insert into plan_revisions(drawing_id,revision_no,file_name,storage_path,submitted_by,submission_note,status,parent_revision_id,correction_task_id,source_decision_id,sha256,mime_type,file_size_bytes)
  values(v_d.id,v_rev,p_file_name,p_storage_path,auth.uid(),p_note,'submitted',v_parent,v_task,v_dec,p_sha256,p_mime_type,p_size_bytes);
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note where id=v_task;
  update plan_drawings set current_revision=v_rev,revision=v_rev,status='revision_pending_dm',updated_at=now(),current_file_name=p_file_name where id=v_d.id returning * into v_d;
  update documents set version=v_rev,storage_path=p_storage_path,file_name=p_file_name,sha256=p_sha256,mime_type=p_mime_type,file_size_bytes=p_size_bytes,status='pending_review',release_status='internal',stakeholder_visible=false where id=v_d.document_id;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_REVISION_DM_REVIEW',v_d.manager_id,'Designer revision '||v_rev||' submitted. Review the revised version before engineer reallocation.','plan_drawing',v_d.id,null,'high');
  perform epas_audit(v_d.project_id,'DESIGNER_REVISION_SUBMITTED','plan_drawing',v_d.id,'designer_response','revision_pending_dm',
    p_note,jsonb_build_object('revision',v_rev,'parent_revision_id',v_parent,'source_decision_id',v_dec,'sha256',p_sha256));
  return v_d;
end;$$;

-- ================================================================
-- J. Stakeholder release workflow
-- ================================================================
create or replace function epas_release_document(
  p_document_id uuid,p_audience_roles text[],p_note text
) returns documents
language plpgsql security definer set search_path=public as $$
declare v_doc documents; v_role text; v_project uuid;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may release documents'; end if;
  select * into v_doc from documents where id=p_document_id for update;
  if v_doc.id is null then raise exception 'Document not found'; end if;
  v_project:=v_doc.project_id;
  if not epas_is_project_member(v_project) then raise exception 'Not authorized for project'; end if;
  if coalesce(array_length(p_audience_roles,1),0)=0 then raise exception 'At least one stakeholder audience is required'; end if;
  foreach v_role in array p_audience_roles loop
    if v_role not in ('designer','owner','ship_management','shipyard','all_stakeholders') then raise exception 'Invalid stakeholder audience'; end if;
    insert into document_releases(document_id,project_id,audience_role,status,release_note,released_by)
    values(v_doc.id,v_project,v_role,'released',p_note,auth.uid())
    on conflict (document_id,audience_role) where status='released' do update
      set release_note=excluded.release_note,released_by=auth.uid(),released_at=now(),withdrawn_by=null,withdrawn_at=null;
  end loop;
  update documents set stakeholder_visible=true,release_status='released',status='approved' where id=v_doc.id returning * into v_doc;
  insert into document_access_audit(document_id,project_id,actor_id,actor_role,action,metadata)
  values(v_doc.id,v_project,auth.uid(),(select role from profiles where id=auth.uid()),'release',jsonb_build_object('audiences',p_audience_roles,'note',p_note));
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note,metadata)
  values(v_project,'document',v_doc.id,'DOCUMENT_RELEASED','internal','released',auth.uid(),p_note,jsonb_build_object('audiences',p_audience_roles));
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  select pm.user_id,'Document released','Document '||v_doc.file_name||' has been released for stakeholder viewing.',v_project,'documents','document_release','info','document',v_doc.id
  from project_members pm
  where pm.project_id=v_project and pm.active
    and (
      'all_stakeholders'=any(p_audience_roles)
      or pm.role=any(p_audience_roles)
    );
  return v_doc;
end;$$;

create or replace function epas_withdraw_document_release(p_document_id uuid,p_note text)
returns documents
language plpgsql security definer set search_path=public as $$
declare v_doc documents;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may withdraw document release'; end if;
  select * into v_doc from documents where id=p_document_id for update;
  if v_doc.id is null then raise exception 'Document not found'; end if;
  update document_releases set status='withdrawn',withdrawn_by=auth.uid(),withdrawn_at=now()
  where document_id=v_doc.id and status='released';
  update documents set stakeholder_visible=false,release_status='withdrawn' where id=v_doc.id returning * into v_doc;
  insert into document_access_audit(document_id,project_id,actor_id,actor_role,action,metadata)
  values(v_doc.id,v_doc.project_id,auth.uid(),(select role from profiles where id=auth.uid()),'withdraw',jsonb_build_object('note',p_note));
  perform epas_audit(v_doc.project_id,'DOCUMENT_RELEASE_WITHDRAWN','document',v_doc.id,'released','withdrawn',p_note,'{}'::jsonb);
  return v_doc;
end;$$;

create or replace function epas_log_document_access(p_document_id uuid,p_action text)
returns void
language plpgsql security definer set search_path=public as $$
declare v_doc documents; v_role text;
begin
  if p_action not in ('view','download') then raise exception 'Invalid document access action'; end if;
  select * into v_doc from documents where id=p_document_id;
  if v_doc.id is null then raise exception 'Document not found'; end if;
  select role into v_role from profiles where id=auth.uid();
  if not epas_is_project_member(v_doc.project_id) then raise exception 'Not authorized for project'; end if;
  if v_role in ('owner','shipyard') and not (v_doc.stakeholder_visible and v_doc.release_status='released') then raise exception 'Document is not released for stakeholder viewing'; end if;
  insert into document_access_audit(document_id,project_id,actor_id,actor_role,action)
  values(v_doc.id,v_doc.project_id,auth.uid(),v_role,p_action);
end;$$;

-- ================================================================
-- K. Certificate lifecycle: Interim -> corrective closure -> Full
-- ================================================================
alter table certificates add column if not exists parent_certificate_id uuid references certificates(id);
alter table certificates add column if not exists superseded_by uuid references certificates(id);
alter table certificates add column if not exists finalized_at timestamptz;
alter table certificates add column if not exists finalization_note text;

create table if not exists certificate_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid not null references certificates(id) on delete cascade,
  event_type text not null,
  from_status text,
  to_status text,
  actor_id uuid not null references profiles(id),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists idx_certificate_lifecycle_cert on certificate_lifecycle_events(certificate_id,created_at desc);

create or replace function epas_finalize_interim_certificate(
  p_certificate_id uuid,p_validity_months integer,p_note text
) returns certificates
language plpgsql security definer set search_path=public as $$
declare v_old certificates; v_new certificates; v_open integer; v_rfi uuid; v_vessel uuid; v_project uuid; v_number text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may finalize an Interim Certificate'; end if;
  select * into v_old from certificates where id=p_certificate_id for update;
  if v_old.id is null then raise exception 'Certificate not found'; end if;
  if v_old.cert_type<>'interim_certificate' or v_old.status<>'active' then raise exception 'Certificate is not an active Interim Certificate'; end if;
  select count(*) into v_open from observations where rfi_id=v_old.rfi_id and status='open';
  if v_open>0 then raise exception 'All survey observations must be cleared before final certificate issuance'; end if;
  select rfi_id,vessel_id,project_id into v_rfi,v_vessel,v_project from certificates where id=v_old.id;
  v_number:='CC-'||to_char(current_date,'YYYY')||'-'||upper(replace((select rfi_code from rfis where id=v_rfi),' ','-'))||'-FINAL';
  if exists(select 1 from certificates where cert_number=v_number) then v_number:=v_number||'-'||substr(gen_random_uuid()::text,1,6); end if;
  insert into certificates(vessel_id,project_id,rfi_id,cert_type,cert_number,issue_date,expiry_date,status,pending_observations,issued_by,parent_certificate_id)
  values(v_vessel,v_project,v_rfi,'class_certificate',v_number,current_date,(current_date+make_interval(months=>p_validity_months))::date,'active','[]'::jsonb,auth.uid(),v_old.id)
  returning * into v_new;
  update certificates set status='superseded',superseded_by=v_new.id,finalized_at=now(),finalization_note=p_note where id=v_old.id;
  insert into certificate_lifecycle_events(certificate_id,event_type,from_status,to_status,actor_id,note)
  values(v_old.id,'FINALIZED','active','superseded',auth.uid(),p_note),
        (v_new.id,'ISSUED_FROM_INTERIM','none','active',auth.uid(),p_note);
  perform epas_audit(v_project,'INTERIM_FINALIZED','certificate',v_old.id,'active','superseded',p_note,jsonb_build_object('final_certificate_id',v_new.id));
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  select pm.user_id,'Final Class Certificate issued',v_new.cert_number||' replaces Interim Certificate '||v_old.cert_number,v_project,'certificates','certificate','success','certificate',v_new.id
  from project_members pm where pm.project_id=v_project and pm.active and pm.user_id<>auth.uid();
  return v_new;
end;$$;

-- ================================================================
-- L. Project closure / archive
-- ================================================================
alter table projects add column if not exists closed_at timestamptz;
alter table projects add column if not exists closed_by uuid references profiles(id);
alter table projects add column if not exists closure_note text;

create table if not exists project_closure_checks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  check_code text not null,
  check_title text not null,
  passed boolean not null,
  details text,
  checked_at timestamptz not null default now(),
  checked_by uuid not null references profiles(id)
);
create index if not exists idx_project_closure_checks_project on project_closure_checks(project_id,checked_at desc);

create table if not exists project_archives (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null unique references projects(id) on delete cascade,
  archived_by uuid not null references profiles(id),
  archived_at timestamptz not null default now(),
  retention_class text not null default 'classification-record',
  archive_note text
);

create or replace function epas_project_closure_check(p_project_id uuid)
returns table(check_code text,check_title text,passed boolean,details text)
language sql security definer set search_path=public stable as $$
  with x as (
    select
      (select count(*) from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id where d.project_id=p_project_id and o.status='open') plan_obs,
      (select count(*) from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id and o.status='open') survey_obs,
      (select count(*) from workflow_tasks t where t.project_id=p_project_id and t.status not in ('completed','returned')) tasks_open,
      (select count(*) from corrective_actions c where c.project_id=p_project_id and c.status not in ('verified','closed')) corrective_open,
      (select count(*) from workflow_escalations e where e.project_id=p_project_id and e.status in ('open','acknowledged')) esc_open,
      (select count(*) from project_milestones m where m.project_id=p_project_id and m.status not in ('completed','cancelled')) milestones_open,
      (select count(*) from certificates c where c.project_id=p_project_id and c.status='active') active_certs
  )
  select * from (
    select 'PLAN_OBSERVATIONS'::text,'Open plan observations = 0'::text,(plan_obs=0),'Open: '||plan_obs::text from x
    union all select 'SURVEY_OBSERVATIONS','Open survey observations = 0',(survey_obs=0),'Open: '||survey_obs::text from x
    union all select 'WORKFLOW_TASKS','No open workflow tasks',(tasks_open=0),'Open: '||tasks_open::text from x
    union all select 'CORRECTIVE_ACTIONS','No unverified corrective actions',(corrective_open=0),'Open: '||corrective_open::text from x
    union all select 'ESCALATIONS','No open escalations',(esc_open=0),'Open: '||esc_open::text from x
    union all select 'MILESTONES','All project milestones completed/cancelled',(milestones_open=0),'Remaining: '||milestones_open::text from x
    union all select 'CERTIFICATE','At least one active certificate exists',(active_certs>0),'Active certificates: '||active_certs::text from x
  ) q;
$$;

create or replace function epas_close_project(p_project_id uuid,p_note text)
returns projects
language plpgsql security definer set search_path=public as $$
declare v projects; v_fail integer;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may close a project'; end if;
  select * into v from projects where id=p_project_id for update;
  if v.id is null then raise exception 'Project not found'; end if;
  if v.status<>'active' then raise exception 'Only active projects can be closed'; end if;
  select count(*) into v_fail from epas_project_closure_check(p_project_id) where not passed;
  delete from project_closure_checks where project_id=p_project_id and checked_by=auth.uid();
  insert into project_closure_checks(project_id,check_code,check_title,passed,details,checked_by)
  select p_project_id,check_code,check_title,passed,details,auth.uid() from epas_project_closure_check(p_project_id);
  if v_fail>0 then raise exception 'Project closure checklist has % failed item(s)',v_fail; end if;
  update projects set status='closed',closed_at=now(),closed_by=auth.uid(),closure_note=p_note,updated_at=now() where id=p_project_id returning * into v;
  insert into project_archives(project_id,archived_by,archive_note) values(p_project_id,auth.uid(),p_note)
    on conflict(project_id) do update set archived_by=auth.uid(),archived_at=now(),archive_note=excluded.archive_note;
  perform epas_audit(p_project_id,'PROJECT_CLOSED','project',p_project_id,'active','closed',p_note,'{}'::jsonb);
  return v;
end;$$;

-- ================================================================
-- M. Escalation action linkage
-- ================================================================
alter table workflow_escalations add column if not exists action_owner_id uuid references profiles(id);
alter table workflow_escalations add column if not exists action_due_at timestamptz;
alter table workflow_escalations add column if not exists linked_task_id uuid references workflow_tasks(id);

create or replace function epas_gm_escalation_decide(
  p_escalation_id uuid,p_decision text,p_note text,
  p_action_owner_id uuid default null,p_action_due_at timestamptz default null
) returns workflow_escalations
language plpgsql security definer set search_path=public as $$
declare v workflow_escalations; v_old text; v_dm uuid; v_task workflow_tasks;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may decide escalations'; end if;
  if p_decision not in ('acknowledge','return_to_dm','resolve','reject','assign_action') then raise exception 'Invalid escalation decision'; end if;
  if p_decision in ('return_to_dm','resolve','reject','assign_action') and coalesce(trim(p_note),'')='' then raise exception 'Decision note is required'; end if;
  select * into v from workflow_escalations where id=p_escalation_id for update;
  if v.id is null or v.assigned_to<>auth.uid() then raise exception 'Escalation not assigned to this GM'; end if;
  if v.status not in ('open','acknowledged') then raise exception 'Escalation is already closed'; end if;
  v_old:=v.status;
  if p_decision='acknowledge' then
    update workflow_escalations set status='acknowledged',acknowledged_at=now(),acknowledged_by=auth.uid(),decision='acknowledge',
      decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
  elsif p_decision='assign_action' then
    if p_action_owner_id is null or p_action_due_at is null then raise exception 'Action owner and due date are required'; end if;
    if not exists(select 1 from project_members where project_id=v.project_id and user_id=p_action_owner_id and active) then raise exception 'Action owner is not a project member'; end if;
    select * into v_task from epas_create_task(v.project_id,'GM_ESCALATION_ACTION',p_action_owner_id,p_note,v.entity_type,v.entity_id,p_action_due_at,'high');
    update workflow_escalations set status='acknowledged',acknowledged_at=coalesce(acknowledged_at,now()),acknowledged_by=auth.uid(),
      decision='assign_action',decision_by=auth.uid(),decision_at=now(),action_owner_id=p_action_owner_id,action_due_at=p_action_due_at,linked_task_id=v_task.id
      where id=v.id returning * into v;
  elsif p_decision='resolve' then
    update workflow_escalations set status='resolved',resolved_at=now(),resolved_note=p_note,decision='resolve',decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
  elsif p_decision='reject' then
    update workflow_escalations set status='rejected',resolved_at=now(),resolved_note=p_note,decision='reject',decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
  else
    select assigned_dm_id into v_dm from rfis where id=v.entity_id and v.entity_type='rfi';
    if v_dm is null then select manager_id into v_dm from plan_drawings where id=v.entity_id and v.entity_type='plan_drawing'; end if;
    if v_dm is null then select user_id into v_dm from project_members where project_id=v.project_id and role='dm' and active order by assigned_at limit 1; end if;
    if v_dm is null then raise exception 'No DM available for escalation return'; end if;
    update workflow_escalations set status='resolved',resolved_at=now(),resolved_note=p_note,decision='return_to_dm',decision_by=auth.uid(),decision_at=now() where id=v.id returning * into v;
    perform epas_create_task(v.project_id,'GM_ESCALATION_RETURN',v_dm,p_note,v.entity_type,v.entity_id,null,'high');
  end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_note
  where entity_type=v.entity_type and entity_id=v.entity_id and to_user_id=auth.uid()
    and task_type='GM_ESCALATION_REVIEW' and status in ('pending','accepted','in_progress');
  perform epas_audit(v.project_id,'GM_ESCALATION_DECISION','escalation',v.id,v_old,v.status,p_note,
    jsonb_build_object('decision',p_decision,'action_owner_id',p_action_owner_id,'action_due_at',p_action_due_at,'linked_task_id',v.linked_task_id));
  return v;
end;$$;

-- ================================================================
-- N. Rich project health
-- ================================================================
create or replace function epas_project_health_v15(p_project_id uuid)
returns table(
  project_id uuid,completion_pct numeric,health_status text,
  plan_completion_pct numeric,survey_completion_pct numeric,
  open_tasks integer,overdue_tasks integer,open_escalations integer,
  open_risks integer,plan_open_observations integer,survey_open_observations integer,
  active_certificates integer,closure_ready boolean
)
language sql security definer set search_path=public stable as $$
  with d as (
    select count(*) total,count(*) filter(where status='approved') done from plan_drawings where project_id=p_project_id
  ), r as (
    select count(*) total,count(*) filter(where status in ('approved_no_observations','approved_with_observations','certificate_issued','closed')) done from rfis where project_id=p_project_id
  ), t as (
    select count(*) filter(where status not in ('completed','returned')) open,count(*) filter(where status not in ('completed','returned') and due_at<now()) overdue from workflow_tasks where project_id=p_project_id
  ), o as (
    select count(*) filter(where o.status='open') plan_open from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id where d.project_id=p_project_id
  ), s as (
    select count(*) filter(where o.status='open') survey_open from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id
  ), e as (
    select count(*) open_escalations from workflow_escalations where project_id=p_project_id and status in ('open','acknowledged')
  ), k as (
    select count(*) open_risks from project_risks where project_id=p_project_id and status='open'
  ), c as (
    select count(*) active_certificates from certificates where project_id=p_project_id and status='active'
  )
  select p_project_id,
    round((coalesce(100.0*d.done/nullif(d.total,0),100) + coalesce(100.0*r.done/nullif(r.total,0),100))/2,1),
    case when t.overdue>0 or e.open_escalations>0 or k.open_risks>0 then 'attention'
         when o.plan_open>0 or s.survey_open>0 then 'watch' else 'healthy' end,
    round(coalesce(100.0*d.done/nullif(d.total,0),100),1),
    round(coalesce(100.0*r.done/nullif(r.total,0),100),1),
    t.open,t.overdue,e.open_escalations,k.open_risks,o.plan_open,s.survey_open,c.active_certificates,
    (t.open=0 and t.overdue=0 and e.open_escalations=0 and k.open_risks=0 and o.plan_open=0 and s.survey_open=0)
  from d,r,t,o,s,e,k,c;
$$;

-- ================================================================
-- O. Audit access + security hardening
-- ================================================================
do $$
begin
  -- All browser direct mutation is disabled; only trusted SECURITY DEFINER
  -- workflow RPCs perform these changes.
  revoke insert,update,delete on documents,rfis,observations,corrective_actions,
    workflow_escalations,project_milestones,certificates,project_risks,project_decisions
    from anon,authenticated;
  revoke execute on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) from public,anon,authenticated;
  revoke execute on function epas_audit(uuid,text,text,uuid,text,text,text,jsonb) from public,anon,authenticated;
exception when undefined_function then null;
end $$;

grant execute on function epas_add_business_days(timestamptz,integer) to authenticated;
grant execute on function epas_task_sla_days(text) to authenticated;
grant execute on function epas_project_eligible_resources_v15(uuid,text,text,date,date) to authenticated;
grant execute on function epas_resource_workload(uuid) to authenticated;
grant execute on function epas_submit_survey_report(uuid,text,jsonb) to authenticated;
grant execute on function epas_clear_survey_observation(uuid,text) to authenticated;
grant execute on function epas_designer_submit_revision(uuid,text,text,text,text,text,bigint) to authenticated;
grant execute on function epas_assignee_submit_corrective(uuid,text,text,text,bigint,text) to authenticated;
grant execute on function epas_release_document(uuid,text[],text) to authenticated;
grant execute on function epas_withdraw_document_release(uuid,text) to authenticated;
grant execute on function epas_log_document_access(uuid,text) to authenticated;
grant execute on function epas_finalize_interim_certificate(uuid,integer,text) to authenticated;
grant execute on function epas_project_closure_check(uuid) to authenticated;
grant execute on function epas_close_project(uuid,text) to authenticated;
grant execute on function epas_gm_escalation_decide(uuid,text,text,uuid,timestamptz) to authenticated;
grant execute on function epas_project_health_v15(uuid) to authenticated;

-- Read policies for release registry and access audit.
drop policy if exists document_releases_select_v15 on document_releases;
create policy document_releases_select_v15 on document_releases for select to authenticated using (
  epas_is_project_member(project_id)
  and (
    (select role from profiles where id=auth.uid()) not in ('owner','shipyard')
    or audience_role in ('owner','shipyard','all_stakeholders')
  )
);

drop policy if exists document_access_audit_select_v15 on document_access_audit;
create policy document_access_audit_select_v15 on document_access_audit for select to authenticated using (
  epas_has_role('gm') or epas_has_role('dm')
  or actor_id=auth.uid()
);

-- ================================================================
-- P. Storage hardening for private project-documents bucket
-- ================================================================
drop policy if exists epas_project_docs_insert_v15 on storage.objects;
create policy epas_project_docs_insert_v15 on storage.objects
for insert to authenticated
with check (
  bucket_id='project-documents'
  and exists (
    select 1 from project_members pm
    where pm.user_id=auth.uid() and pm.active
      and pm.project_id=(storage.foldername(name))[2]::uuid
      and (
        (select role from profiles where id=auth.uid()) in ('gm','dm','engineer','surveyor')
        or ((select role from profiles where id=auth.uid())='designer' and name like 'projects/%/plan-appraisal/%')
        or ((select role from profiles where id=auth.uid())='ship_management' and name like 'projects/%/corrective-actions/%')
      )
  )
);

drop policy if exists epas_project_docs_select_v15 on storage.objects;
create policy epas_project_docs_select_v15 on storage.objects
for select to authenticated
using (
  bucket_id='project-documents'
  and (
    exists (
      select 1 from project_members pm
      where pm.user_id=auth.uid() and pm.active
        and pm.project_id=(storage.foldername(name))[2]::uuid
        and (select role from profiles where id=auth.uid()) in ('gm','dm','engineer','surveyor')
    )
    or exists (
      select 1 from documents d
      where d.storage_path=name
        and d.stakeholder_visible=true
        and d.release_status='released'
        and exists (
          select 1 from project_members pm
          where pm.project_id=d.project_id and pm.user_id=auth.uid() and pm.active
            and pm.role in ('owner','designer','ship_management','shipyard')
        )
    )
  )
);

-- No client-side overwrite/delete for project documents.
drop policy if exists epas_project_docs_update_v15 on storage.objects;
drop policy if exists epas_project_docs_delete_v15 on storage.objects;

comment on table document_releases is 'Controlled external stakeholder release registry. Owner/Shipyard are read-only stakeholder roles.';
comment on table document_access_audit is 'Audit of document view/download/release/withdraw actions.';
comment on table sla_policies is 'Configurable working-day SLA policies per workflow task type.';


-- ================================================================
-- Q. Production query endpoints omitted from earlier releases
-- ================================================================

create or replace function epas_register_project_document_v15(
  p_project_id uuid,p_category text,p_file_name text,p_storage_path text,
  p_version integer default 1,p_sha256 text default null,p_mime_type text default null,p_size_bytes bigint default null
) returns documents
language plpgsql security definer set search_path=public as $$
declare v documents; v_prefix text;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may register project documents'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  if p_category not in ('contract','class_rules','timeline','drawing') then raise exception 'Invalid document category'; end if;
  v_prefix := 'projects/'||p_project_id::text||'/documents/'||p_category||'/';
  if p_storage_path <> v_prefix||p_file_name then raise exception 'Invalid controlled document storage path'; end if;
  insert into documents(project_id,category,file_name,version,status,storage_path,uploaded_by,sha256,mime_type,file_size_bytes,release_status,stakeholder_visible)
  values(p_project_id,p_category,p_file_name,p_version,'pending_review',p_storage_path,auth.uid(),p_sha256,p_mime_type,p_size_bytes,'internal',false)
  returning * into v;
  perform epas_audit(p_project_id,'DOCUMENT_REGISTERED','document',v.id,null,'pending_review',null,
    jsonb_build_object('category',p_category,'file_name',p_file_name,'storage_path',p_storage_path,'sha256',p_sha256,'size_bytes',p_size_bytes));
  return v;
end;$$;

create or replace function epas_gm_add_risk_v15(
  p_project_id uuid,p_code text,p_title text,p_description text,p_probability text,p_impact text,
  p_severity text,p_owner_id uuid,p_mitigation text,p_target_date date
) returns project_risks
language plpgsql security definer set search_path=public as $$
declare v project_risks;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may add project risks'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  if coalesce(trim(p_code),'')='' or coalesce(trim(p_title),'')='' or coalesce(trim(p_description),'')='' then
    raise exception 'Risk code, title and description are required';
  end if;
  insert into project_risks(project_id,risk_code,title,description,probability,impact,severity,owner_id,mitigation,target_date,created_by)
  values(p_project_id,p_code,p_title,p_description,p_probability,p_impact,p_severity,p_owner_id,p_mitigation,p_target_date,auth.uid())
  on conflict(project_id,risk_code) do update set
    title=excluded.title,description=excluded.description,probability=excluded.probability,impact=excluded.impact,
    severity=excluded.severity,owner_id=excluded.owner_id,mitigation=excluded.mitigation,target_date=excluded.target_date,updated_at=now()
  returning * into v;
  perform epas_audit(p_project_id,'RISK_REGISTERED','risk',v.id,null,v.status,null,jsonb_build_object('risk_code',p_code));
  return v;
end;$$;

create or replace function epas_run_sla_monitor_v15()
returns integer
language plpgsql security definer set search_path=public as $$
declare v_marked integer := 0; v_warn integer := 0;
begin
  update workflow_tasks
  set overdue_at=now()
  where status not in ('completed','returned')
    and due_at is not null
    and due_at < now()
    and overdue_at is null;
  get diagnostics v_marked=row_count;

  update workflow_tasks
  set last_reminder_at=now()
  where status not in ('completed','returned')
    and due_at is not null
    and due_at between now() and now()+interval '24 hours'
    and (last_reminder_at is null or last_reminder_at < now()-interval '24 hours');
  get diagnostics v_warn=row_count;

  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id,due_at)
  select t.to_user_id,'SLA deadline approaching',
         replace(t.task_type,'_',' ')||' is due by '||to_char(t.due_at,'DD Mon YYYY HH24:MI TZ'),
         t.project_id,
         case when t.entity_type='plan_drawing' then 'plan_appraisal'
              when t.entity_type='rfi' then 'survey_rfi' else 'dm_dashboard' end,
         'sla','medium','workflow_task',t.id,t.due_at
  from workflow_tasks t
  where t.status not in ('completed','returned')
    and t.due_at between now() and now()+interval '24 hours'
    and t.last_reminder_at >= now()-interval '2 minutes';

  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id,due_at)
  select t.to_user_id,'Workflow task overdue',
         replace(t.task_type,'_',' ')||' is overdue and requires immediate action.',
         t.project_id,
         case when t.entity_type='plan_drawing' then 'plan_appraisal'
              when t.entity_type='rfi' then 'survey_rfi' else 'dm_dashboard' end,
         'sla','high','workflow_task',t.id,t.due_at
  from workflow_tasks t
  where t.status not in ('completed','returned')
    and t.overdue_at >= now()-interval '2 minutes';

  return v_marked + v_warn;
end;$$;

grant execute on function epas_register_project_document_v15(uuid,text,text,text,integer,text,text,bigint) to authenticated;
grant execute on function epas_gm_add_risk_v15(uuid,text,text,text,text,text,text,uuid,text,date) to authenticated;
-- SLA monitor is intended for pg_cron/external scheduler; not exposed as a general browser mutation.
revoke execute on function epas_run_sla_monitor_v15() from public,anon,authenticated;


grant execute on function epas_release_document(uuid,text[],text) to authenticated;
grant execute on function epas_withdraw_document_release(uuid,text) to authenticated;


-- ================================================================
-- R. Date-aware Engineer/Surveyor assignment endpoints
-- ================================================================
create or replace function epas_dm_assign_engineer_v15(
  p_drawing_id uuid,p_engineer_id uuid,p_due_date date
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare v_d plan_drawings; v_ok boolean;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may assign engineer'; end if;
  select * into v_d from plan_drawings where id=p_drawing_id for update;
  if v_d.manager_id<>auth.uid() then raise exception 'Drawing belongs to another DM'; end if;
  if p_due_date < current_date then raise exception 'Engineer due date cannot be in the past'; end if;
  if not exists(select 1 from project_members where project_id=v_d.project_id and user_id=p_engineer_id and role='engineer' and active) then
    raise exception 'Engineer is not an active project member';
  end if;
  select exists(
    select 1 from epas_project_eligible_resources_v15(v_d.project_id,'engineer',v_d.discipline,current_date,p_due_date)
    where user_id=p_engineer_id and overlapping_tasks <= 2 and workload_pct < 90
  ) into v_ok;
  if not v_ok then raise exception 'Engineer fails authorization, competency, availability, workload, or conflict checks'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note='Reallocated by DM.'
  where entity_type='plan_drawing' and entity_id=v_d.id and to_user_id=auth.uid()
    and task_type in ('PLAN_APPRAISAL_MANAGER_HANDOVER','PLAN_APPRAISAL_REVISION_DM_REVIEW') and status in ('accepted','in_progress');
  update plan_drawings set engineer_id=p_engineer_id,status='assigned_engineer',updated_at=now() where id=v_d.id returning * into v_d;
  perform epas_create_task(v_d.project_id,'PLAN_APPRAISAL_ENGINEERING',p_engineer_id,
    'Appraise drawing '||v_d.drawing_no||' Rev '||v_d.current_revision||'. Technical review due '||to_char(p_due_date,'DD Mon YYYY')||'.',
    'plan_drawing',v_d.id,(p_due_date+1)::timestamptz,'high');
  perform epas_audit(v_d.project_id,'DM_ASSIGNED_ENGINEER_V15','plan_drawing',v_d.id,null,'assigned_engineer',null,
    jsonb_build_object('engineer_id',p_engineer_id,'due_date',p_due_date));
  return v_d;
end;$$;

create or replace function epas_dm_assign_surveyor_v15(
  p_rfi_id uuid,p_surveyor_id uuid,p_scheduled_date date
) returns rfis
language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_disc text; v_ok boolean;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may assign surveyor'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if p_scheduled_date < current_date then raise exception 'Survey date cannot be in the past'; end if;
  if v_rfi.status not in ('allocated_to_dm','sent_back_for_rework') then raise exception 'RFI is not ready for surveyor allocation'; end if;
  v_disc:=case when v_rfi.survey_type ilike '%machinery%' then 'Machinery'
               when v_rfi.survey_type ilike '%electrical%' then 'Electrical'
               else 'Hull & Structure' end;
  if not exists(select 1 from project_members where project_id=v_rfi.project_id and user_id=p_surveyor_id and role='surveyor' and active) then
    raise exception 'Surveyor is not an active project member';
  end if;
  select exists(
    select 1 from epas_project_eligible_resources_v15(v_rfi.project_id,'surveyor',v_disc,p_scheduled_date,p_scheduled_date)
    where user_id=p_surveyor_id and overlapping_tasks <= 2 and workload_pct < 90
  ) into v_ok;
  if not v_ok then raise exception 'Surveyor fails specialization, authorization, competency, availability, workload, or conflict checks'; end if;
  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note='Reallocated by DM.'
  where entity_type='rfi' and entity_id=v_rfi.id and to_user_id=auth.uid()
    and task_type in ('SURVEY_RFI_HANDOVER','FOLLOW_UP_RFI_DM_SCOPE_REVIEW') and status in ('accepted','in_progress');
  update rfis set assigned_surveyor_id=p_surveyor_id,scheduled_date=p_scheduled_date,status='survey_in_progress',updated_at=now()
  where id=p_rfi_id returning * into v_rfi;
  perform epas_create_task(v_rfi.project_id,'SURVEY_EXECUTION',p_surveyor_id,
    'Conduct '||v_rfi.survey_type||' on '||to_char(p_scheduled_date,'DD Mon YYYY')||' and submit the controlled survey report.',
    'rfi',v_rfi.id,p_scheduled_date::timestamptz,'high');
  perform epas_audit(v_rfi.project_id,'DM_ASSIGNED_SURVEYOR_V15','rfi',v_rfi.id,'allocated_to_dm','survey_in_progress',null,
    jsonb_build_object('surveyor_id',p_surveyor_id,'discipline',v_disc,'scheduled_date',p_scheduled_date));
  return v_rfi;
end;$$;

-- ================================================================
-- S. Controlled initial designer submission with provenance
-- ================================================================
create or replace function epas_designer_submit_initial_drawing_v15(
  p_project_id uuid,p_drawing_no text,p_title text,p_discipline text,
  p_file_name text,p_storage_path text,p_note text,
  p_sha256 text default null,p_mime_type text default 'application/pdf',p_size_bytes bigint default null
) returns plan_drawings
language plpgsql security definer set search_path=public as $$
declare v_doc documents; v_draw plan_drawings; v_gm uuid; v_prefix text;
begin
  if not epas_has_role('designer') then raise exception 'Only Designer may submit initial drawing'; end if;
  if not exists(select 1 from project_members where project_id=p_project_id and user_id=auth.uid() and role='designer' and active) then
    raise exception 'Designer is not an active member of this project';
  end if;
  v_prefix:='projects/'||p_project_id::text||'/plan-appraisal/intake/';
  if p_storage_path<>v_prefix||p_file_name then raise exception 'Invalid controlled intake storage path'; end if;
  if lower(coalesce(p_mime_type,''))<>'application/pdf' then raise exception 'Only PDF drawing submissions are accepted'; end if;
  if coalesce(p_size_bytes,0)<=0 then raise exception 'Drawing file size is required'; end if;
  if exists(select 1 from plan_drawings where project_id=p_project_id and drawing_no=p_drawing_no and status<>'approved') then
    raise exception 'A live drawing with this drawing number already exists';
  end if;
  insert into documents(project_id,category,file_name,version,status,storage_path,uploaded_by,sha256,mime_type,file_size_bytes,release_status,stakeholder_visible)
  values(p_project_id,'drawing',p_file_name,1,'pending_review',p_storage_path,auth.uid(),p_sha256,p_mime_type,p_size_bytes,'internal',false)
  returning * into v_doc;
  insert into plan_drawings(project_id,document_id,drawing_no,title,discipline,revision,status,designer_id,current_revision,current_file_name)
  values(p_project_id,v_doc.id,p_drawing_no,p_title,p_discipline,1,'submitted',auth.uid(),1,p_file_name) returning * into v_draw;
  insert into plan_revisions(drawing_id,revision_no,file_name,storage_path,submitted_by,submission_note,status,sha256,mime_type,file_size_bytes)
  values(v_draw.id,1,p_file_name,p_storage_path,auth.uid(),p_note,'submitted',p_sha256,p_mime_type,p_size_bytes);
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  perform epas_create_task(v_draw.project_id,'PLAN_APPRAISAL_GM_INTAKE',v_gm,
    'New drawing submitted by Designer for GM intake and Plan Appraisal handover.','plan_drawing',v_draw.id,null,'high');
  perform epas_audit(v_draw.project_id,'DESIGNER_INITIAL_DRAWING_SUBMITTED_V15','plan_drawing',v_draw.id,null,'submitted',p_note,
    jsonb_build_object('drawing_no',p_drawing_no,'revision',1,'sha256',p_sha256,'size_bytes',p_size_bytes));
  return v_draw;
end;$$;

-- ================================================================
-- T. Certificate PDF provenance
-- ================================================================
alter table certificates add column if not exists pdf_sha256 text;
alter table certificates add column if not exists pdf_size_bytes bigint;
alter table certificates add column if not exists pdf_mime_type text;

create or replace function epas_register_certificate_pdf_v15(
  p_certificate_id uuid,p_storage_path text,p_sha256 text,p_size_bytes bigint
) returns certificates
language plpgsql security definer set search_path=public as $$
declare v certificates; v_prefix text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may register certificate PDF'; end if;
  select * into v from certificates where id=p_certificate_id for update;
  if v.id is null then raise exception 'Certificate not found'; end if;
  v_prefix:='projects/'||v.project_id::text||'/certificates/';
  if p_storage_path<>v_prefix||v.cert_number||'.pdf' then raise exception 'Invalid controlled certificate path'; end if;
  if coalesce(p_size_bytes,0)<=0 or coalesce(p_sha256,'')='' then raise exception 'Certificate PDF integrity metadata is required'; end if;
  update certificates set pdf_storage_path=p_storage_path,pdf_sha256=p_sha256,pdf_size_bytes=p_size_bytes,pdf_mime_type='application/pdf'
  where id=v.id returning * into v;
  perform epas_audit(v.project_id,'CERTIFICATE_PDF_REGISTERED_V15','certificate',v.id,null,'active',null,
    jsonb_build_object('storage_path',p_storage_path,'sha256',p_sha256,'size_bytes',p_size_bytes));
  return v;
end;$$;

grant execute on function epas_dm_assign_engineer_v15(uuid,uuid,date) to authenticated;
grant execute on function epas_dm_assign_surveyor_v15(uuid,uuid,date) to authenticated;
grant execute on function epas_designer_submit_initial_drawing_v15(uuid,text,text,text,text,text,text,text,text,bigint) to authenticated;
grant execute on function epas_register_certificate_pdf_v15(uuid,text,text,bigint) to authenticated;

-- ================================================================
-- T.1 Resource capacity hours + improved conflict calculation
-- ================================================================
alter table workflow_tasks add column if not exists estimated_hours numeric(8,2) not null default 8;
alter table resource_availability_calendar add column if not exists capacity_hours numeric(8,2) not null default 8;

drop function if exists epas_resource_workload(uuid);
create function epas_resource_workload(p_project_id uuid)
returns table(
  user_id uuid,full_name text,role text,discipline text,workload_pct numeric,capacity_pct numeric,
  assigned_tasks integer,overdue_tasks integer,due_7d integer,same_due_date_conflicts integer,
  overlapping_tasks integer,availability_status text,assigned_hours numeric,capacity_hours numeric,utilization_pct numeric
)
language sql security definer set search_path=public stable as $$
  select pm.user_id,p.full_name,pm.role,pm.discipline,
    coalesce(av.workload_pct,0)::numeric,
    (100-coalesce(av.workload_pct,0))::numeric,
    coalesce((select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.status not in ('completed','returned')),0),
    coalesce((select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.status not in ('completed','returned') and t.due_at<now()),0),
    coalesce((select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.status not in ('completed','returned') and t.due_at between now() and now()+interval '7 days'),0),
    coalesce((select count(*) from workflow_tasks t1 where t1.to_user_id=pm.user_id and t1.project_id=p_project_id and t1.status not in ('completed','returned')
      and exists(select 1 from workflow_tasks t2 where t2.to_user_id=pm.user_id and t2.status not in ('completed','returned') and t2.id<>t1.id and t2.due_at::date=t1.due_at::date)),0),
    coalesce((select count(*) from workflow_tasks t where t.to_user_id=pm.user_id and t.status not in ('completed','returned')
      and coalesce(t.planned_start_at,t.created_at)<=now()+interval '7 days'
      and coalesce(t.planned_end_at,t.due_at)>=now()),0),
    coalesce(av.status,'available'),
    coalesce((select sum(coalesce(t.estimated_hours,8)) from workflow_tasks t where t.to_user_id=pm.user_id and t.status not in ('completed','returned')),0)::numeric,
    coalesce(av.capacity_hours,8)::numeric,
    round((coalesce((select sum(coalesce(t.estimated_hours,8)) from workflow_tasks t where t.to_user_id=pm.user_id and t.status not in ('completed','returned')),0)
      / nullif(coalesce(av.capacity_hours,8),0) * 100)::numeric,1)
  from project_members pm
  join profiles p on p.id=pm.user_id
  left join resource_availability_calendar av on av.user_id=pm.user_id and av.work_date=current_date
  where pm.project_id=p_project_id and pm.active and pm.role in ('dm','engineer','surveyor')
  group by pm.user_id,p.full_name,pm.role,pm.discipline,av.workload_pct,av.status,av.capacity_hours;
$$;
grant execute on function epas_resource_workload(uuid) to authenticated;

-- ================================================================
-- T.2 Stakeholder release may only release controlled/approved documents
-- and a drawing only after GM approval.
-- ================================================================
create or replace function epas_release_document(
  p_document_id uuid,p_audience_roles text[],p_note text
) returns documents
language plpgsql security definer set search_path=public as $$
declare v_doc documents; v_role text; v_project uuid; v_releasable boolean:=false;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may release documents'; end if;
  select * into v_doc from documents where id=p_document_id for update;
  if v_doc.id is null then raise exception 'Document not found'; end if;
  v_project:=v_doc.project_id;
  if not epas_is_project_member(v_project) then raise exception 'Not authorized for project'; end if;

  if v_doc.category='drawing' then
    select exists(
      select 1 from plan_drawings d
      where d.document_id=v_doc.id and d.status='approved' and d.approved_by is not null
    ) into v_releasable;
  else
    v_releasable := v_doc.status='approved';
  end if;
  if not v_releasable then raise exception 'Only approved controlled documents may be released to stakeholders'; end if;
  if coalesce(array_length(p_audience_roles,1),0)=0 then raise exception 'At least one stakeholder audience is required'; end if;

  foreach v_role in array p_audience_roles loop
    if v_role not in ('designer','owner','ship_management','shipyard','all_stakeholders') then
      raise exception 'Invalid stakeholder audience';
    end if;
    insert into document_releases(document_id,project_id,audience_role,status,release_note,released_by)
    values(v_doc.id,v_project,v_role,'released',p_note,auth.uid())
    on conflict (document_id,audience_role) where status='released' do update
      set release_note=excluded.release_note,released_by=auth.uid(),released_at=now(),withdrawn_by=null,withdrawn_at=null;
  end loop;
  update documents set stakeholder_visible=true,release_status='released',status='approved' where id=v_doc.id returning * into v_doc;
  insert into document_access_audit(document_id,project_id,actor_id,actor_role,action,metadata)
  values(v_doc.id,v_project,auth.uid(),(select role from profiles where id=auth.uid()),'release',
         jsonb_build_object('audiences',p_audience_roles,'note',p_note));
  perform epas_audit(v_project,'DOCUMENT_RELEASED','document',v_doc.id,'internal','released',p_note,
                     jsonb_build_object('audiences',p_audience_roles));
  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  select pm.user_id,'Document released','Controlled document '||v_doc.file_name||' is now released for stakeholder viewing.',
         v_project,'documents','document_release','info','document',v_doc.id
  from project_members pm
  where pm.project_id=v_project and pm.active
    and ('all_stakeholders'=any(p_audience_roles) or pm.role=any(p_audience_roles));
  insert into notification_outbox(project_id,recipient_email,subject,body)
  select v_project,p.email,'EPAS document released',
         'Controlled document '||v_doc.file_name||' has been released for stakeholder viewing.'
  from project_members pm join profiles p on p.id=pm.user_id
  where pm.project_id=v_project and pm.active
    and ('all_stakeholders'=any(p_audience_roles) or pm.role=any(p_audience_roles))
    and coalesce(p.email,'')<>'';
  return v_doc;
end;$$;

-- ================================================================
-- T.3 Improved closure gates: no pending plan drawings, no unfinalized interim
-- ================================================================
create or replace function epas_project_closure_check(p_project_id uuid)
returns table(check_code text,check_title text,passed boolean,details text)
language sql security definer set search_path=public stable as $$
  with x as (
    select
      (select count(*) from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id where d.project_id=p_project_id and o.status='open') plan_obs,
      (select count(*) from plan_drawings d where d.project_id=p_project_id and d.status<>'approved') plan_pending,
      (select count(*) from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id and o.status='open') survey_obs,
      (select count(*) from workflow_tasks t where t.project_id=p_project_id and t.status not in ('completed','returned')) tasks_open,
      (select count(*) from corrective_actions c where c.project_id=p_project_id and c.status not in ('verified','closed')) corrective_open,
      (select count(*) from workflow_escalations e where e.project_id=p_project_id and e.status in ('open','acknowledged')) esc_open,
      (select count(*) from project_milestones m where m.project_id=p_project_id and m.status not in ('completed','cancelled')) milestones_open,
      (select count(*) from certificates c where c.project_id=p_project_id and c.status='active' and c.cert_type='interim_certificate') interim_active,
      (select count(*) from certificates c where c.project_id=p_project_id and c.status='active' and c.cert_type in ('class_certificate','nsc_certificate')) final_cert
  )
  select * from (
    select 'PLAN_OBSERVATIONS','Open plan observations = 0',(plan_obs=0),'Open: '||plan_obs::text from x
    union all select 'PLAN_DRAWINGS','All plan drawings approved',(plan_pending=0),'Pending/non-approved drawings: '||plan_pending::text from x
    union all select 'SURVEY_OBSERVATIONS','Open survey observations = 0',(survey_obs=0),'Open: '||survey_obs::text from x
    union all select 'WORKFLOW_TASKS','No open workflow tasks',(tasks_open=0),'Open: '||tasks_open::text from x
    union all select 'CORRECTIVE_ACTIONS','No unverified corrective actions',(corrective_open=0),'Open: '||corrective_open::text from x
    union all select 'ESCALATIONS','No open escalations',(esc_open=0),'Open: '||esc_open::text from x
    union all select 'MILESTONES','All project milestones completed/cancelled',(milestones_open=0),'Remaining: '||milestones_open::text from x
    union all select 'CERTIFICATE','Final/NSC certificate active and no Interim remains',(interim_active=0 and final_cert>0),'Interim active: '||interim_active::text||' / final certificates: '||final_cert::text from x
  ) q;
$$;

-- v1.5 control tables are RPC/trigger owned; browser clients are read-only.
revoke insert,update,delete on document_releases,document_access_audit,notification_outbox,
  certificate_lifecycle_events,project_closure_checks,project_archives,sla_policies
  from anon,authenticated;

-- ================================================================
-- U. Backward-compatible DM corrective-action handover endpoint
-- ================================================================
create or replace function epas_dm_complete_corrective(p_action_id uuid,p_instruction text)
returns corrective_actions
language plpgsql security definer set search_path=public as $$
declare v corrective_actions;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may issue corrective action'; end if;
  select * into v from corrective_actions where id=p_action_id for update;
  if v.id is null then raise exception 'Corrective action not found'; end if;
  if v.assigned_by<>auth.uid() and not epas_has_role('gm') then raise exception 'Corrective action belongs to another DM'; end if;
  update corrective_actions set instruction=coalesce(nullif(trim(p_instruction),''),instruction),status='open'
  where id=v.id returning * into v;
  perform epas_audit(v.project_id,'DM_CORRECTIVE_ACTION_ISSUED','corrective_action',v.id,v.status,'open',p_instruction,'{}'::jsonb);
  return v;
end;$$;
grant execute on function epas_dm_complete_corrective(uuid,text) to authenticated;
