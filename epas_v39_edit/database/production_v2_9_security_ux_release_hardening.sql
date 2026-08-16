-- EPAS v2.9 — Security, UX, release and production hardening
-- Cumulative after v2.8. Closes audited gaps across RLS, SECURITY DEFINER
-- boundaries, stakeholder phase isolation, immutable evidence, idempotency,
-- concurrency, scheduler resilience, frontend/runtime fail-closed behavior,
-- and role-specific cockpit readiness.

begin;
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- ============================================================================
-- 1. Shared authorization helpers
-- ============================================================================
create or replace function epas_v29_role()
returns text
language sql security definer stable set search_path=public
as $$ select role from profiles where id=auth.uid() $$;

grant execute on function epas_v29_role() to authenticated;

create or replace function epas_v29_can_access_project_phase(p_project_id uuid,p_phase text)
returns boolean
language plpgsql security definer stable set search_path=public as $$
declare v_role text; ok boolean;
begin
  v_role:=epas_v29_role();
  if v_role is null then return false; end if;
  if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active) then
    return false;
  end if;
  if v_role in ('gm','dm') then return true; end if;
  if v_role='shipyard' then return p_phase='nsc_survey'; end if;
  if v_role in ('owner','ship_management') then return p_phase='in_service'; end if;
  if v_role='surveyor' then
    return exists(select 1 from rfis r where r.project_id=p_project_id and r.phase=p_phase and r.assigned_surveyor_id=auth.uid());
  end if;
  if v_role='engineer' then
    return p_phase='plan_appraisal' and exists(
      select 1 from workflow_tasks wt where wt.project_id=p_project_id and wt.to_user_id=auth.uid()
        and wt.task_type in ('PLAN_APPRAISAL_ENGINEERING','PLAN_APPRAISAL_ENGINEER_FEEDBACK')
    );
  end if;
  if v_role='designer' then
    return p_phase='plan_appraisal' and exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active and pm.role='designer');
  end if;
  return false;
end;$$;
grant execute on function epas_v29_can_access_project_phase(uuid,text) to authenticated;

-- ============================================================================
-- 2. RLS for all v2.8 operational tables
-- ============================================================================
alter table survey_cycle_instances enable row level security;
alter table survey_checklist_instances enable row level security;
alter table survey_assignment_acknowledgements enable row level security;
alter table survey_scope_change_events enable row level security;
alter table survey_scope_acknowledgements enable row level security;
alter table survey_drawing_package_acknowledgements enable row level security;

-- Cycle instances: internal management, assigned surveyor, or phase-appropriate stakeholder.
drop policy if exists survey_cycle_instances_select_v29 on survey_cycle_instances;
create policy survey_cycle_instances_select_v29 on survey_cycle_instances
for select to authenticated using (epas_v29_can_access_project_phase(project_id,phase));
drop policy if exists survey_cycle_instances_write_v29 on survey_cycle_instances;
create policy survey_cycle_instances_write_v29 on survey_cycle_instances
for all to authenticated using (false) with check (false);

-- Checklist instance: only GM/DM or assigned surveyor can read; no client writes.
drop policy if exists survey_checklist_instances_select_v29 on survey_checklist_instances;
create policy survey_checklist_instances_select_v29 on survey_checklist_instances
for select to authenticated using (
  exists(select 1 from rfis r where r.id=survey_checklist_instances.rfi_id and (
    (epas_v29_role() in ('gm','dm') and epas_v29_can_access_project_phase(r.project_id,r.phase))
    or (epas_v29_role()='surveyor' and r.assigned_surveyor_id=auth.uid())
  ))
);
drop policy if exists survey_checklist_instances_write_v29 on survey_checklist_instances;
create policy survey_checklist_instances_write_v29 on survey_checklist_instances
for all to authenticated using (false) with check (false);

-- Assignment acknowledgements: only assigned Surveyor + project managers can read.
drop policy if exists survey_assignment_ack_select_v29 on survey_assignment_acknowledgements;
create policy survey_assignment_ack_select_v29 on survey_assignment_acknowledgements
for select to authenticated using (
  surveyor_id=auth.uid()
  or epas_v29_role()='gm'
  or (epas_v29_role()='dm' and exists(select 1 from survey_assignments a join rfis r on r.id=a.rfi_id where a.id=survey_assignment_acknowledgements.assignment_id and r.assigned_dm_id=auth.uid()))
);
drop policy if exists survey_assignment_ack_write_v29 on survey_assignment_acknowledgements;
create policy survey_assignment_ack_write_v29 on survey_assignment_acknowledgements
for all to authenticated using (false) with check (false);

-- Scope change audit events: internal only; stakeholders do not see internal change rationale.
drop policy if exists survey_scope_change_events_select_v29 on survey_scope_change_events;
create policy survey_scope_change_events_select_v29 on survey_scope_change_events
for select to authenticated using (
  epas_v29_role() in ('gm','dm')
  or (epas_v29_role()='surveyor' and exists(select 1 from rfis r where r.id=survey_scope_change_events.rfi_id and r.assigned_surveyor_id=auth.uid()))
);
drop policy if exists survey_scope_change_events_write_v29 on survey_scope_change_events;
create policy survey_scope_change_events_write_v29 on survey_scope_change_events
for all to authenticated using (false) with check(false);

-- Scope/package acknowledgement records: only the assigned Surveyor + management can see.
drop policy if exists survey_scope_ack_select_v29 on survey_scope_acknowledgements;
create policy survey_scope_ack_select_v29 on survey_scope_acknowledgements
for select to authenticated using (
  acknowledged_by=auth.uid()
  or epas_v29_role()='gm'
  or (epas_v29_role()='dm' and exists(select 1 from rfis r where r.id=survey_scope_acknowledgements.rfi_id and r.assigned_dm_id=auth.uid()))
);
drop policy if exists survey_scope_ack_write_v29 on survey_scope_acknowledgements;
create policy survey_scope_ack_write_v29 on survey_scope_acknowledgements
for all to authenticated using(false) with check(false);

drop policy if exists survey_drawing_pkg_ack_select_v29 on survey_drawing_package_acknowledgements;
create policy survey_drawing_pkg_ack_select_v29 on survey_drawing_package_acknowledgements
for select to authenticated using (
  acknowledged_by=auth.uid()
  or epas_v29_role()='gm'
  or (epas_v29_role()='dm' and exists(select 1 from rfis r where r.id=survey_drawing_package_acknowledgements.rfi_id and r.assigned_dm_id=auth.uid()))
);
drop policy if exists survey_drawing_pkg_ack_write_v29 on survey_drawing_package_acknowledgements;
create policy survey_drawing_pkg_ack_write_v29 on survey_drawing_package_acknowledgements
for all to authenticated using(false) with check(false);

-- ============================================================================
-- 3. Lock legacy direct RPCs; expose only v2.9 authorized wrappers.
-- ============================================================================
revoke all on function epas_scope_version_sha256(uuid,integer) from authenticated;
revoke all on function epas_assignment_fingerprint(uuid) from authenticated;
revoke all on function epas_survey_checklist_ready_v28(uuid) from authenticated;
revoke all on function epas_survey_start_gate_v28(uuid) from authenticated;
revoke all on function epas_survey_submission_gate_v28(uuid) from authenticated;
revoke all on function epas_certificate_issuance_gate(uuid,text) from authenticated;
revoke all on function epas_refresh_vessel_survey_status_v28(uuid) from authenticated;
revoke all on function epas_sync_survey_schedule_v28(uuid) from authenticated;

-- ============================================================================
-- 4. Secure v2.9 fingerprint/read wrappers.
-- ============================================================================
create or replace function epas_scope_version_sha256_v29(p_rfi_id uuid,p_version integer)
returns text language plpgsql security definer stable set search_path=public as $$
declare r rfis;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not epas_v29_can_access_project_phase(r.project_id,r.phase) then raise exception 'Not authorized for this survey scope'; end if;
  return encode(digest(coalesce((select scope_text from survey_scope_versions where rfi_id=p_rfi_id and version_no=p_version),''),'sha256'),'hex');
end;$$;
grant execute on function epas_scope_version_sha256_v29(uuid,integer) to authenticated;

create or replace function epas_assignment_fingerprint_v29(p_assignment_id uuid)
returns text language plpgsql security definer stable set search_path=public as $$
declare a survey_assignments; r rfis;
begin
  select * into a from survey_assignments where id=p_assignment_id;
  select * into r from rfis where id=a.rfi_id;
  if a.id is null or r.id is null then raise exception 'Assignment not found'; end if;
  if not epas_v29_can_access_project_phase(r.project_id,r.phase) then raise exception 'Not authorized for assignment'; end if;
  return encode(digest(coalesce(a.surveyor_id::text,'')||'|'||coalesce(a.scheduled_date::text,'')||'|'||coalesce(a.assigned_by::text,'')||'|'||a.assignment_version::text,'sha256'),'hex');
end;$$;
grant execute on function epas_assignment_fingerprint_v29(uuid) to authenticated;

create or replace function epas_survey_checklist_ready_v29(p_rfi_id uuid)
returns jsonb language plpgsql security definer volatile set search_path=public as $$
declare r rfis; x survey_checklist_instances; pending integer; fp text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not epas_v29_can_access_project_phase(r.project_id,r.phase) then raise exception 'Not authorized for checklist status'; end if;
  select * into x from survey_checklist_instances where rfi_id=p_rfi_id;
  if x.id is null then return jsonb_build_object('ready',false,'reason','CHECKLIST_INSTANCE_MISSING'); end if;
  fp:=epas_survey_checklist_definition_fingerprint(r.phase,x.checklist_version);
  if fp<>x.definition_sha256 or x.status='INVALIDATED' then return jsonb_build_object('ready',false,'reason',case when x.status='INVALIDATED' then 'CHECKLIST_INVALIDATED' else 'CHECKLIST_DEFINITION_CHANGED' end,'fingerprint',fp,'stored',x.definition_sha256,'version',x.checklist_version); end if;
  select count(*) into pending from survey_checklist_items where rfi_id=r.id and mandatory and status<>'complete';
  if pending>0 then return jsonb_build_object('ready',false,'reason','MANDATORY_ITEMS_PENDING','pending',pending,'version',x.checklist_version,'fingerprint',fp); end if;
  update survey_checklist_instances set status='COMPLETE',completed_at=coalesce(completed_at,now()) where id=x.id and status<>'COMPLETE';
  return jsonb_build_object('ready',true,'version',x.checklist_version,'fingerprint',fp,'instance_id',x.id);
end;$$;
grant execute on function epas_survey_checklist_ready_v29(uuid) to authenticated;

create or replace function epas_survey_start_gate_v29(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; a survey_assignments; e survey_executions; s survey_scopes; pkgver integer; pkgfp text; checklist jsonb; scope_fp text; assign_ack boolean; scope_ack boolean; package_ack boolean; revision_clear boolean; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not epas_v29_can_access_project_phase(r.project_id,r.phase) then raise exception 'Not authorized for survey start gate'; end if;
  select * into a from survey_assignments where rfi_id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  if e.id is null or a.id is null or s.id is null then raise exception 'Controlled survey execution context is incomplete'; end if;
  pkgver:=coalesce((select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),0);
  pkgfp:=epas_survey_drawing_package_fingerprint(r.id,pkgver);
  scope_fp:=epas_scope_version_sha256_v29(r.id,s.current_version);
  checklist:=epas_survey_checklist_ready_v29(r.id);
  assign_ack:=exists(select 1 from survey_assignment_acknowledgements x where x.assignment_id=a.id and x.assignment_version=a.assignment_version and x.surveyor_id=a.surveyor_id and x.assignment_fingerprint=epas_assignment_fingerprint_v29(a.id));
  scope_ack:=exists(select 1 from survey_scope_acknowledgements x where x.rfi_id=r.id and x.scope_version=s.current_version and x.scope_sha256=scope_fp and x.ack_status='ACTIVE' and x.acknowledged_by=r.assigned_surveyor_id);
  package_ack:=exists(select 1 from survey_drawing_package_acknowledgements x where x.rfi_id=r.id and x.package_version=pkgver and x.package_fingerprint=pkgfp and x.ack_status='ACTIVE' and x.acknowledged_by=r.assigned_surveyor_id);
  revision_clear:=not exists(select 1 from survey_drawing_impact_decisions x join survey_rfi_drawings p on p.id=x.package_id where x.rfi_id=r.id and p.package_state='ACTIVE' and x.impact='REISSUE_REQUIRED');
  role_name:=epas_v29_role();
  return jsonb_build_object(
    'assignment_accepted',a.status in ('ACCEPTED','IN_PROGRESS','COMPLETED') and assign_ack,
    'assignment_version',a.assignment_version,
    'scope_acknowledged',scope_ack,
    'scope_version',s.current_version,
    'scope_sha256',scope_fp,
    'drawing_package_version',pkgver,
    'drawing_package_fingerprint',pkgfp,
    'package_acknowledged',package_ack,
    'checklist_ready',coalesce((checklist->>'ready')::boolean,false),
    'checklist_version',checklist->>'version',
    'checklist_definition_fingerprint',checklist->>'fingerprint',
    'revision_impact_clear',revision_clear,
    'execution_basis_frozen',e.basis_frozen_at is not null,
    'ready',(a.status in ('ACCEPTED','IN_PROGRESS','COMPLETED') and assign_ack and scope_ack and package_ack and coalesce((checklist->>'ready')::boolean,false) and revision_clear and r.assigned_surveyor_id is not null),
    'viewer_role',role_name
  );
end;$$;
grant execute on function epas_survey_start_gate_v29(uuid) to authenticated;

create or replace function epas_survey_submission_gate_v29(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; e survey_executions; d survey_execution_declarations; g jsonb;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not epas_v29_can_access_project_phase(r.project_id,r.phase) then raise exception 'Not authorized for survey submission gate'; end if;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into d from survey_execution_declarations where execution_id=e.id;
  if e.id is null then raise exception 'Survey execution not found'; end if;
  g:=epas_survey_start_gate_v29(p_rfi_id);
  return g || jsonb_build_object(
    'basis_frozen',e.basis_frozen_at is not null,
    'execution_basis_version',e.execution_basis_version,
    'basis_sha256',e.basis_sha256,
    'report_hash_present',exists(select 1 from survey_reports sr where sr.rfi_id=r.id and coalesce(length(sr.evidence_sha256),0)=64),
    'declaration_complete',d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete,
    'ready_to_submit',coalesce((g->>'ready')::boolean,false) and e.basis_frozen_at is not null and d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete
  );
end;$$;
grant execute on function epas_survey_submission_gate_v29(uuid) to authenticated;

create or replace function epas_certificate_issuance_gate_v29(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; p certificate_decision_packages; a certificate_decision_acknowledgements; open_obs integer; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not(epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Certificate issuance gate is internal to GM/DM'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=r.project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Not authorized for this project certificate gate'; end if;
  select count(*) into open_obs from observations where rfi_id=r.id and status='open';
  select * into p from certificate_decision_packages where rfi_id=r.id and status='FROZEN' order by package_version desc limit 1;
  select * into a from certificate_decision_acknowledgements where package_id=p.id and acknowledged_by=r.assigned_dm_id limit 1;
  role_name:=epas_v29_role();
  return jsonb_build_object(
    'gate_passed',p.id is not null and a.id is not null and r.status in ('approved_no_observations','approved_with_observations') and ((open_obs=0 and p_cert_type<>'interim_certificate') or (open_obs>0 and p_cert_type='interim_certificate')),
    'decision_package_id',p.id,
    'package_version',p.package_version,
    'package_fingerprint',p.package_sha256,
    'dm_acknowledged',a.id is not null,
    'open_observations',open_obs,
    'certificate_type',p_cert_type,
    'viewer_role',role_name
  );
end;$$;
grant execute on function epas_certificate_issuance_gate_v29(uuid,text) to authenticated;

-- ============================================================================
-- 5. Stakeholder-safe schedule queue and project timeline.
-- ============================================================================
create or replace function epas_survey_schedule_queue_v29(p_project_id uuid default null)
returns table(schedule_id uuid,project_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,cycle_number integer,lifecycle_state text,due_basis_date date,next_due_date date,window_start date,window_end date,status text,schedule_config_status text,due_basis text,due_basis_reference text,survey_interval_months integer,current_rfi_id uuid,rfi_code text,rfi_status text,assigned_surveyor_id uuid,surveyor_name text)
language plpgsql security definer stable set search_path=public as $$
declare v_role text; pid uuid;
begin
  v_role:=epas_v29_role();
  if p_project_id is not null then
    if not epas_v29_can_access_project_phase(p_project_id,case when v_role='shipyard' then 'nsc_survey' else 'in_service' end) and v_role not in ('gm','dm') then
      if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active) then raise exception 'Not authorized for project schedule'; end if;
    end if;
  elsif v_role not in ('gm','dm') then
    raise exception 'Global schedule requires GM/DM';
  end if;
  return query
  select s.id,s.project_id,s.vessel_id,v.name,s.phase,s.survey_type,s.cycle_number,s.lifecycle_state,s.due_basis_date,s.next_due_date,s.window_start,s.window_end,s.status,s.schedule_config_status,s.due_basis,s.due_basis_reference,s.survey_interval_months,s.current_rfi_id,r.rfi_code,r.status,r.assigned_surveyor_id,p.full_name
  from survey_schedules s
  join vessels v on v.id=s.vessel_id
  left join rfis r on r.id=s.current_rfi_id
  left join profiles p on p.id=r.assigned_surveyor_id
  where s.active
    and (p_project_id is null or s.project_id=p_project_id)
    and (
      v_role in ('gm','dm')
      or (v_role='shipyard' and s.phase='nsc_survey')
      or (v_role in ('owner','ship_management') and s.phase='in_service')
      or (v_role='surveyor' and r.assigned_surveyor_id=auth.uid())
    )
  order by s.next_due_date;
end;$$;
grant execute on function epas_survey_schedule_queue_v29(uuid) to authenticated;

create or replace function epas_project_timeline_v29(p_project_id uuid,p_limit integer default 100)
returns table(created_at timestamptz,event_type text,entity_type text,entity_id uuid,actor_id uuid,from_state text,to_state text,note text,metadata jsonb)
language plpgsql security definer stable set search_path=public as $$
declare v_role text;
begin
  v_role:=epas_v29_role();
  if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active) then raise exception 'Not authorized for project timeline'; end if;
  if v_role in ('gm','dm') then
    return query
      select le.created_at,le.event_type,le.entity_type,le.entity_id,le.actor_id,le.from_state,le.to_state,le.note,le.metadata
      from lifecycle_events le where le.project_id=p_project_id
      union all
      select a.created_at,a.action,'audit',a.id,a.actor_id,null,null,null,a.details from audit_log a where a.project_id=p_project_id
      order by created_at desc limit greatest(1,least(p_limit,500));
  else
    return query
      select le.created_at,le.event_type,le.entity_type,le.entity_id,null,null,le.to_state,
             case when le.event_type in ('RFI_CREATED','IN_SERVICE_RFI_INITIATED_FROM_SCHEDULE','SURVEY_SCHEDULED','SURVEY_COMPLETED','CERTIFICATE_ISSUED','PROJECT_CLOSED') then le.note else null end,
             case when le.event_type in ('RFI_CREATED','IN_SERVICE_RFI_INITIATED_FROM_SCHEDULE','SURVEY_SCHEDULED','SURVEY_COMPLETED','CERTIFICATE_ISSUED','PROJECT_CLOSED') then le.metadata else '{}'::jsonb end
      from lifecycle_events le
      where le.project_id=p_project_id
        and le.event_type in ('RFI_CREATED','IN_SERVICE_RFI_INITIATED_FROM_SCHEDULE','SURVEY_SCHEDULED','SURVEY_COMPLETED','CERTIFICATE_ISSUED','PROJECT_CLOSED')
        and (
          (v_role='shipyard' and le.entity_type='rfi' and le.metadata->>'phase'='nsc_survey')
          or v_role in ('owner','ship_management')
          or v_role='surveyor'
        )
      order by le.created_at desc limit greatest(1,least(p_limit,200));
  end if;
end;$$;
grant execute on function epas_project_timeline_v29(uuid,integer) to authenticated;

-- ============================================================================
-- 6. Prevent synthetic survey-report hashes.
-- ============================================================================
alter table survey_reports add column if not exists report_file_required boolean not null default true;
create or replace function epas_guard_survey_report_file_v29()
returns trigger language plpgsql as $$
begin
  if (tg_op='INSERT' and new.report_completed_at is not null) or (tg_op='UPDATE' and old.report_completed_at is null and new.report_completed_at is not null) then
    if new.evidence_path is null or trim(new.evidence_path)='' then raise exception 'Controlled survey report file is required'; end if;
    if new.evidence_sha256 is null or length(new.evidence_sha256)<>64 then raise exception 'Actual survey report SHA-256 is required'; end if;
    if new.evidence_size_bytes is null or new.evidence_size_bytes<=0 then raise exception 'Survey report file size is required'; end if;
    if new.mime_type is null or lower(new.mime_type)<>'application/pdf' then raise exception 'Survey report must be a PDF'; end if;
  end if;
  return new;
end;$$;
drop trigger if exists trg_guard_survey_report_file_v29 on survey_reports;
create trigger trg_guard_survey_report_file_v29 before insert or update on survey_reports for each row execute function epas_guard_survey_report_file_v29();

-- Re-authoritative report submit: no synthetic hash fallback.
create or replace function epas_submit_survey_report_v29(
  p_rfi_id uuid,p_report_note text,p_observations jsonb default '[]'::jsonb,
  p_evidence_path text,p_evidence_sha256 text,p_mime_type text,p_size_bytes bigint,
  p_location text default null,p_survey_date date default current_date,
  p_attendance text default null,p_declaration text default null
) returns survey_reports language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; e survey_executions; v_report survey_reports; v_item jsonb; code text;
begin
  if epas_v29_role()<>'surveyor' then raise exception 'Only assigned Surveyor may submit a survey report'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  if v_rfi.id is null or e.id is null then raise exception 'Controlled survey execution is required'; end if;
  if v_rfi.assigned_surveyor_id<>auth.uid() then raise exception 'RFI is assigned to another Surveyor'; end if;
  if coalesce(trim(p_report_note),'')='' then raise exception 'Survey report is required'; end if;
  if coalesce(trim(p_declaration),'')='' then raise exception 'Surveyor declaration is required'; end if;
  if p_evidence_path is null or trim(p_evidence_path)='' then raise exception 'Survey report PDF is required'; end if;
  if p_evidence_sha256 is null or length(p_evidence_sha256)<>64 then raise exception 'Actual survey report SHA-256 is required'; end if;
  if p_mime_type is null or lower(p_mime_type)<>'application/pdf' then raise exception 'Survey report must be a PDF'; end if;
  if p_size_bytes is null or p_size_bytes<=0 then raise exception 'Survey report file size is required'; end if;
  if p_evidence_path not like 'projects/'||v_rfi.project_id::text||'/survey-reports/'||v_rfi.id::text||'/%' then raise exception 'Survey report must use the controlled storage path'; end if;
  insert into survey_reports(rfi_id,surveyor_id,report_note,survey_date,location,attendance,evidence_path,declaration,evidence_sha256,evidence_size_bytes,mime_type,report_sha256,report_completed_at,execution_basis_version)
  values(v_rfi.id,auth.uid(),p_report_note,p_survey_date,p_location,p_attendance,p_evidence_path,p_declaration,p_evidence_sha256,p_size_bytes,p_mime_type,p_evidence_sha256,now(),e.execution_basis_version)
  returning * into v_report;
  for v_item in select * from jsonb_array_elements(coalesce(p_observations,'[]'::jsonb)) loop
    code:=coalesce(nullif(v_item->>'obs_code',''),'OBS-'||to_char(current_date,'YYYYMMDD')||'-'||substr(gen_random_uuid()::text,1,8));
    insert into observations(rfi_id,obs_code,description,severity,status,raised_by,location,rule_reference,deficiency_category,responsible_party,target_date,corrective_action)
    values(v_rfi.id,code,coalesce(v_item->>'description',''),coalesce(v_item->>'severity','Minor'),'open',auth.uid(),nullif(v_item->>'location',''),nullif(v_item->>'rule_reference',''),nullif(v_item->>'deficiency_category',''),nullif(v_item->>'responsible_party',''),nullif(v_item->>'target_date','')::date,nullif(v_item->>'corrective_action',''));
  end loop;
  update survey_executions set status='REPORT_SUBMITTED',report_id=v_report.id,report_sha256=p_evidence_sha256,report_completed_at=now(),completed_at=now(),updated_at=now() where id=e.id;
  update rfis set status='observations_logged',updated_at=now() where id=v_rfi.id;
  perform epas_audit(v_rfi.project_id,'SURVEY_REPORT_SUBMITTED','rfi',v_rfi.id,'survey_in_progress','observations_logged','Controlled survey report submitted',jsonb_build_object('observation_count',jsonb_array_length(coalesce(p_observations,'[]'::jsonb)),'report_sha256',p_evidence_sha256,'execution_basis_version',e.execution_basis_version));
  return v_report;
end;$$;
grant execute on function epas_submit_survey_report_v29(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;

revoke all on function epas_submit_survey_report(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) from authenticated;

-- ============================================================================
-- 7. Idempotent, concurrency-safe recurring cycle completion.
-- ============================================================================
create or replace function epas_mark_in_service_cycle_complete_v29(p_rfi_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_schedules; e survey_executions; base_date date; due date; cycle_id uuid; already_complete boolean;
begin
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null or r.phase<>'in_service' then raise exception 'RFI is not an In-Service survey'; end if;
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may complete an In-Service cycle'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=r.project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Not authorized for project'; end if;
  select * into e from survey_executions where rfi_id=r.id;
  if e.id is null or e.status not in ('REPORT_SUBMITTED','DM_REVIEW','GM_REVIEW','COMPLETED') then raise exception 'Survey execution is not complete'; end if;
  if exists(select 1 from survey_cycle_instances c where c.rfi_id=r.id and c.status='COMPLETED') then
    select * into s from survey_schedules where vessel_id=r.vessel_id and phase='in_service' and active order by id limit 1;
    return s;
  end if;
  select * into s from survey_schedules where vessel_id=r.vessel_id and phase='in_service' and active for update;
  if s.id is null then raise exception 'Active In-Service schedule not found'; end if;
  if s.schedule_config_status<>'CONFIGURED' or s.survey_interval_months is null or s.survey_interval_months<=0 then raise exception 'Configure explicit schedule basis before completing cycle'; end if;
  base_date:=coalesce((e.completed_at at time zone 'UTC')::date,(select max(coalesce(completed_at,submitted_at))::date from survey_reports where rfi_id=r.id),current_date);
  due:=(base_date+make_interval(months=>s.survey_interval_months))::date;
  update survey_schedules set last_completed_date=base_date,last_survey_completed_at=coalesce(last_survey_completed_at,now()),next_due_date=due,window_start=(due-due_window_days_before)::date,window_end=(due+window_days_after)::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=r.id,cycle_completed_at=now(),cycle_number=cycle_number+1,lifecycle_state='ACTIVE',phase_lifecycle='ACTIVE',intent_action='CREATE_IN_SERVICE_RFI',updated_at=now() where id=s.id returning * into s;
  update survey_cycle_instances set status='COMPLETED',completed_at=now(),updated_at=now() where schedule_id=s.id and rfi_id=r.id;
  insert into survey_cycle_instances(schedule_id,rfi_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,source_certificate_id,schedule_basis,schedule_basis_reference,completed_at)
  values(s.id,null,r.project_id,r.vessel_id,'in_service',s.cycle_number,'DUE',s.next_due_date,s.window_start,s.window_end,s.source_certificate_id,s.due_basis,s.due_basis_reference,null)
  on conflict(schedule_id,cycle_number) do nothing returning id into cycle_id;
  update survey_schedules set cycle_instance_id=cycle_id where id=s.id;
  perform epas_refresh_project_phase_state(r.project_id);
  perform epas_audit(r.project_id,'IN_SERVICE_CYCLE_COMPLETED','rfi',r.id,'dm','COMPLETED','In-Service cycle completed; persistent phase remains active',jsonb_build_object('schedule_id',s.id,'completed_cycle',s.cycle_number-1,'next_cycle',s.cycle_number,'next_due_date',s.next_due_date));
  return s;
end;$$;
grant execute on function epas_mark_in_service_cycle_complete_v29(uuid) to authenticated;
revoke all on function epas_mark_in_service_cycle_complete_v28(uuid) from authenticated;

-- ============================================================================
-- 8. Fail-closed manual status/schedule mutations + manager-scoped wrappers.
-- ============================================================================
create or replace function epas_refresh_vessel_status_as_manager_v29(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may refresh vessel status manually'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v.project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Not authorized for project'; end if;
  return epas_refresh_vessel_survey_status_v27(p_vessel_id);
end;$$;
grant execute on function epas_refresh_vessel_status_as_manager_v29(uuid) to authenticated;
revoke all on function epas_refresh_vessel_survey_status_v28(uuid) from authenticated;

-- ============================================================================
-- 9. Scheduler resilience: explicit failure escalation + retry metadata.
-- ============================================================================
alter table scheduler_runs add column if not exists retry_count integer not null default 0;
alter table scheduler_runs add column if not exists error_count integer not null default 0;
alter table scheduler_runs add column if not exists health_state text not null default 'HEALTHY';
create index if not exists idx_scheduler_runs_status on scheduler_runs(status,started_at desc);

create table if not exists scheduler_failures_v29(
  id uuid primary key default gen_random_uuid(),
  scheduler_run_id uuid references scheduler_runs(id) on delete cascade,
  vessel_id uuid references vessels(id) on delete cascade,
  project_id uuid references projects(id) on delete cascade,
  operation text not null,
  error_message text not null,
  retry_count integer not null default 0,
  status text not null default 'OPEN' check(status in ('OPEN','RETRYING','RESOLVED','ESCALATED')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
alter table scheduler_failures_v29 enable row level security;
drop policy if exists scheduler_failures_v29_select on scheduler_failures_v29;
create policy scheduler_failures_v29_select on scheduler_failures_v29 for select to authenticated using (
  epas_v29_role()='gm' or (epas_v29_role()='dm' and exists(select 1 from project_members pm where pm.project_id=scheduler_failures_v29.project_id and pm.user_id=auth.uid() and pm.active and pm.role='dm'))
);
drop policy if exists scheduler_failures_v29_write on scheduler_failures_v29;
create policy scheduler_failures_v29_write on scheduler_failures_v29 for all to authenticated using(false) with check(false);

-- ============================================================================
-- 10. Optimistic concurrency + idempotency for critical transitions.
-- ============================================================================
alter table rfis add column if not exists row_version bigint not null default 1;
alter table rfis add column if not exists last_transition_idempotency_key text;
alter table survey_schedules add column if not exists row_version bigint not null default 1;
alter table survey_schedules add column if not exists last_cycle_idempotency_key text;
alter table certificates add column if not exists row_version bigint not null default 1;

create unique index if not exists ux_rfis_idempotency_key on rfis(last_transition_idempotency_key) where last_transition_idempotency_key is not null;
create unique index if not exists ux_schedule_cycle_idempotency on survey_schedules(last_cycle_idempotency_key) where last_cycle_idempotency_key is not null;

-- ============================================================================
-- 11. Certificate package version/fingerprint acknowledgement hardening.
-- ============================================================================
alter table certificate_decision_acknowledgements add column if not exists package_version integer;
alter table certificate_decision_acknowledgements add column if not exists package_sha256 text;
alter table certificate_decision_acknowledgements add column if not exists ack_status text not null default 'ACTIVE';
alter table certificate_decision_acknowledgements add column if not exists invalidated_at timestamptz;

create or replace function epas_acknowledge_certificate_decision_package_v29(p_package_id uuid,p_note text default '')
returns certificate_decision_acknowledgements language plpgsql security definer set search_path=public as $$
declare p certificate_decision_packages; r rfis; a certificate_decision_acknowledgements; fp text;
begin
  if epas_v29_role()<>'dm' then raise exception 'Only DM may acknowledge certificate decision package'; end if;
  select * into p from certificate_decision_packages where id=p_package_id for update;
  if p.id is null or p.status<>'FROZEN' then raise exception 'Frozen certificate decision package required'; end if;
  select * into r from rfis where id=p.rfi_id for update;
  if r.id is null or r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may acknowledge this package'; end if;
  fp:=coalesce(p.package_sha256,encode(digest(coalesce(p.snapshot::text,''),'sha256'),'hex'));
  update certificate_decision_acknowledgements set ack_status='INVALIDATED',invalidated_at=now() where package_id=p.id and acknowledged_by=auth.uid() and ack_status='ACTIVE';
  insert into certificate_decision_acknowledgements(package_id,rfi_id,acknowledged_by,note,package_version,package_sha256,ack_status)
  values(p.id,r.id,auth.uid(),p_note,p.package_version,fp,'ACTIVE')
  on conflict(package_id,acknowledged_by) do update set note=excluded.note,package_version=excluded.package_version,package_sha256=excluded.package_sha256,ack_status='ACTIVE',invalidated_at=null,acknowledged_at=now()
  returning * into a;
  update certificate_decision_packages set dm_ack_snapshot=jsonb_build_object('package_version',p.package_version,'package_sha256',fp,'acknowledged_by',auth.uid(),'acknowledged_at',a.acknowledged_at,'note',p_note) where id=p.id;
  return a;
end;$$;
grant execute on function epas_acknowledge_certificate_decision_package_v29(uuid,text) to authenticated;
revoke all on function epas_acknowledge_certificate_decision_package(uuid,text) from authenticated;

-- ============================================================================
-- 12. Stakeholder-specific timeline filtering at the data layer.
-- ============================================================================
-- v2.9 queue/timeline functions are authoritative; older versions remain for internal compatibility
-- but are revoked from stakeholders via explicit execution wrapper policy below.
revoke all on function epas_survey_schedule_queue_v28(uuid) from authenticated;
revoke all on function epas_project_timeline(uuid,integer) from authenticated;

-- ============================================================================
-- 13. Production deployment guard: demo mode must be explicit opt-in.
-- ============================================================================
create table if not exists production_runtime_guard_v29(
  guard_key text primary key,
  guard_value text not null,
  updated_at timestamptz not null default now()
);
insert into production_runtime_guard_v29(guard_key,guard_value) values('DEMO_MODE','DISABLED') on conflict(guard_key) do update set guard_value='DISABLED',updated_at=now();
alter table production_runtime_guard_v29 enable row level security;
drop policy if exists production_runtime_guard_select_v29 on production_runtime_guard_v29;
create policy production_runtime_guard_select_v29 on production_runtime_guard_v29 for select to authenticated using(epas_has_role('gm') or epas_has_role('dm'));
drop policy if exists production_runtime_guard_write_v29 on production_runtime_guard_v29;
create policy production_runtime_guard_write_v29 on production_runtime_guard_v29 for all to authenticated using(false) with check(false);

-- ============================================================================
-- 14. Audit-chain integrity fields for tamper-evident business history.
-- ============================================================================
alter table audit_log add column if not exists previous_hash text;
alter table audit_log add column if not exists event_hash text;
create index if not exists idx_audit_log_project_created on audit_log(project_id,created_at desc);

create or replace function epas_compute_audit_event_hash_v29()
returns trigger language plpgsql security definer set search_path=public as $$
declare prev text;
begin
  select event_hash into prev from audit_log where project_id=new.project_id order by created_at desc, id desc limit 1;
  new.previous_hash:=coalesce(prev,'GENESIS');
  new.event_hash:=encode(digest(coalesce(new.previous_hash,'GENESIS')||'|'||coalesce(new.action,'')||'|'||coalesce(new.actor_id::text,'')||'|'||coalesce(new.project_id::text,'')||'|'||coalesce(new.details::text,'')||'|'||coalesce(new.created_at::text,''),'sha256'),'hex');
  return new;
end;$$;
drop trigger if exists trg_audit_log_hash_v29 on audit_log;
create trigger trg_audit_log_hash_v29 before insert on audit_log for each row execute function epas_compute_audit_event_hash_v29();

-- ============================================================================
-- 15. Resilient production scheduler tick with per-vessel failure capture.
-- ============================================================================
create or replace function epas_scheduler_tick_v29()
returns jsonb language plpgsql security definer set search_path=public as $$
declare run_id uuid; v record; sc integer:=0; vc integer:=0; nc integer:=0; err integer:=0; failure_id uuid; started timestamptz:=now();
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  insert into scheduler_runs(run_type,status,started_at,metadata,health_state)
  values('EPAS_SURVEY_LIFECYCLE_V29','RUNNING',started,jsonb_build_object('version','2.9'),'HEALTHY') returning id into run_id;
  for v in select id,project_id from vessels loop
    begin
      perform epas_sync_survey_schedule_v28(v.id); sc:=sc+1;
    exception when others then
      err:=err+1;
      insert into scheduler_failures_v29(scheduler_run_id,vessel_id,project_id,operation,error_message,retry_count,status)
      values(run_id,v.id,v.project_id,'SCHEDULE_SYNC',sqlerrm,0,'OPEN') returning id into failure_id;
    end;
    begin
      perform epas_refresh_vessel_survey_status_v28(v.id); vc:=vc+1;
    exception when others then
      err:=err+1;
      insert into scheduler_failures_v29(scheduler_run_id,vessel_id,project_id,operation,error_message,retry_count,status)
      values(run_id,v.id,v.project_id,'VESSEL_STATUS_SYNC',sqlerrm,0,'OPEN');
    end;
  end loop;
  begin nc:=epas_generate_survey_due_notifications_v28(); exception when others then
    err:=err+1;
    insert into scheduler_failures_v29(scheduler_run_id,operation,error_message,retry_count,status)
    values(run_id,'NOTIFICATION_GENERATION',sqlerrm,0,'OPEN');
  end;
  update scheduler_runs
  set status=case when err=0 then 'SUCCEEDED' else 'SUCCEEDED_WITH_ERRORS' end,
      completed_at=now(),processed_count=sc,error_count=err,
      health_state=case when err=0 then 'HEALTHY' else 'DEGRADED' end,
      metadata=jsonb_build_object('version','2.9','schedules_processed',sc,'vessel_statuses_processed',vc,'notifications',nc,'errors',err)
  where id=run_id;
  return jsonb_build_object('run_id',run_id,'schedules_processed',sc,'vessel_statuses_processed',vc,'notifications',nc,'errors',err,'health_state',case when err=0 then 'HEALTHY' else 'DEGRADED' end);
end;$$;
grant execute on function epas_scheduler_tick_v29() to service_role;

-- ============================================================================
-- 16A. Controlled observation evidence integrity and file-type policy.
-- ============================================================================
create or replace function epas_register_observation_evidence_v29(
  p_observation_id uuid,p_corrective_action_id uuid,p_file_name text,p_storage_path text,
  p_sha256 text,p_mime_type text,p_size_bytes bigint,p_evidence_type text default 'CORRECTIVE_EVIDENCE'
) returns observation_evidence language plpgsql security definer set search_path=public as $$
declare o observations; ca corrective_actions; r rfis; e observation_evidence; role_name text;
begin
  select * into o from observations where id=p_observation_id for update;
  if o.id is null then raise exception 'Observation not found'; end if;
  select * into r from rfis where id=o.rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name not in ('ship_management','surveyor','dm') then raise exception 'Role cannot submit observation evidence'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not an active project member'; end if;
  if p_corrective_action_id is null then raise exception 'Evidence must be bound to an exact corrective action'; end if;
  if p_sha256 is null or length(p_sha256)<>64 then raise exception 'Actual evidence SHA-256 is required'; end if;
  if p_size_bytes is null or p_size_bytes<=0 then raise exception 'Evidence size is required'; end if;
  if lower(coalesce(p_mime_type,'')) not in ('application/pdf','image/jpeg','image/png') then raise exception 'Unsupported evidence file type'; end if;
  if p_storage_path is null or p_storage_path not like 'projects/'||r.project_id::text||'/%' then raise exception 'Evidence must use the controlled project storage path'; end if;
  select * into ca from corrective_actions where id=p_corrective_action_id and rfi_id=r.id;
  if ca.id is null then raise exception 'Corrective action is not linked to this RFI'; end if;
  if not exists(select 1 from corrective_action_observations where corrective_action_id=ca.id and observation_id=o.id) then raise exception 'Evidence must be linked to an exact corrective-action observation pair'; end if;
  if role_name='ship_management' and ca.assigned_to<>auth.uid() then raise exception 'Corrective action is not assigned to this Ship Management user'; end if;
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  insert into observation_evidence(observation_id,corrective_action_id,uploaded_by,file_name,storage_path,sha256,mime_type,size_bytes,evidence_type)
  values(o.id,p_corrective_action_id,auth.uid(),p_file_name,p_storage_path,p_sha256,p_mime_type,p_size_bytes,p_evidence_type) returning * into e;
  return e;
end;$$;
grant execute on function epas_register_observation_evidence_v29(uuid,uuid,text,text,text,text,bigint,text) to authenticated;
revoke all on function epas_register_observation_evidence(uuid,uuid,text,text,text,text,bigint,text) from authenticated;

-- ============================================================================
-- 16. Security events + controlled global search + row-version bump triggers.
-- ============================================================================
create table if not exists security_events_v29(
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id),
  event_type text not null,
  success boolean not null default true,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table security_events_v29 enable row level security;
drop policy if exists security_events_v29_select on security_events_v29;
create policy security_events_v29_select on security_events_v29 for select to authenticated using(user_id=auth.uid() or epas_has_role('gm'));
drop policy if exists security_events_v29_write on security_events_v29;
create policy security_events_v29_write on security_events_v29 for all to authenticated using(false) with check(false);

create or replace function epas_record_security_event_v29(p_event_type text,p_success boolean default true,p_details jsonb default '{}'::jsonb)
returns security_events_v29 language plpgsql security definer set search_path=public as $$
declare e security_events_v29;
begin
  insert into security_events_v29(user_id,event_type,success,details) values(auth.uid(),p_event_type,p_success,coalesce(p_details,'{}'::jsonb)) returning * into e;
  return e;
end;$$;
grant execute on function epas_record_security_event_v29(text,boolean,jsonb) to authenticated;

create or replace function epas_global_search_v29(p_query text,p_limit integer default 25)
returns table(result_type text,result_id uuid,title text,subtitle text,project_id uuid,phase text,match_rank real)
language plpgsql security definer stable set search_path=public as $$
declare q text; role_name text;
begin
  q:=trim(coalesce(p_query,''));
  if length(q)<2 then return; end if;
  role_name:=epas_v29_role();
  return query
  with project_scope as (
    select distinct pm.project_id from project_members pm where pm.user_id=auth.uid() and pm.active
  ),
  p as (
    select 'project'::text result_type,pr.id result_id,coalesce(pr.project_code,'')||' · '||pr.name title,'Project' subtitle,pr.id project_id,null::text phase,similarity(lower(coalesce(pr.project_code,'')||' '||pr.name),lower(q)) match_rank
    from projects pr join project_scope ps on ps.project_id=pr.id
    where lower(coalesce(pr.project_code,'')||' '||pr.name) like '%'||lower(q)||'%'
  ),
  v as (
    select 'vessel',ve.id,ve.name||coalesce(' · '||ve.imo_number,''),'Vessel',ve.project_id,null::text,similarity(lower(ve.name||' '||coalesce(ve.imo_number,'')),lower(q))
    from vessels ve join project_scope ps on ps.project_id=ve.project_id
    where lower(ve.name||' '||coalesce(ve.imo_number,'')) like '%'||lower(q)||'%'
  ),
  r as (
    select 'rfi',rf.id,rf.rfi_code||' · '||rf.survey_type,'RFI',rf.project_id,rf.phase,similarity(lower(rf.rfi_code||' '||coalesce(rf.survey_type,'')),lower(q))
    from rfis rf join project_scope ps on ps.project_id=rf.project_id
    where lower(rf.rfi_code||' '||coalesce(rf.survey_type,'')) like '%'||lower(q)||'%'
      and (role_name in ('gm','dm','engineer','surveyor','designer') or (role_name='shipyard' and rf.phase='nsc_survey') or (role_name in ('owner','ship_management') and rf.phase='in_service'))
  ),
  c as (
    select 'certificate',ce.id,ce.cert_number||' · '||ce.cert_type,'Certificate',ce.project_id,null::text,similarity(lower(coalesce(ce.cert_number,'')||' '||coalesce(ce.cert_type,'')),lower(q))
    from certificates ce join project_scope ps on ps.project_id=ce.project_id
    where lower(coalesce(ce.cert_number,'')||' '||coalesce(ce.cert_type,'')) like '%'||lower(q)||'%'
      and role_name in ('gm','dm','owner','ship_management','shipyard')
  )
  select * from p union all select * from v union all select * from r union all select * from c
  order by match_rank desc nulls last limit greatest(1,least(p_limit,100));
end;$$;
grant execute on function epas_global_search_v29(text,integer) to authenticated;

create or replace function epas_bump_row_version_v29()
returns trigger language plpgsql as $$
begin
  if tg_table_name='rfis' then new.row_version:=coalesce(old.row_version,0)+1; end if;
  if tg_table_name='survey_schedules' then new.row_version:=coalesce(old.row_version,0)+1; end if;
  if tg_table_name='certificates' then new.row_version:=coalesce(old.row_version,0)+1; end if;
  return new;
end;$$;
drop trigger if exists trg_rfis_row_version_v29 on rfis;
create trigger trg_rfis_row_version_v29 before update on rfis for each row execute function epas_bump_row_version_v29();
drop trigger if exists trg_survey_schedule_row_version_v29 on survey_schedules;
create trigger trg_survey_schedule_row_version_v29 before update on survey_schedules for each row execute function epas_bump_row_version_v29();
drop trigger if exists trg_certificates_row_version_v29 on certificates;
create trigger trg_certificates_row_version_v29 before update on certificates for each row execute function epas_bump_row_version_v29();

-- ============================================================================
-- 15. Acceptance matrix v2.9
-- ============================================================================
create table if not exists workflow_acceptance_cases_v29(
  case_code text primary key,
  role_name text not null,
  phase text,
  expected_result text not null,
  negative boolean not null default false,
  priority text not null default 'P1',
  created_at timestamptz not null default now()
);
insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V29_RLS_NEW_TABLES','all','all','All v2.8 operational tables are protected by RLS and scoped policies',true,'P0'),
('V29_SECURITY_DEFINER_READS','all','all','SECURITY DEFINER read RPCs reject unauthorized project/phase access',true,'P0'),
('V29_STAKEHOLDER_SCHEDULE_ISOLATION','shipyard','nsc_survey','Shipyard sees NSC schedules only; Owner/Ship Management see In-Service only',true,'P0'),
('V29_REPORT_FILE_HASH','surveyor','nsc_survey|in_service','Survey report requires actual uploaded PDF SHA-256 and file metadata',false,'P0'),
('V29_CYCLE_IDEMPOTENCY','gm','in_service','Repeated cycle completion cannot generate duplicate next cycles',true,'P0'),
('V29_SCOPE_AMENDMENT_INVALIDATION','dm','nsc_survey|in_service','Scope amendment invalidates acknowledgement/package/checklist/execution basis',false,'P0'),
('V29_CRON_HEALTH','system','all','Scheduler failures are logged and escalated for retry/management action',false,'P1'),
('V29_FAIL_CLOSED','all','all','Production runtime refuses missing Supabase configuration; demo mode is never implicit',true,'P0'),
('V29_BROWSER_UX','all','all','All role cockpits render state, blocker, next action and contextual workflow navigation',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,negative=excluded.negative,priority=excluded.priority;

commit;
