-- EPAS v1.9 Role-Complete Gap Closure (Items 11-20)
-- Apply AFTER v1.8.
-- Business rule: Shipyard may initiate NSC Survey RFIs ONLY.
-- Owner and Ship Management may initiate In-Service Survey RFIs ONLY.

begin;

create extension if not exists pgcrypto;

-- ================================================================
-- 11. SURVEY PRE-SURVEY CHECKLIST
-- ================================================================
create table if not exists survey_checklist_items (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  item_code text not null,
  category text not null,
  requirement text not null,
  mandatory boolean not null default true,
  status text not null default 'pending' check(status in ('pending','complete','not_applicable')),
  response text,
  remarks text,
  completed_by uuid references profiles(id),
  completed_at timestamptz,
  unique(rfi_id,item_code)
);
create index if not exists idx_survey_checklist_rfi on survey_checklist_items(rfi_id,status);

create or replace function epas_initialize_survey_checklist(p_rfi_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_count integer:=0; v_role text;
begin
  select * into v_rfi from rfis where id=p_rfi_id;
  if v_rfi.id is null then raise exception 'RFI not found'; end if;
  v_role := (select role from profiles where id=auth.uid());
  if v_role not in ('gm','dm','surveyor') then raise exception 'Only GM, DM or Surveyor may initialize survey checklist'; end if;
  if v_role='surveyor' and v_rfi.assigned_surveyor_id<>auth.uid() then raise exception 'Survey RFI is assigned to another surveyor'; end if;

  insert into survey_checklist_items(rfi_id,item_code,category,requirement,mandatory)
  values
    (p_rfi_id,'ACCESS_001','Access','Vessel/site access and survey attendance confirmed',true),
    (p_rfi_id,'DOC_001','Documents','Approved/current drawings and applicable documents available',true),
    (p_rfi_id,'DOC_002','Documents','Previous survey reports reviewed',case when v_rfi.phase='in_service' then true else false end),
    (p_rfi_id,'DOC_003','Documents','Maintenance/repair records reviewed',case when v_rfi.phase='in_service' then true else false end),
    (p_rfi_id,'CLASS_001','Class','Current class/certificate status reviewed',true),
    (p_rfi_id,'SAFETY_001','Safety','Required safety arrangements confirmed',true),
    (p_rfi_id,'SCOPE_001','Scope','Survey scope and requested survey type confirmed',true),
    (p_rfi_id,'CHANGE_001','Change of Class','Change-of-class requirement assessed',case when v_rfi.phase='in_service' then true else false end)
  on conflict(rfi_id,item_code) do nothing;

  select count(*) into v_count from survey_checklist_items where rfi_id=p_rfi_id;
  return v_count;
end;$$;
grant execute on function epas_initialize_survey_checklist(uuid) to authenticated;

create or replace function epas_complete_survey_checklist_item(
  p_item_id uuid,p_status text,p_response text,p_remarks text
) returns survey_checklist_items language plpgsql security definer set search_path=public as $$
declare v_item survey_checklist_items; v_rfi rfis;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may complete survey checklist'; end if;
  if p_status not in ('complete','not_applicable') then raise exception 'Invalid checklist status'; end if;
  select * into v_item from survey_checklist_items where id=p_item_id for update;
  select * into v_rfi from rfis where id=v_item.rfi_id;
  if v_rfi.assigned_surveyor_id<>auth.uid() then raise exception 'Checklist belongs to another surveyor'; end if;
  update survey_checklist_items set status=p_status,response=p_response,remarks=p_remarks,completed_by=auth.uid(),completed_at=now() where id=p_item_id returning * into v_item;
  return v_item;
end;$$;
grant execute on function epas_complete_survey_checklist_item(uuid,text,text,text) to authenticated;

create or replace function epas_survey_checklist_ready(p_rfi_id uuid)
returns boolean language sql security definer set search_path=public stable as $$
  select not exists(select 1 from survey_checklist_items where rfi_id=p_rfi_id and mandatory and status='pending');
$$;
grant execute on function epas_survey_checklist_ready(uuid) to authenticated;

-- ================================================================
-- 12. PROFESSIONAL OBSERVATION DATA MODEL
-- ================================================================
alter table observations add column if not exists rule_reference text;
alter table observations add column if not exists location text;
alter table observations add column if not exists equipment_system text;
alter table observations add column if not exists deficiency_category text;
alter table observations add column if not exists responsible_party text;
alter table observations add column if not exists target_date date;
alter table observations add column if not exists corrective_action text;
alter table observations add column if not exists evidence_required boolean not null default true;
alter table observations add column if not exists verification_method text;
alter table observations add column if not exists clearance_note text;
alter table observations add column if not exists verified_at timestamptz;
alter table observations add column if not exists verified_by uuid references profiles(id);

create index if not exists idx_observations_rfi_status_severity on observations(rfi_id,status,severity);

create or replace function epas_stakeholder_observation_summary(p_rfi_id uuid)
returns table(observation_id uuid,obs_code text,description text,severity text,status text,rule_reference text,location text,equipment_system text,deficiency_category text,target_date date,corrective_action text)
language plpgsql security definer set search_path=public stable as $$
declare v_rfi rfis; v_role text;
begin
  select * into v_rfi from rfis where id=p_rfi_id;
  select role into v_role from profiles where id=auth.uid();
  if v_rfi.id is null then raise exception 'RFI not found'; end if;
  if v_role not in ('gm','dm','owner','ship_management','shipyard') then raise exception 'Not authorized'; end if;
  if v_role in ('owner','ship_management','shipyard') and v_rfi.requested_by<>auth.uid() then raise exception 'Stakeholders may only view observations for their own RFI'; end if;
  return query select o.id,o.obs_code,o.description,o.severity,o.status,o.rule_reference,o.location,o.equipment_system,o.deficiency_category,o.target_date,o.corrective_action from observations o where o.rfi_id=p_rfi_id order by o.raised_at;
end;$$;
grant execute on function epas_stakeholder_observation_summary(uuid) to authenticated;

-- ================================================================
-- 13. FOLLOW-UP RFI TYPE AND LINEAGE
-- ================================================================
alter table rfis add column if not exists follow_up_type text;
alter table rfis drop constraint if exists rfis_follow_up_type_check;
alter table rfis add constraint rfis_follow_up_type_check check(follow_up_type is null or follow_up_type in ('NSC_REWORK_VERIFICATION','IN_SERVICE_OBSERVATION_CLEARANCE','CHANGE_OF_CLASS_FOLLOW_UP','GENERAL_FOLLOW_UP'));

create or replace function epas_dm_create_follow_up_rfi(
  p_parent_rfi_id uuid,p_follow_up_type text,p_scope_note text,p_requested_date date
) returns rfis language plpgsql security definer set search_path=public as $$
declare v_parent rfis; v_new rfis; v_code text; v_gm uuid;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may create follow-up RFI'; end if;
  if p_follow_up_type not in ('NSC_REWORK_VERIFICATION','IN_SERVICE_OBSERVATION_CLEARANCE','CHANGE_OF_CLASS_FOLLOW_UP','GENERAL_FOLLOW_UP') then raise exception 'Invalid follow-up type'; end if;
  if coalesce(trim(p_scope_note),'')='' then raise exception 'Follow-up scope is required'; end if;
  select * into v_parent from rfis where id=p_parent_rfi_id for update;
  if v_parent.id is null then raise exception 'Parent RFI not found'; end if;
  if v_parent.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if p_follow_up_type='NSC_REWORK_VERIFICATION' and v_parent.phase<>'nsc_survey' then raise exception 'NSC rework follow-up requires NSC RFI'; end if;
  if p_follow_up_type in ('IN_SERVICE_OBSERVATION_CLEARANCE','CHANGE_OF_CLASS_FOLLOW_UP') and v_parent.phase<>'in_service' then raise exception 'Selected follow-up type requires In-Service RFI'; end if;
  v_code:='RFI-FU-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,assigned_dm_id,requested_date,priority,scope_note,requester_role,follow_up_of_rfi_id,follow_up_type)
  values(v_parent.project_id,v_parent.vessel_id,v_parent.phase,v_parent.survey_type,v_code,'pending_allocation',auth.uid(),auth.uid(),coalesce(p_requested_date,current_date),v_parent.priority,p_scope_note,'dm',p_parent_rfi_id,p_follow_up_type)
  returning * into v_new;
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  if v_gm is not null then perform epas_create_task(v_new.project_id,'GM_SURVEY_RFI_INTAKE',v_gm,'Follow-up RFI awaiting GM intake: '||v_code,'rfi',v_new.id,null,'high'); end if;
  perform epas_audit(v_new.project_id,'FOLLOW_UP_RFI_CREATED','rfi',v_new.id,null,'pending_allocation',p_scope_note,jsonb_build_object('parent_rfi_id',p_parent_rfi_id,'follow_up_type',p_follow_up_type));
  return v_new;
end;$$;
grant execute on function epas_dm_create_follow_up_rfi(uuid,text,text,date) to authenticated;

-- ================================================================
-- 14. CERTIFICATE LIFECYCLE HARDENING
-- ================================================================
alter table certificates add column if not exists certificate_stage text not null default 'FINAL';
update certificates set certificate_stage='INTERIM' where cert_type='interim_certificate';
alter table certificates drop constraint if exists certificates_certificate_stage_check;
alter table certificates add constraint certificates_certificate_stage_check check(certificate_stage in ('INTERIM','FINAL'));

create or replace function epas_refresh_certificate_lifecycle()
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  if not epas_has_role('gm') and not epas_has_role('dm') then raise exception 'Only GM or DM may refresh certificate lifecycle'; end if;
  update certificates set lifecycle_state='EXPIRED',last_lifecycle_at=now(),lifecycle_note='Automatically expired by lifecycle monitor'
  where expiry_date<current_date and status='active' and lifecycle_state in ('ACTIVE','EXPIRING');
  get diagnostics v_count=row_count;
  update certificates set lifecycle_state='EXPIRING',last_lifecycle_at=now(),lifecycle_note='Certificate is within expiry warning window'
  where expiry_date>=current_date and expiry_date<=current_date+interval '30 days' and status='active' and lifecycle_state='ACTIVE';
  return v_count;
end;$$;
grant execute on function epas_refresh_certificate_lifecycle() to authenticated;

-- ================================================================
-- 15/16. OWNER / SHIPYARD FLEET/VESSEL DASHBOARD DATA
-- ================================================================
create or replace function epas_stakeholder_fleet_summary()
returns table(total_vessels bigint,in_class bigint,interim bigint,out_of_class bigint,expiring_certificates bigint,open_observations bigint)
language plpgsql security definer set search_path=public stable as $$
declare v_role text;
begin
  select role into v_role from profiles where id=auth.uid();
  if v_role not in ('owner','shipyard','ship_management') then raise exception 'Stakeholder role required'; end if;
  return query
  with my_projects as (select distinct project_id from project_members where user_id=auth.uid() and active and role=v_role),
  my_vessels as (select v.* from vessels v join my_projects p on p.project_id=v.project_id),
  certs as (select c.* from certificates c join my_vessels v on v.id=c.vessel_id where c.status='active')
  select (select count(*) from my_vessels),
         (select count(*) from certs where certificate_stage='FINAL'),
         (select count(*) from certs where certificate_stage='INTERIM'),
         (select count(*) from my_vessels v where not exists(select 1 from certs c where c.vessel_id=v.id and c.status='active')),
         (select count(*) from certs where expiry_date between current_date and current_date+interval '90 days'),
         (select count(*) from observations o join rfis r on r.id=o.rfi_id join my_vessels v on v.id=r.vessel_id where o.status='open' and r.requested_by=auth.uid());
end;$$;
grant execute on function epas_stakeholder_fleet_summary() to authenticated;

create or replace function epas_stakeholder_vessel_dashboard(p_vessel_id uuid)
returns table(vessel_id uuid,vessel_name text,imo_number text,current_class text,status text,certificate_count bigint,open_observations bigint,next_survey_date date)
language plpgsql security definer set search_path=public stable as $$
declare v_role text; v_project uuid;
begin
  select role into v_role from profiles where id=auth.uid();
  select project_id into v_project from vessels where id=p_vessel_id;
  if v_project is null then raise exception 'Vessel not found'; end if;
  if not exists(select 1 from project_members where project_id=v_project and user_id=auth.uid() and active and role=v_role) then raise exception 'Vessel is not visible to this stakeholder'; end if;
  return query
  select v.id,v.name,v.imo_number,v.current_class,
         case when exists(select 1 from certificates c where c.vessel_id=v.id and c.status='active' and c.certificate_stage='FINAL') then 'In Class'
              when exists(select 1 from certificates c where c.vessel_id=v.id and c.status='active' and c.certificate_stage='INTERIM') then 'Interim' else 'Out of Class' end,
         (select count(*) from certificates c where c.vessel_id=v.id),
         (select count(*) from observations o join rfis r on r.id=o.rfi_id where r.vessel_id=v.id and o.status='open' and r.requested_by=auth.uid()),
         (select min(coalesce(r.scheduled_date,r.requested_date)) from rfis r where r.vessel_id=v.id and r.status in ('pending_allocation','allocated_to_dm','survey_in_progress'))
  from vessels v where v.id=p_vessel_id;
end;$$;
grant execute on function epas_stakeholder_vessel_dashboard(uuid) to authenticated;

create or replace function epas_stakeholder_upcoming_surveys(p_vessel_id uuid)
returns table(rfi_id uuid,rfi_code text,phase text,survey_type text,scheduled_date date,status text,follow_up_type text)
language plpgsql security definer set search_path=public stable as $$
declare v_role text; v_project uuid;
begin
  select role into v_role from profiles where id=auth.uid();
  select project_id into v_project from vessels where id=p_vessel_id;
  if not exists(select 1 from project_members where project_id=v_project and user_id=auth.uid() and active and role=v_role) then raise exception 'Not authorized'; end if;
  return query select r.id,r.rfi_code,r.phase,r.survey_type,r.scheduled_date,r.status,r.follow_up_type from rfis r where r.vessel_id=p_vessel_id and (r.scheduled_date is not null or r.requested_date>=current_date) order by coalesce(r.scheduled_date,r.requested_date);
end;$$;
grant execute on function epas_stakeholder_upcoming_surveys(uuid) to authenticated;

-- Stakeholder initiation is reasserted here so the rule cannot regress.
create or replace function epas_stakeholder_create_rfi(
  p_project_id uuid,p_vessel_id uuid,p_phase text,p_survey_type text,p_requested_date date,p_priority text,p_scope_note text
) returns rfis language plpgsql security definer set search_path=public as $$
declare v_role text; v_rfi rfis; v_gm uuid; v_code text;
begin
  select role into v_role from profiles where id=auth.uid();
  if v_role not in ('owner','ship_management','shipyard') then raise exception 'Stakeholder role not permitted'; end if;
  if v_role='shipyard' and p_phase<>'nsc_survey' then raise exception 'Shipyard may initiate NSC Survey RFIs only'; end if;
  if v_role in ('owner','ship_management') and p_phase<>'in_service' then raise exception 'Owner and Ship Management may initiate In-Service Survey RFIs only'; end if;
  if p_phase not in ('nsc_survey','in_service') then raise exception 'Invalid survey phase'; end if;
  if not exists(select 1 from project_members where project_id=p_project_id and user_id=auth.uid() and active and role=v_role) then raise exception 'Not an active stakeholder member of this project'; end if;
  if not exists(select 1 from vessels where id=p_vessel_id and project_id=p_project_id) then raise exception 'Vessel does not belong to project'; end if;
  v_code:='RFI-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(p_project_id,p_vessel_id,p_phase,p_survey_type,v_code,'pending_allocation',auth.uid(),coalesce(p_requested_date,current_date),p_priority,p_scope_note,v_role) returning * into v_rfi;
  insert into survey_checklist_items(rfi_id,item_code,category,requirement,mandatory) values
    (v_rfi.id,'ACCESS_001','Access','Vessel/site access and survey attendance confirmed',true),
    (v_rfi.id,'DOC_001','Documents','Approved/current drawings and applicable documents available',true),
    (v_rfi.id,'DOC_002','Documents','Previous survey reports reviewed',case when p_phase='in_service' then true else false end),
    (v_rfi.id,'DOC_003','Documents','Maintenance/repair records reviewed',case when p_phase='in_service' then true else false end),
    (v_rfi.id,'CLASS_001','Class','Current class/certificate status reviewed',true),
    (v_rfi.id,'SAFETY_001','Safety','Required safety arrangements confirmed',true),
    (v_rfi.id,'SCOPE_001','Scope','Survey scope and requested survey type confirmed',true),
    (v_rfi.id,'CHANGE_001','Change of Class','Change-of-class requirement assessed',case when p_phase='in_service' then true else false end);
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  if v_gm is not null then perform epas_create_task(v_rfi.project_id,'GM_SURVEY_RFI_INTAKE',v_gm,'Stakeholder RFI submitted: '||v_code,'rfi',v_rfi.id,null,p_priority); end if;
  perform epas_audit(v_rfi.project_id,'STAKEHOLDER_RFI_CREATED','rfi',v_rfi.id,null,'pending_allocation',p_scope_note,jsonb_build_object('requester_role',v_role,'survey_phase',p_phase));
  return v_rfi;
end;$$;
grant execute on function epas_stakeholder_create_rfi(uuid,uuid,text,text,date,text,text) to authenticated;

-- ================================================================
-- 17/18. DESIGNER SUBMISSION TRACKER / REVISION LINEAGE
-- ================================================================
alter table plan_revisions add column if not exists parent_revision_id uuid references plan_revisions(id);
alter table plan_revisions add column if not exists submission_reason text;
alter table plan_revisions add column if not exists sha256 text;
alter table plan_revisions add column if not exists mime_type text;
alter table plan_revisions add column if not exists size_bytes bigint;
alter table plan_revisions add column if not exists reviewed_by uuid references profiles(id);

create or replace function epas_designer_submission_queue()
returns table(drawing_id uuid,project_id uuid,drawing_no text,title text,discipline text,current_revision integer,status text,latest_revision_status text,latest_submission_at timestamptz,action_required text)
language plpgsql security definer set search_path=public stable as $$
begin
  if not epas_has_role('designer') then raise exception 'Only Designer may access submission queue'; end if;
  return query
  select d.id,d.project_id,d.drawing_no,d.title,d.discipline,d.current_revision,d.status,
         pr.status,pr.submitted_at,
         case when exists(select 1 from workflow_tasks t where t.entity_type='plan_drawing' and t.entity_id=d.id and t.to_user_id=auth.uid() and t.task_type='PLAN_APPRAISAL_DESIGNER_RESPONSE' and t.status in ('pending','accepted','in_progress')) then 'Amendment / resubmission required'
              when d.status='approved' then 'No further action'
              else 'Awaiting review' end
  from plan_drawings d
  left join lateral(select * from plan_revisions x where x.drawing_id=d.id order by x.revision_no desc limit 1) pr on true
  where exists(select 1 from project_members pm where pm.project_id=d.project_id and pm.user_id=auth.uid() and pm.active and pm.role='designer')
  order by d.updated_at desc;
end;$$;
grant execute on function epas_designer_submission_queue() to authenticated;

-- ================================================================
-- 19. SHIP MANAGEMENT CORRECTIVE-ACTION / EVIDENCE DASHBOARD DATA
-- ================================================================
create or replace function epas_ship_management_action_queue()
returns table(action_id uuid,rfi_id uuid,rfi_code text,obs_count bigint,instruction text,status text,due_at timestamptz,evidence_path text,submitted_at timestamptz)
language sql security definer set search_path=public stable as $$
  select ca.id,ca.rfi_id,r.rfi_code,count(cao.observation_id),ca.instruction,ca.status,ca.due_at,ca.evidence_path,ca.submitted_at
  from corrective_actions ca join rfis r on r.id=ca.rfi_id
  left join corrective_action_observations cao on cao.corrective_action_id=ca.id
  where epas_has_role('ship_management') and ca.assigned_to=auth.uid()
  group by ca.id,ca.rfi_id,r.rfi_code,ca.instruction,ca.status,ca.due_at,ca.evidence_path,ca.submitted_at
  order by ca.due_at nulls last;
$$;
grant execute on function epas_ship_management_action_queue() to authenticated;

-- ================================================================
-- 20. RESOURCE ALLOCATION MATRIX + SNAPSHOT
-- ================================================================
create table if not exists resource_assignment_snapshots (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  resource_id uuid not null references profiles(id),
  role text not null,
  discipline text,
  allocation_date date not null,
  eligible boolean not null,
  authorization_ok boolean not null default false,
  competency_ok boolean not null default false,
  availability_ok boolean not null default false,
  workload_pct numeric(5,2),
  conflict_note text,
  captured_by uuid not null references profiles(id),
  captured_at timestamptz not null default now()
);
create index if not exists idx_resource_assignment_snapshots_entity on resource_assignment_snapshots(entity_type,entity_id,captured_at desc);

create or replace function epas_resource_allocation_matrix(p_project_id uuid,p_role text,p_discipline text,p_work_date date default current_date)
returns table(user_id uuid,full_name text,authorization_ok boolean,competency_ok boolean,availability_ok boolean,workload_pct numeric,eligible boolean,eligibility_note text)
language sql security definer set search_path=public stable as $$
  select e.user_id,e.full_name,
         (e.authorization_level is not null) as authorization_ok,
         exists(select 1 from resource_competencies c where c.user_id=e.user_id and c.discipline=p_discipline and c.status in ('competent','conditional') and (c.valid_until is null or c.valid_until>=p_work_date)) as competency_ok,
         exists(select 1 from resource_availability_calendar a where a.user_id=e.user_id and a.work_date=p_work_date and a.status in ('available','partial')) as availability_ok,
         e.workload_pct,
         true,
         e.eligibility_note
  from epas_project_eligible_resources_v15(p_project_id,p_role,p_discipline,p_work_date,p_work_date) e
  order by e.workload_pct asc,e.full_name;
$$;
grant execute on function epas_resource_allocation_matrix(uuid,text,text,date) to authenticated;

-- ================================================================
-- SLA / task lifecycle fields used by resource and management views
-- ================================================================
alter table workflow_tasks add column if not exists accepted_at timestamptz;
alter table workflow_tasks add column if not exists started_at timestamptz;
alter table workflow_tasks add column if not exists sla_due_at timestamptz;
alter table workflow_tasks add column if not exists sla_state text not null default 'ON_TRACK';
alter table workflow_tasks drop constraint if exists workflow_tasks_sla_state_check;
alter table workflow_tasks add constraint workflow_tasks_sla_state_check check(sla_state in ('ON_TRACK','DUE_SOON','OVERDUE','BREACHED'));

create or replace function epas_refresh_task_sla()
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  update workflow_tasks set sla_state=case when status in ('completed','returned') then 'ON_TRACK' when coalesce(sla_due_at,due_at)<now() then 'BREACHED' when coalesce(sla_due_at,due_at)<=now()+interval '24 hours' then 'DUE_SOON' else 'ON_TRACK' end;
  get diagnostics v_count=row_count;
  return v_count;
end;$$;
grant execute on function epas_refresh_task_sla() to authenticated;


-- Re-run checklist readiness gate in survey submission by exposing a single helper.
create or replace function epas_survey_submission_gate(p_rfi_id uuid)
returns table(checklist_ready boolean,open_observations bigint,latest_report_at timestamptz)
language sql security definer set search_path=public stable as $$
  select epas_survey_checklist_ready(p_rfi_id),
         (select count(*) from observations where rfi_id=p_rfi_id and status='open'),
         (select max(submitted_at) from survey_reports where rfi_id=p_rfi_id);
$$;
grant execute on function epas_survey_submission_gate(uuid) to authenticated;

commit;
