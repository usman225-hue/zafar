-- EPAS v3.3 — final workflow facade consolidation, performance and live-security acceptance hardening
-- Apply after v3.2.
begin;
create extension if not exists pgcrypto;

-- ------------------------------------------------------------------
-- 1. Canonical v3.3 read facade: direct role/phase filtering. These are
-- the only schedule/timeline read entry points exposed to application users.
-- ------------------------------------------------------------------
create or replace function epas_schedule_queue_v33(p_project_id uuid default null)
returns table(
  schedule_id uuid, project_id uuid, vessel_id uuid, phase text, cycle_number integer,
  schedule_status text, schedule_config_status text, due_basis text, due_basis_reference text,
  due_basis_date date, next_due_date date, window_start date, window_end date, current_rfi_id uuid,
  stakeholder_safe boolean
)
language plpgsql security definer stable set search_path=public as $$
declare role_name text; uid uuid;
begin
  uid:=auth.uid(); role_name:=epas_v29_role();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if p_project_id is not null and role_name not in ('gm','dm') and not exists(
    select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=uid and pm.active
  ) then raise exception 'Not authorized for project'; end if;
  return query
  select s.id,s.project_id,s.vessel_id,s.phase,s.cycle_number,s.status,s.schedule_config_status,
         case when role_name in ('gm','dm') then s.due_basis else null end,
         case when role_name in ('gm','dm') then s.due_basis_reference else null end,
         case when role_name in ('gm','dm') then s.due_basis_date else null end,
         s.next_due_date,s.window_start,s.window_end,s.current_rfi_id,
         role_name not in ('gm','dm')
  from survey_schedules s
  where s.active and (p_project_id is null or s.project_id=p_project_id)
    and (
      role_name in ('gm','dm')
      or (role_name='shipyard' and s.phase='nsc_survey' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active))
      or (role_name in ('owner','ship_management') and s.phase='in_service' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active))
      or (role_name='surveyor' and exists(select 1 from rfis r where r.id=s.current_rfi_id and r.assigned_surveyor_id=uid))
    )
  order by s.next_due_date nulls last,s.window_start nulls last,s.phase;
end;$$;
revoke all on function epas_schedule_queue_v33(uuid) from public;
grant execute on function epas_schedule_queue_v33(uuid) to authenticated;

create or replace function epas_timeline_v33(p_project_id uuid,p_limit integer default 100)
returns table(event_id uuid,event_type text,occurred_at timestamptz,summary text,phase text,entity_id uuid)
language plpgsql security definer stable set search_path=public as $$
declare role_name text; uid uuid;
begin
  uid:=auth.uid(); role_name:=epas_v29_role();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=uid and pm.active) then
    raise exception 'Not authorized for project timeline';
  end if;
  return query
  with ev as (
    select le.id,le.event_type,le.created_at,le.note,le.entity_id,coalesce(le.metadata->>'phase',case when le.entity_type='rfi' then (select r.phase from rfis r where r.id=le.entity_id) end) phase_resolved
    from lifecycle_events le where le.project_id=p_project_id
  )
  select ev.id,ev.event_type,ev.created_at,
    case
      when role_name in ('gm','dm') then coalesce(ev.note,ev.event_type)
      when role_name='shipyard' and ev.phase_resolved='nsc_survey' then coalesce(ev.event_type,'NSC workflow event')
      when role_name in ('owner','ship_management') and ev.phase_resolved='in_service' then coalesce(ev.event_type,'In-Service workflow event')
      when role_name='surveyor' and exists(select 1 from rfis r where r.id=ev.entity_id and r.assigned_surveyor_id=uid) then coalesce(ev.event_type,'Survey workflow event')
      when role_name in ('engineer','designer') and ev.phase_resolved='plan_appraisal' then coalesce(ev.event_type,'Plan workflow event')
      else 'Authorized workflow event'
    end,
    ev.phase_resolved,ev.entity_id
  from ev
  where role_name in ('gm','dm')
     or (role_name='shipyard' and ev.phase_resolved='nsc_survey')
     or (role_name in ('owner','ship_management') and ev.phase_resolved='in_service')
     or (role_name='surveyor' and exists(select 1 from rfis r where r.id=ev.entity_id and r.assigned_surveyor_id=uid))
     or (role_name in ('engineer','designer') and ev.phase_resolved='plan_appraisal')
  order by ev.created_at desc limit greatest(1,least(p_limit,200));
end;$$;
revoke all on function epas_timeline_v33(uuid,integer) from public;
grant execute on function epas_timeline_v33(uuid,integer) to authenticated;

-- ------------------------------------------------------------------
-- 2. v3.3 gate facade. Internal historical functions remain available
-- only to server-side function chaining; callers use v3.3 entry points.
-- ------------------------------------------------------------------
create or replace function epas_survey_start_gate_v33(p_rfi_id uuid)
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

create or replace function epas_survey_submission_gate_v33(p_rfi_id uuid)
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

create or replace function epas_survey_checklist_ready_v33(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm','surveyor') then raise exception 'Checklist state is an internal survey control'; end if;
  return epas_survey_checklist_ready_v29(p_rfi_id);
end;$$;

create or replace function epas_survey_dependency_status_v33(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm','surveyor') then raise exception 'Survey dependency state is an internal survey control'; end if;
  return epas_survey_dependency_status_v27(p_rfi_id);
end;$$;

create or replace function epas_certificate_issuance_gate_v33(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Certificate issuance gate is an internal management control'; end if;
  return epas_certificate_issuance_gate_v29(p_rfi_id,p_cert_type);
end;$$;

create or replace function epas_set_in_service_schedule_basis_v33(p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_basis_date date,p_window_days_before integer default 90,p_window_days_after integer default 30,p_basis_document_id uuid default null)
returns survey_schedules language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may configure In-Service schedule basis'; end if;
  return epas_set_in_service_schedule_basis_v28(p_vessel_id,p_interval_months,p_due_basis,p_basis_reference,p_basis_date,p_window_days_before,p_window_days_after,p_basis_document_id);
end;$$;

create or replace function epas_register_certificate_pdf_v33(p_certificate_id uuid,p_storage_path text,p_sha256 text,p_size_bytes bigint)
returns certificates language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may register a certificate PDF'; end if;
  if coalesce(p_sha256,'')='' or p_size_bytes<=0 then raise exception 'Certificate file integrity metadata is required'; end if;
  return epas_register_certificate_pdf_v32(p_certificate_id,p_storage_path,p_sha256,p_size_bytes);
end;$$;

create or replace function epas_submit_survey_report_v33(p_rfi_id uuid,p_report_note text,p_observations jsonb,p_evidence_path text,p_evidence_sha256 text,p_mime_type text,p_size_bytes bigint,p_location text,p_survey_date date,p_attendance text,p_declaration text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'surveyor' then raise exception 'Only assigned Surveyor may submit a survey report'; end if;
  if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_surveyor_id=auth.uid()) then raise exception 'RFI is not assigned to current Surveyor'; end if;
  if lower(coalesce(p_mime_type,''))<>'application/pdf' or coalesce(p_size_bytes,0)<=0 or coalesce(p_evidence_sha256,'')='' then raise exception 'Controlled PDF integrity metadata is required'; end if;
  return epas_submit_survey_report_v32(p_rfi_id,p_report_note,p_observations,p_evidence_path,p_evidence_sha256,p_mime_type,p_size_bytes,p_location,p_survey_date,p_attendance,p_declaration);
end;$$;


create or replace function epas_surveyor_accept_assignment_v33(p_rfi_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'surveyor' then raise exception 'Only assigned Surveyor may accept a survey assignment'; end if;
  if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_surveyor_id=auth.uid()) then raise exception 'RFI is not assigned to current Surveyor'; end if;
  return epas_surveyor_accept_assignment_v32(p_rfi_id,p_note);
end;$$;

create or replace function epas_acknowledge_survey_scope_v33(p_rfi_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare role_name text; uid uuid;
begin
  role_name:=epas_v29_role(); uid:=auth.uid();
  if role_name='surveyor' then
    if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_surveyor_id=uid) then raise exception 'RFI is not assigned to current Surveyor'; end if;
  elsif role_name='dm' then
    if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_dm_id=uid) then raise exception 'RFI is not assigned to current DM'; end if;
  elsif role_name<>'gm' then raise exception 'Scope acknowledgement is not exposed to this role'; end if;
  return epas_acknowledge_survey_scope_v32(p_rfi_id,p_note);
end;$$;

create or replace function epas_start_survey_execution_v33(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'surveyor' then raise exception 'Only the assigned Surveyor may start survey execution'; end if;
  if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_surveyor_id=auth.uid()) then raise exception 'RFI is not assigned to current Surveyor'; end if;
  return epas_start_survey_execution_v32(p_rfi_id);
end;$$;

create or replace function epas_acknowledge_certificate_decision_package_v33(p_package_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'dm' then raise exception 'Only the assigned DM may acknowledge a certificate decision package'; end if;
  return epas_acknowledge_certificate_decision_package_v29(p_package_id,p_note);
end;$$;

create or replace function epas_mark_in_service_cycle_complete_v33(p_rfi_id uuid,p_idempotency_key text)
returns survey_cycle_instances language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may complete an In-Service cycle'; end if;
  return epas_mark_in_service_cycle_complete_v32(p_rfi_id,p_idempotency_key);
end;$$;


create or replace function epas_acknowledge_survey_drawing_package_v33(p_rfi_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'surveyor' then raise exception 'Only assigned Surveyor may acknowledge a drawing package'; end if;
  if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_surveyor_id=auth.uid()) then raise exception 'RFI is not assigned to current Surveyor'; end if;
  return epas_acknowledge_survey_drawing_package_v32(p_rfi_id,p_note);
end;$$;

create or replace function epas_freeze_survey_execution_basis_v33(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'surveyor' then raise exception 'Only assigned Surveyor may freeze execution basis'; end if;
  if not exists(select 1 from rfis r where r.id=p_rfi_id and r.assigned_surveyor_id=auth.uid()) then raise exception 'RFI is not assigned to current Surveyor'; end if;
  return epas_freeze_survey_execution_basis_v32(p_rfi_id);
end;$$;


create or replace function epas_project_health_bundle_v33(p_project_ids uuid[])
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); uid uuid:=auth.uid(); result jsonb:='{}'::jsonb; pid uuid; row jsonb;
begin
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  foreach pid in array coalesce(p_project_ids,'{}'::uuid[]) loop
    if role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=pid and pm.user_id=uid and pm.active) then continue; end if;
    select jsonb_build_object(
      'completion_pct',coalesce(round(100.0*sum(case when wt.status='completed' then 1 else 0 end)/nullif(count(wt.id),0),1),0),
      'total_tasks',count(wt.id),'completed_tasks',sum(case when wt.status='completed' then 1 else 0 end),
      'overdue_tasks',sum(case when wt.status in ('pending','accepted','in_progress') and wt.due_at<now() then 1 else 0 end),
      'open_risks',(select count(*) from project_risks pr where pr.project_id=pid and pr.status not in ('closed','resolved')),
      'plan_drawings',(select count(*) from plan_drawings d where d.project_id=pid),
      'approved_drawings',(select count(*) from plan_drawings d where d.project_id=pid and d.status='approved'),
      'rfis',(select count(*) from rfis r where r.project_id=pid),
      'rfis_approved',(select count(*) from rfis r where r.project_id=pid and r.status in ('approved','certificate_issued','closed')),
      'open_observations',(select count(*) from observations o join rfis r on r.id=o.rfi_id where r.project_id=pid and o.status in ('open','in_progress')),
      'health_status',case when exists(select 1 from workflow_tasks wt2 where wt2.project_id=pid and wt2.status in ('pending','accepted','in_progress') and wt2.due_at<now()) then 'attention' when exists(select 1 from project_risks pr2 where pr2.project_id=pid and pr2.status not in ('closed','resolved')) or exists(select 1 from observations o2 join rfis r2 on r2.id=o2.rfi_id where r2.project_id=pid and o2.status in ('open','in_progress')) then 'watch' else 'healthy' end
    ) into row from workflow_tasks wt where wt.project_id=pid;
    result:=result||jsonb_build_object(pid::text,coalesce(row,'{}'::jsonb));
  end loop;
  return result;
end;$$;

create or replace function epas_stakeholder_create_scheduled_in_service_rfi_v33(p_schedule_id uuid,p_scope text,p_requested_date date,p_priority text,p_note text)
returns rfis language plpgsql security definer set search_path=public as $$
declare s survey_schedules; r rfis; role_name text:=epas_v29_role();
begin
  if role_name not in ('owner','ship_management') then raise exception 'Only Owner or Ship Management may initiate In-Service RFI'; end if;
  select * into s from survey_schedules where id=p_schedule_id and phase='in_service' and active for update;
  if s.id is null then raise exception 'In-Service schedule not found'; end if;
  if not epas_is_project_member(s.project_id) then raise exception 'Not authorized for project'; end if;
  if s.schedule_config_status<>'CONFIGURED' then raise exception 'Survey schedule requires configuration before RFI initiation'; end if;
  if s.current_rfi_id is not null and exists(select 1 from rfis rr where rr.id=s.current_rfi_id and rr.status not in ('closed','certificate_issued')) then raise exception 'An In-Service RFI is already active for this cycle'; end if;
  insert into rfis(project_id,vessel_id,phase,survey_type,scope_note,requested_date,priority,requested_by,status)
  values(s.project_id,s.vessel_id,'in_service','In-Service Survey',p_scope,p_requested_date,p_priority,auth.uid(),'pending_allocation') returning * into r;
  update survey_cycle_instances set rfi_id=r.id,status='RFI_OPEN',updated_at=now() where id=s.cycle_instance_id;
  update survey_schedules set current_rfi_id=r.id,phase_lifecycle='ACTIVE',updated_at=now() where id=s.id;
  return r;
end;$$;

create or replace function epas_refresh_vessel_status_as_manager_v33(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may refresh vessel status manually'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v.project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Not authorized for project'; end if;
  return epas_refresh_vessel_status_as_manager_v29(p_vessel_id);
end;$$;

create or replace function epas_scheduler_health_v33(p_limit integer default 20)
returns table(run_id uuid,started_at timestamptz,finished_at timestamptz,status text,critical_failures integer,notes text)
language sql security definer stable set search_path=public as $$
  select id,started_at,completed_at,status,coalesce((metadata->>'critical_failures')::integer,0),coalesce(error_message,'')
  from scheduler_runs order by started_at desc limit greatest(1,least(p_limit,50));
$$;

create or replace function epas_scheduler_tick_v33()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if current_user <> 'service_role' then raise exception 'Service role required'; end if;
  return epas_scheduler_tick_v32();
end;$$;

revoke all on function epas_survey_start_gate_v33(uuid) from public;
revoke all on function epas_survey_submission_gate_v33(uuid) from public;
revoke all on function epas_survey_checklist_ready_v33(uuid) from public;
revoke all on function epas_survey_dependency_status_v33(uuid) from public;
revoke all on function epas_certificate_issuance_gate_v33(uuid,text) from public;
revoke all on function epas_set_in_service_schedule_basis_v33(uuid,integer,text,text,date,integer,integer,uuid) from public;
revoke all on function epas_register_certificate_pdf_v33(uuid,text,text,bigint) from public;
revoke all on function epas_submit_survey_report_v33(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) from public;
revoke all on function epas_mark_in_service_cycle_complete_v33(uuid,text) from public;
revoke all on function epas_scheduler_tick_v33() from public;
grant execute on function epas_survey_start_gate_v33(uuid) to authenticated;
grant execute on function epas_surveyor_accept_assignment_v33(uuid,text) to authenticated;
grant execute on function epas_acknowledge_survey_scope_v33(uuid,text) to authenticated;
grant execute on function epas_start_survey_execution_v33(uuid) to authenticated;
grant execute on function epas_acknowledge_certificate_decision_package_v33(uuid,text) to authenticated;
grant execute on function epas_survey_submission_gate_v33(uuid) to authenticated;
grant execute on function epas_survey_checklist_ready_v33(uuid) to authenticated;
grant execute on function epas_survey_dependency_status_v33(uuid) to authenticated;
grant execute on function epas_certificate_issuance_gate_v33(uuid,text) to authenticated;
grant execute on function epas_set_in_service_schedule_basis_v33(uuid,integer,text,text,date,integer,integer,uuid) to authenticated;
grant execute on function epas_register_certificate_pdf_v33(uuid,text,text,bigint) to authenticated;
grant execute on function epas_submit_survey_report_v33(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;
grant execute on function epas_mark_in_service_cycle_complete_v33(uuid,text) to authenticated;
grant execute on function epas_acknowledge_survey_drawing_package_v33(uuid,text) to authenticated;
grant execute on function epas_freeze_survey_execution_basis_v33(uuid) to authenticated;
grant execute on function epas_scheduler_health_v33(integer) to authenticated;
grant execute on function epas_project_health_bundle_v33(uuid[]) to authenticated;
grant execute on function epas_stakeholder_create_scheduled_in_service_rfi_v33(uuid,text,date,text,text) to authenticated;
grant execute on function epas_refresh_vessel_status_as_manager_v33(uuid) to authenticated;
grant execute on function epas_scheduler_tick_v33() to service_role;

-- ------------------------------------------------------------------
-- 3. Batch project/task context RPCs to remove UI N+1 reads.
-- ------------------------------------------------------------------
create or replace function epas_plan_drawing_bundle_v33(p_drawing_ids uuid[])
returns table(id uuid,project_id uuid,drawing_no text,title text,discipline text,status text,current_revision integer,updated_at timestamptz,engineer_id uuid,manager_id uuid,designer_id uuid,current_file_name text)
language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); uid uuid;
begin
  uid:=auth.uid();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  return query
  select d.id,d.project_id,d.drawing_no,d.title,d.discipline,d.status,d.current_revision,d.updated_at,d.engineer_id,d.manager_id,d.designer_id,d.current_file_name
  from plan_drawings d
  where d.id = any(coalesce(p_drawing_ids,'{}'::uuid[]))
    and (
      role_name in ('gm','dm') and exists(select 1 from project_members pm where pm.project_id=d.project_id and pm.user_id=uid and pm.active and pm.role in ('gm','dm'))
      or role_name='engineer' and d.engineer_id=uid
      or role_name='designer' and d.designer_id=uid
      or role_name='surveyor' and exists(select 1 from survey_rfi_drawings srd join rfis r on r.id=srd.rfi_id where srd.drawing_id=d.id and r.assigned_surveyor_id=uid)
    );
end;$$;

create or replace function epas_rfi_bundle_v33(p_rfi_ids uuid[])
returns setof rfis
language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); uid uuid;
begin
  uid:=auth.uid();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  return query
  select r.* from rfis r
  where r.id = any(coalesce(p_rfi_ids,'{}'::uuid[]))
    and (
      role_name in ('gm','dm')
      or (role_name='surveyor' and r.assigned_surveyor_id=uid)
      or (role_name='shipyard' and r.phase='nsc_survey' and r.requested_by=uid)
      or (role_name in ('owner','ship_management') and r.phase='in_service' and r.requested_by=uid)
    );
end;$$;
revoke all on function epas_plan_drawing_bundle_v33(uuid[]) from public;
revoke all on function epas_rfi_bundle_v33(uuid[]) from public;
grant execute on function epas_plan_drawing_bundle_v33(uuid[]) to authenticated;
grant execute on function epas_rfi_bundle_v33(uuid[]) to authenticated;

-- ------------------------------------------------------------------
-- 3b. Compact stakeholder/project bundles.
-- ------------------------------------------------------------------
create or replace function epas_authorized_projects_v33()
returns table(id uuid,project_code text,name text,status text,phases text[],created_at timestamptz,updated_at timestamptz,vessel_name text,vessel_type text,flag_state text)
language sql security definer stable set search_path=public as $$
  select p.id,p.project_code,p.name,p.status,p.phases,p.created_at,p.updated_at,v.name,v.vessel_type,v.flag_state
  from projects p left join vessels v on v.project_id=p.id
  where p.status='active' and (
    epas_v29_role() in ('gm','dm')
    or exists(select 1 from project_members pm where pm.project_id=p.id and pm.user_id=auth.uid() and pm.active and (
      pm.role=epas_v29_role() or (epas_v29_role() in ('shipyard','owner','ship_management') and pm.role=epas_v29_role())
    ))
  ) order by p.created_at desc;
$$;

create or replace function epas_role_dashboard_bundle_v33()
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); uid uuid:=auth.uid(); active_projects integer:=0; open_tasks integer:=0; overdue_tasks integer:=0; open_actions integer:=0; schedule_due integer:=0; schedule_overdue integer:=0; pending_decisions integer:=0; open_certificates integer:=0;
begin
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if role_name in ('gm','dm') then select count(*) into active_projects from projects where status='active';
  else select count(distinct pm.project_id) into active_projects from project_members pm where pm.user_id=uid and pm.active; end if;
  select count(*) into open_tasks from workflow_tasks where to_user_id=uid and status in ('pending','accepted','in_progress');
  select count(*) into overdue_tasks from workflow_tasks where to_user_id=uid and status in ('pending','accepted','in_progress') and coalesce(due_at,now())<now();
  if role_name='gm' then
    select count(*) into pending_decisions from rfis where status='pending_gm_approval';
    select count(*) into open_certificates from certificates where status in ('draft','pending_approval','gm_approved','pending_dm_ack','ready_for_issuance');
  elsif role_name in ('owner','ship_management') then
    select count(*) into schedule_due from survey_schedules s where s.active and s.phase='in_service' and s.status in ('DUE','DUE_SOON','OVERDUE') and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
    select count(*) into schedule_overdue from survey_schedules s where s.active and s.phase='in_service' and s.status='OVERDUE' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
    select count(*) into open_actions from corrective_actions ca where ca.assignee_id=uid and ca.status not in ('verified','closed');
  elsif role_name='shipyard' then
    select count(*) into schedule_due from survey_schedules s where s.active and s.phase='nsc_survey' and s.status in ('DUE','DUE_SOON','OVERDUE') and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
    select count(*) into schedule_overdue from survey_schedules s where s.active and s.phase='nsc_survey' and s.status='OVERDUE' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
  end if;
  return jsonb_build_object('role',role_name,'active_projects',active_projects,'open_tasks',open_tasks,'overdue_tasks',overdue_tasks,'open_actions',open_actions,'schedule_due',schedule_due,'schedule_overdue',schedule_overdue,'pending_decisions',pending_decisions,'open_certificates',open_certificates);
end;$$;

create or replace function epas_stakeholder_fleet_bundle_v33()
returns jsonb language sql security definer stable set search_path=public as $$
  select jsonb_build_object(
    'total_vessels',count(*),
    'in_class',count(*) filter(where class_status='active'),
    'interim',count(*) filter(where class_status='interim'),
    'out_of_class',count(*) filter(where class_status='out_of_class'),
    'expiring_certificates',(select count(*) from certificates c join project_members pm on pm.project_id=c.project_id where c.expiry_date between current_date and current_date+interval '90 days' and pm.user_id=auth.uid() and pm.active and pm.role=epas_v29_role()),
    'open_observations',(select count(*) from observations o join rfis r on r.id=o.rfi_id join project_members pm on pm.project_id=r.project_id where o.status in ('open','in_progress') and pm.user_id=auth.uid() and pm.active and pm.role=epas_v29_role())
  )
  from vessels v join project_members pm on pm.project_id=v.project_id
  where pm.user_id=auth.uid() and pm.active and pm.role=epas_v29_role();
$$;

create or replace function epas_stakeholder_vessel_bundle_v33(p_vessel_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); uid uuid:=auth.uid(); pid uuid; result jsonb;
begin
  select project_id into pid from vessels where id=p_vessel_id;
  if pid is null or not exists(select 1 from project_members pm where pm.project_id=pid and pm.user_id=uid and pm.active and pm.role=role_name) then raise exception 'Not authorized for vessel'; end if;
  select jsonb_build_object(
    'vessel',jsonb_build_object('id',v.id,'name',v.name,'imo_number',v.imo_number,'class_status',v.class_status,'survey_status',v.survey_status,'next_survey_due',v.next_survey_due,'last_survey_date',v.last_survey_date),
    'certificate_count',(select count(*) from certificates c where c.project_id=pid and c.status in ('active','superseded')),
    'open_observations',(select count(*) from observations o join rfis r on r.id=o.rfi_id where r.project_id=pid and o.status in ('open','in_progress')),
    'next_survey_date',v.next_survey_due,
    'upcoming_surveys',(select coalesce(jsonb_agg(jsonb_build_object('rfi_code',r.rfi_code,'phase',r.phase,'survey_type',r.survey_type,'status',r.status,'scheduled_date',r.scheduled_date) order by r.scheduled_date nulls last),'[]'::jsonb) from rfis r where r.vessel_id=p_vessel_id and r.status not in ('closed','certificate_issued') and r.requested_by=uid limit 20)
  ) into result from vessels v where v.id=p_vessel_id;
  return result;
end;$$;

revoke all on function epas_authorized_projects_v33() from public;
revoke all on function epas_role_dashboard_bundle_v33() from public;
revoke all on function epas_stakeholder_fleet_bundle_v33() from public;
revoke all on function epas_stakeholder_vessel_bundle_v33(uuid) from public;
grant execute on function epas_authorized_projects_v33() to authenticated;
grant execute on function epas_role_dashboard_bundle_v33() to authenticated;
grant execute on function epas_stakeholder_fleet_bundle_v33() to authenticated;
grant execute on function epas_stakeholder_vessel_bundle_v33(uuid) to authenticated;

-- ------------------------------------------------------------------
-- 4. Final application privilege cleanup: lower-version entry points are
-- internal only. v3.3 is the sole external application facade.
-- ------------------------------------------------------------------
do $$
declare fn text; argtypes text;
begin
  foreach fn in array array[
    'epas_schedule_queue_v31','epas_schedule_queue_v32','epas_timeline_v31','epas_timeline_v32',
    'epas_survey_start_gate_v30','epas_survey_start_gate_v32','epas_survey_submission_gate_v30','epas_survey_submission_gate_v32',
    'epas_survey_checklist_ready_v32','epas_survey_dependency_status_v32','epas_certificate_issuance_gate_v30','epas_certificate_issuance_gate_v32',
    'epas_set_in_service_schedule_basis_v32','epas_register_certificate_pdf_v32','epas_submit_survey_report_v32','epas_mark_in_service_cycle_complete_v32',
    'epas_scheduler_tick_v32','epas_surveyor_accept_assignment_v32','epas_stakeholder_create_scheduled_in_service_rfi_v30','epas_refresh_vessel_status_as_manager_v29','epas_acknowledge_survey_drawing_package_v32','epas_freeze_survey_execution_basis_v32','epas_acknowledge_survey_scope_v32','epas_start_survey_execution_v32','epas_acknowledge_certificate_decision_package_v29'
  ] loop
    begin
      select pg_get_function_identity_arguments(p.oid) into argtypes from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=fn limit 1;
      if argtypes is not null then
        execute format('revoke execute on function public.%I(%s) from authenticated',fn,argtypes);
      end if;
    exception when others then null;
    end;
  end loop;
end$$;

-- ------------------------------------------------------------------
-- 5. Security acceptance matrix / release state.
-- ------------------------------------------------------------------
create table if not exists epas_live_acceptance_runs_v33(
  id uuid primary key default gen_random_uuid(),
  case_code text not null,
  actor_role text,
  project_id uuid,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'PENDING',
  evidence jsonb not null default '{}'::jsonb,
  created_by uuid
);
create index if not exists ix_epas_live_acceptance_runs_v33_case on epas_live_acceptance_runs_v33(case_code,started_at desc);
alter table epas_live_acceptance_runs_v33 enable row level security;
drop policy if exists epas_live_acceptance_runs_v33_select on epas_live_acceptance_runs_v33;
create policy epas_live_acceptance_runs_v33_select on epas_live_acceptance_runs_v33 for select to authenticated using(epas_v29_role() in ('gm','dm'));
drop policy if exists epas_live_acceptance_runs_v33_write on epas_live_acceptance_runs_v33;
create policy epas_live_acceptance_runs_v33_write on epas_live_acceptance_runs_v33 for all to authenticated using(false) with check(false);

commit;
