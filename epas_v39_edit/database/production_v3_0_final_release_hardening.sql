-- EPAS v3.0 — Final release hardening
-- Baseline: v2.9 cumulative package
-- Scope: final privilege allowlist, stakeholder data minimisation,
-- recurring-cycle idempotency, dependency invalidation, immutable evidence,
-- role-scoped gates, concurrency protection, and production auditability.

begin;
create extension if not exists pgcrypto;

-- ================================================================
-- 1. Final RLS coverage for v2.9 operational/audit tables.
-- ================================================================
-- Reassert RLS for every operational table introduced since v2.8.
alter table survey_cycle_instances enable row level security;
alter table survey_checklist_instances enable row level security;
alter table survey_assignment_acknowledgements enable row level security;
alter table survey_scope_change_events enable row level security;
alter table survey_scope_acknowledgements enable row level security;
alter table survey_drawing_package_acknowledgements enable row level security;

alter table security_events_v29 enable row level security;
alter table scheduler_failures_v29 enable row level security;
alter table workflow_acceptance_cases_v29 enable row level security;

drop policy if exists security_events_v29_select_final on security_events_v29;
create policy security_events_v29_select_final on security_events_v29
for select to authenticated using (
  user_id=auth.uid() or epas_v29_role()='gm'
);

drop policy if exists security_events_v29_write_final on security_events_v29;
create policy security_events_v29_write_final on security_events_v29
for all to authenticated using(false) with check(false);

drop policy if exists scheduler_failures_v29_select_final on scheduler_failures_v29;
create policy scheduler_failures_v29_select_final on scheduler_failures_v29
for select to authenticated using (
  epas_v29_role()='gm'
  or (epas_v29_role()='dm' and exists(
    select 1 from project_members pm
    where pm.project_id=scheduler_failures_v29.project_id
      and pm.user_id=auth.uid() and pm.active and pm.role='dm'
  ))
);

drop policy if exists scheduler_failures_v29_write_final on scheduler_failures_v29;
create policy scheduler_failures_v29_write_final on scheduler_failures_v29
for all to authenticated using(false) with check(false);

drop policy if exists workflow_acceptance_cases_v29_select_final on workflow_acceptance_cases_v29;
create policy workflow_acceptance_cases_v29_select_final on workflow_acceptance_cases_v29
for select to authenticated using (epas_v29_role() in ('gm','dm'));

drop policy if exists workflow_acceptance_cases_v29_write_final on workflow_acceptance_cases_v29;
create policy workflow_acceptance_cases_v29_write_final on workflow_acceptance_cases_v29
for all to authenticated using(false) with check(false);

-- ================================================================
-- 2. Stakeholder-safe schedule queue and timeline wrappers.
--    Internal users receive operational detail; stakeholders receive
--    phase-appropriate business status only.
-- ================================================================
create or replace function epas_schedule_queue_v30(p_project_id uuid default null)
returns table(
  schedule_id uuid, project_id uuid, vessel_id uuid, phase text, cycle_number integer,
  schedule_status text, schedule_config_status text, due_basis text, due_basis_reference text,
  due_basis_date date, next_due_date date, window_start date, window_end date,
  current_rfi_id uuid, stakeholder_safe boolean
)
language plpgsql security definer stable set search_path=public as $$
declare role_name text;
begin
  role_name:=epas_v29_role();
  if role_name is null then raise exception 'Not authenticated'; end if;
  if p_project_id is not null and not exists(
    select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active
  ) then raise exception 'Not authorized for project'; end if;
  return query
  select s.id,s.project_id,s.vessel_id,s.phase,s.cycle_number,s.status,s.schedule_config_status,
         case when role_name in ('gm','dm') then s.due_basis else s.due_basis end,
         case when role_name in ('gm','dm') then s.due_basis_reference else null end,
         case when role_name in ('gm','dm') then s.due_basis_date else null end,
         s.next_due_date,s.window_start,s.window_end,s.current_rfi_id,
         (role_name not in ('gm','dm')) as stakeholder_safe
  from survey_schedules s
  where s.active
    and (p_project_id is null or s.project_id=p_project_id)
    and (
      role_name in ('gm','dm')
      or (role_name='shipyard' and s.phase='nsc_survey')
      or (role_name in ('owner','ship_management') and s.phase='in_service')
      or (role_name='surveyor' and exists(
        select 1 from rfis r where r.id=s.current_rfi_id and r.assigned_surveyor_id=auth.uid()
      ))
    )
  order by s.next_due_date nulls last,s.window_start nulls last,s.phase;
end;$$;
grant execute on function epas_schedule_queue_v30(uuid) to authenticated;

create or replace function epas_timeline_v30(p_project_id uuid,p_limit integer default 100)
returns table(event_id uuid,event_type text,occurred_at timestamptz,summary text,phase text,entity_id uuid)
language plpgsql security definer stable set search_path=public as $$
declare role_name text;
begin
  role_name:=epas_v29_role();
  if role_name is null or not epas_v29_can_access_project_phase(p_project_id,'plan_appraisal')
     and not epas_v29_can_access_project_phase(p_project_id,'nsc_survey')
     and not epas_v29_can_access_project_phase(p_project_id,'in_service')
  then raise exception 'Not authorized for project timeline'; end if;
  return query
  with ev as (
    select le.*, coalesce(le.metadata->>'phase', case when le.entity_type='rfi' then (select r.phase from rfis r where r.id=le.entity_id) end) as phase_resolved
    from lifecycle_events le where le.project_id=p_project_id
  )
  select ev.id,ev.event_type,ev.created_at,
    case
      when role_name in ('gm','dm') then coalesce(ev.note,ev.event_type)
      when role_name='shipyard' then case when ev.phase_resolved='nsc_survey' then coalesce(ev.note,ev.event_type) else 'NSC workflow event' end
      when role_name in ('owner','ship_management') then case when ev.phase_resolved='in_service' then coalesce(ev.note,ev.event_type) else 'In-Service workflow event' end
      else coalesce(ev.event_type,'Workflow event')
    end,
    ev.phase_resolved,ev.entity_id
  from ev
  where (
    role_name in ('gm','dm')
    or (role_name='shipyard' and ev.phase_resolved='nsc_survey')
    or (role_name in ('owner','ship_management') and ev.phase_resolved='in_service')
    or (role_name='surveyor' and exists(select 1 from rfis r where r.id=ev.entity_id and r.assigned_surveyor_id=auth.uid()))
    or (role_name in ('engineer','designer') and ev.phase_resolved='plan_appraisal')
  )
  order by ev.created_at desc limit greatest(1,least(p_limit,200));
end;$$;
grant execute on function epas_timeline_v30(uuid,integer) to authenticated;

-- ================================================================
-- 3. Role-scoped internal gate wrappers.
-- ================================================================
create or replace function epas_survey_start_gate_v30(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if role_name not in ('gm','dm','surveyor') then raise exception 'Internal survey readiness is not exposed to this role'; end if;
  return epas_survey_start_gate_v29(p_rfi_id);
end;$$;
grant execute on function epas_survey_start_gate_v30(uuid) to authenticated;

create or replace function epas_survey_submission_gate_v30(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if role_name not in ('gm','dm','surveyor') then raise exception 'Internal survey submission gate is not exposed to this role'; end if;
  return epas_survey_submission_gate_v29(p_rfi_id);
end;$$;
grant execute on function epas_survey_submission_gate_v30(uuid) to authenticated;

create or replace function epas_certificate_issuance_gate_v30(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare role_name text;
begin
  role_name:=epas_v29_role();
  if role_name not in ('gm','dm') then raise exception 'Certificate issuance gate is an internal management control'; end if;
  return epas_certificate_issuance_gate_v29(p_rfi_id,p_cert_type);
end;$$;
grant execute on function epas_certificate_issuance_gate_v30(uuid,text) to authenticated;

-- ================================================================
-- 4. Recurring-cycle idempotency and explicit cycle state.
-- ================================================================
alter table survey_cycle_instances add column if not exists completion_idempotency_key text;
alter table survey_cycle_instances add column if not exists phase_lifecycle text not null default 'ACTIVE';
create unique index if not exists ux_cycle_completion_idempotency_v30
  on survey_cycle_instances(completion_idempotency_key)
  where completion_idempotency_key is not null;

create or replace function epas_mark_in_service_cycle_complete_v30(p_rfi_id uuid,p_idempotency_key text)
returns survey_cycle_instances language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_schedules; c survey_cycle_instances; n survey_cycle_instances; role_name text; next_no integer; next_due date; new_id uuid;
begin
  if coalesce(trim(p_idempotency_key),'')='' then raise exception 'Idempotency key is required'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null or r.phase<>'in_service' then raise exception 'In-Service RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name not in ('gm','dm') then raise exception 'Only GM/DM may complete an In-Service cycle'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not authorized for project'; end if;
  select * into s from survey_schedules where project_id=r.project_id and vessel_id=r.vessel_id and phase='in_service' and active order by updated_at desc limit 1 for update;
  if s.id is null then raise exception 'Active In-Service schedule not found'; end if;
  select * into c from survey_cycle_instances where rfi_id=r.id for update;
  if c.id is null then
    select * into c from survey_cycle_instances where schedule_id=s.id and cycle_number=coalesce(s.cycle_number,1) for update;
  end if;
  if c.id is null then raise exception 'Survey cycle instance not found'; end if;
  if c.status='COMPLETED' then return c; end if;
  if c.completion_idempotency_key is not null and c.completion_idempotency_key=p_idempotency_key then return c; end if;
  c.completion_idempotency_key:=p_idempotency_key;
  update survey_cycle_instances set status='COMPLETED',completed_at=coalesce(completed_at,now()),completion_idempotency_key=p_idempotency_key,updated_at=now() where id=c.id;
  next_no:=c.cycle_number+1;
  next_due:=coalesce(s.next_due_date,current_date)+coalesce(s.survey_interval_months,12) * interval '1 month';
  if exists(select 1 from survey_cycle_instances where schedule_id=s.id and cycle_number=next_no) then
    select * into n from survey_cycle_instances where schedule_id=s.id and cycle_number=next_no limit 1;
  else
    insert into survey_cycle_instances(schedule_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,source_certificate_id,schedule_basis,schedule_basis_reference,phase_lifecycle)
    values(s.id,s.project_id,s.vessel_id,'in_service',next_no,'DUE',next_due::date,(next_due::date-coalesce(s.window_days_before,90)),(next_due::date+coalesce(s.window_days_after,30)),s.source_certificate_id,s.due_basis,s.due_basis_reference,'ACTIVE') returning * into n;
  end if;
  update survey_schedules set cycle_number=next_no,next_due_date=n.due_date,window_start=n.window_start,window_end=n.window_end,current_rfi_id=null,cycle_instance_id=n.id,phase_lifecycle='ACTIVE',last_cycle_idempotency_key=p_idempotency_key,updated_at=now() where id=s.id;
  return n;
end;$$;
grant execute on function epas_mark_in_service_cycle_complete_v30(uuid,text) to authenticated;

-- ================================================================
-- 5. Scope/checklist/package/assignment dependency invalidation.
-- ================================================================
alter table survey_assignment_acknowledgements add column if not exists ack_status text not null default 'ACTIVE';
alter table survey_assignment_acknowledgements add column if not exists invalidated_at timestamptz;
alter table survey_assignment_acknowledgements add column if not exists invalidation_reason text;

drop trigger if exists trg_assignment_dependency_invalidation_v30 on survey_assignments;
create or replace function epas_invalidate_assignment_dependencies_v30()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='UPDATE' and (new.assignment_version is distinct from old.assignment_version or new.surveyor_id is distinct from old.surveyor_id or new.status in ('REASSIGNED','CANCELLED')) then
    update survey_assignment_acknowledgements
      set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason='Assignment version or assignee changed'
      where assignment_id=new.id and ack_status='ACTIVE';
    update survey_rfi_drawings set package_state='REVOKED',revoked_at=now(),revoke_reason='Surveyor assignment changed'
      where rfi_id=new.rfi_id and package_state='ACTIVE';
    update survey_scope_acknowledgements
      set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason='Surveyor assignment changed'
      where rfi_id=new.rfi_id and ack_status='ACTIVE';
    update survey_checklist_instances
      set status='INVALIDATED',invalidated_at=now(),invalidation_reason='Surveyor assignment changed'
      where rfi_id=new.rfi_id and status in ('OPEN','COMPLETE');
    update survey_executions set basis_frozen_at=null,updated_at=now() where rfi_id=new.rfi_id;
  end if;
  return new;
end;$$;
create trigger trg_assignment_dependency_invalidation_v30
before update on survey_assignments
for each row execute function epas_invalidate_assignment_dependencies_v30();

create or replace function epas_invalidate_scope_dependencies_v30()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.current_version is distinct from old.current_version then
    update survey_scope_acknowledgements set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason='Scope version changed'
      where rfi_id=new.rfi_id and ack_status='ACTIVE';
    update survey_drawing_package_acknowledgements set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason='Scope version changed'
      where rfi_id=new.rfi_id and ack_status='ACTIVE';
    update survey_rfi_drawings set package_state='REVOKED',revoked_at=now(),revoke_reason='Scope version changed'
      where rfi_id=new.rfi_id and package_state='ACTIVE';
    update survey_checklist_instances set status='INVALIDATED',invalidated_at=now(),invalidation_reason='Scope version changed'
      where rfi_id=new.rfi_id and status in ('OPEN','COMPLETE');
    update survey_executions set basis_frozen_at=null,updated_at=now() where rfi_id=new.rfi_id;
  end if;
  return new;
end;$$;
drop trigger if exists trg_scope_dependency_invalidation_v30 on survey_scopes;
create trigger trg_scope_dependency_invalidation_v30
before update on survey_scopes
for each row execute function epas_invalidate_scope_dependencies_v30();

-- ================================================================
-- 6. Survey report/file integrity: actual file hash and metadata required.
-- ================================================================
alter table survey_reports add column if not exists report_storage_path text;
alter table survey_reports add column if not exists report_file_name text;
alter table survey_reports add column if not exists report_size_bytes bigint;
alter table survey_reports add column if not exists report_mime_type text;

create or replace function epas_validate_survey_report_artifact_v30()
returns trigger language plpgsql as $$
begin
  if new.report_storage_path is null or trim(new.report_storage_path)='' then raise exception 'Controlled survey report storage path is required'; end if;
  if new.report_sha256 is null or length(new.report_sha256)<>64 then raise exception 'Actual survey report SHA-256 is required'; end if;
  if new.report_size_bytes is null or new.report_size_bytes<=0 then raise exception 'Survey report size is required'; end if;
  if lower(coalesce(new.report_mime_type,''))<>'application/pdf' then raise exception 'Survey report must be PDF'; end if;
  if new.report_storage_path not like 'projects/%/survey-reports/%' then raise exception 'Survey report must use controlled storage path'; end if;
  return new;
end;$$;
drop trigger if exists trg_validate_survey_report_artifact_v30 on survey_reports;
create trigger trg_validate_survey_report_artifact_v30
before insert or update on survey_reports
for each row execute function epas_validate_survey_report_artifact_v30();

create or replace function epas_submit_survey_report_v30(
  p_rfi_id uuid,p_report_note text,p_observations jsonb,p_evidence_path text,p_evidence_sha256 text,
  p_mime_type text,p_size_bytes bigint,p_location text,p_survey_date date,p_attendance text,p_declaration text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare r rfis; role_name text; g jsonb;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name<>'surveyor' or r.assigned_surveyor_id<>auth.uid() then raise exception 'Only the assigned Surveyor may submit this report'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not authorized for project'; end if;
  if p_evidence_sha256 is null or length(p_evidence_sha256)<>64 then raise exception 'Actual uploaded PDF SHA-256 is required'; end if;
  if p_size_bytes is null or p_size_bytes<=0 then raise exception 'Uploaded report size is required'; end if;
  if lower(coalesce(p_mime_type,''))<>'application/pdf' then raise exception 'Survey report must be a PDF'; end if;
  if p_evidence_path is null or p_evidence_path not like 'projects/'||r.project_id::text||'/survey-reports/%' then raise exception 'Controlled project report path is required'; end if;
  g:=epas_survey_submission_gate_v30(p_rfi_id);
  if coalesce((g->>'gate_passed')::boolean,false)=false then raise exception 'Survey report gate has not passed'; end if;
  return epas_submit_survey_report_v29(p_rfi_id,p_report_note,p_observations,p_evidence_path,p_evidence_sha256,p_mime_type,p_size_bytes,p_location,p_survey_date,p_attendance,p_declaration);
end;$$;
grant execute on function epas_submit_survey_report_v30(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;
revoke all on function epas_submit_survey_report_v29(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) from authenticated;

-- ================================================================
-- 7. Explicit internal certificate gate only; stakeholder-safe status is separate.
-- ================================================================
create or replace function epas_certificate_status_v30(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; c certificates; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if not epas_v29_can_access_project_phase(r.project_id,r.phase) then raise exception 'Not authorized for certificate status'; end if;
  select * into c from certificates where rfi_id=r.id order by created_at desc limit 1;
  return jsonb_build_object('status',coalesce(c.status,'pending'),'certificate_type',c.cert_type,'certificate_id',c.id,'safe',role_name not in ('gm','dm'));
end;$$;
grant execute on function epas_certificate_status_v30(uuid) to authenticated;

-- ================================================================
-- 8. Final privilege audit registry and explicit legacy revocations.
-- ================================================================
create table if not exists epas_privilege_registry_v30(
  routine_name text primary key,
  allowed_roles text[] not null,
  purpose text not null,
  legacy boolean not null default false,
  reviewed_at timestamptz not null default now()
);

insert into epas_privilege_registry_v30(routine_name,allowed_roles,purpose,legacy) values
('epas_schedule_queue_v30','{gm,dm,owner,ship_management,shipyard,surveyor}','Stakeholder-safe survey schedule queue',false),
('epas_timeline_v30','{gm,dm,engineer,surveyor,designer,owner,ship_management,shipyard}','Role-filtered project timeline',false),
('epas_survey_start_gate_v30','{gm,dm,surveyor}','Internal survey readiness gate',false),
('epas_survey_submission_gate_v30','{gm,dm,surveyor}','Internal report submission gate',false),
('epas_certificate_issuance_gate_v30','{gm,dm}','Internal certificate issuance gate',false),
('epas_mark_in_service_cycle_complete_v30','{gm,dm}','Cycle completion control',false),
('epas_submit_survey_report_v30','{surveyor}','Controlled report submission',false),
('epas_certificate_status_v30','{gm,dm,owner,ship_management,shipyard}','Stakeholder-safe certificate status',false)
on conflict(routine_name) do update set allowed_roles=excluded.allowed_roles,purpose=excluded.purpose,reviewed_at=now();

-- Explicitly revoke historically broad, high-risk lifecycle functions from authenticated.
do $$
declare r record;
  legacy_names text[] := array[
    'epas_clear_survey_observation','epas_close_project','epas_issue_certificate',
    'epas_finalize_interim_certificate','epas_refresh_all_survey_schedules_as_operator',
    'epas_generate_survey_due_notifications_as_operator','epas_sync_survey_schedule_v26',
    'epas_sync_survey_schedule_v27','epas_refresh_vessel_survey_status_v26',
    'epas_refresh_vessel_survey_status_v27','epas_refresh_vessel_survey_status_v28',
    'epas_mark_in_service_cycle_complete','epas_mark_in_service_cycle_complete_v27',
    'epas_mark_in_service_cycle_complete_v28','epas_mark_in_service_cycle_complete_v29',
    'epas_survey_start_gate_v26','epas_survey_start_gate_v27','epas_survey_start_gate_v28',
    'epas_survey_submission_gate','epas_survey_submission_gate_v26','epas_survey_submission_gate_v27','epas_survey_submission_gate_v28',
    'epas_certificate_issuance_gate','epas_register_observation_evidence','epas_stakeholder_create_scheduled_in_service_rfi'
  ];
begin
  for r in select p.oid,p.proname,pg_get_function_identity_arguments(p.oid) args
           from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname=any(legacy_names)
  loop
    execute format('revoke all on function public.%I(%s) from authenticated',r.proname,r.args);
    insert into epas_privilege_registry_v30(routine_name,allowed_roles,purpose,legacy)
    values(r.proname,'{}','Legacy function revoked from authenticated',true)
    on conflict(routine_name) do update set legacy=true,reviewed_at=now();
  end loop;
end$$;

-- Safe legacy bridge for stakeholder scheduled RFI initiation; phase policy is enforced here.
create or replace function epas_stakeholder_create_scheduled_in_service_rfi_v30(p_schedule_id uuid,p_scope text,p_requested_date date,p_priority text,p_note text)
returns rfis language plpgsql security definer set search_path=public as $$
declare s survey_schedules; v vessels; pr projects; role_name text; r rfis;
begin
  role_name:=epas_v29_role();
  if role_name not in ('owner','ship_management') then raise exception 'Only Owner or Ship Management may initiate In-Service RFI'; end if;
  select * into s from survey_schedules where id=p_schedule_id and phase='in_service' and active for update;
  if s.id is null then raise exception 'In-Service schedule not found'; end if;
  select * into v from vessels where id=s.vessel_id;
  select * into pr from projects where id=s.project_id;
  if not epas_is_project_member(s.project_id) then raise exception 'Not authorized for project'; end if;
  if s.schedule_config_status<>'CONFIGURED' then raise exception 'Survey schedule requires configuration before RFI initiation'; end if;
  if s.current_rfi_id is not null and exists(select 1 from rfis rr where rr.id=s.current_rfi_id and rr.status not in ('closed','certificate_issued')) then raise exception 'An In-Service RFI is already active for this cycle'; end if;
  insert into rfis(project_id,vessel_id,phase,survey_type,scope_note,requested_date,priority,requested_by,status)
  values(s.project_id,s.vessel_id,'in_service','In-Service Survey',p_scope,p_requested_date,p_priority,auth.uid(),'pending_allocation') returning * into r;
  update survey_cycle_instances set rfi_id=r.id,status='RFI_OPEN',updated_at=now() where id=s.cycle_instance_id;
  update survey_schedules set current_rfi_id=r.id,phase_lifecycle='ACTIVE',updated_at=now() where id=s.id;
  return r;
end;$$;
grant execute on function epas_stakeholder_create_scheduled_in_service_rfi_v30(uuid,text,date,text,text) to authenticated;

-- ================================================================
-- 9. Audit-chain protection and operational metadata.
-- ================================================================
alter table audit_log add column if not exists previous_hash text;
alter table audit_log add column if not exists event_hash text;
create or replace function epas_audit_chain_hash_v30()
returns trigger language plpgsql security definer set search_path=public as $$
declare prev text;
begin
  select event_hash into prev from audit_log order by created_at desc limit 1;
  new.previous_hash:=prev;
  new.event_hash:=encode(digest(coalesce(prev,'')||'|'||coalesce(new.action,'')||'|'||coalesce(new.project_id::text,'')||'|'||coalesce(new.details::text,'')||'|'||coalesce(new.created_at::text,''),'sha256'),'hex');
  return new;
end;$$;
drop trigger if exists trg_audit_chain_hash_v30 on audit_log;
create trigger trg_audit_chain_hash_v30 before insert on audit_log for each row execute function epas_audit_chain_hash_v30();

-- ================================================================
-- 10. Scheduler escalation policy.
-- ================================================================
alter table scheduler_failures_v29 add column if not exists next_retry_at timestamptz;
alter table scheduler_failures_v29 add column if not exists escalated_at timestamptz;
alter table scheduler_failures_v29 add column if not exists last_error_hash text;

create or replace function epas_scheduler_health_v30()
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare open_failures integer; recent_errors integer; latest scheduler_runs;
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Scheduler health is internal'; end if;
  select count(*) into open_failures from scheduler_failures_v29 where status in ('OPEN','RETRYING');
  select count(*) into recent_errors from scheduler_runs where error_count>0 and started_at>now()-interval '24 hours';
  select * into latest from scheduler_runs order by started_at desc limit 1;
  return jsonb_build_object('open_failures',open_failures,'recent_error_runs',recent_errors,'latest_run',to_jsonb(latest),'health_state',case when open_failures>0 or recent_errors>0 then 'DEGRADED' else 'HEALTHY' end);
end;$$;
grant execute on function epas_scheduler_health_v30() to authenticated;

-- ================================================================
-- 11. Final acceptance cases.
-- ================================================================
insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V30_NEW_RLS_TABLES','all','all','All v2.9 operational and audit tables have RLS and deny direct client writes',true,'P0'),
('V30_STAKEHOLDER_SCHEDULE_FILTER','shipyard','nsc_survey','Shipyard receives NSC schedule only and no internal gate detail',true,'P0'),
('V30_STAKEHOLDER_CERT_STATUS','owner','in_service','Owner receives certificate status, not internal issuance gate diagnostics',false,'P0'),
('V30_CYCLE_IDEMPOTENCY','gm','in_service','Completing the same cycle twice with one idempotency key creates exactly one next cycle',true,'P0'),
('V30_SCOPE_INVALIDATES_DEPENDENCIES','dm','nsc_survey|in_service','Scope amendment invalidates scope/package/checklist/execution basis',false,'P0'),
('V30_ASSIGNMENT_INVALIDATES_DEPENDENCIES','dm','nsc_survey|in_service','Reassignment invalidates prior acknowledgement and package readiness',false,'P0'),
('V30_ACTUAL_REPORT_HASH','surveyor','nsc_survey|in_service','Survey report requires actual file SHA-256 and PDF metadata',true,'P0'),
('V30_LEGACY_PRIVILEGE_LOCKDOWN','all','all','High-risk legacy lifecycle RPCs are not executable by authenticated users',true,'P0'),
('V30_AUDIT_CHAIN','gm','all','Audit log records previous hash and event hash in tamper-evident sequence',false,'P1'),
('V30_SCHEDULER_HEALTH','gm','all','Scheduler failures are observable and escalate to degraded health',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,negative=excluded.negative,priority=excluded.priority;

commit;
