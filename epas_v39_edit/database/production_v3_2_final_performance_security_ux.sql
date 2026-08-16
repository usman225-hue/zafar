-- EPAS v3.2 — final production hardening, canonical RPC facade, performance and UX closure
-- Apply after v3.1. This migration does not replace the v3.1 baseline; it adds a
-- single authoritative v3.2 application facade and final security/performance controls.
begin;
create extension if not exists pgcrypto;

-- ------------------------------------------------------------------
-- 1. Explicit final RLS for new operational/audit tables.
-- ------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'survey_cycle_instances','survey_checklist_instances','survey_assignment_acknowledgements',
    'survey_scope_change_events','survey_scope_acknowledgements','survey_drawing_package_acknowledgements',
    'security_events_v29','scheduler_failures_v29','workflow_acceptance_cases_v29',
    'epas_privilege_registry_v30'
  ] LOOP
    EXECUTE format('alter table if exists %I enable row level security', t);
  END LOOP;
END$$;

-- Cycle visibility follows project membership, with stakeholder phase boundaries.
drop policy if exists epas_cycle_select_v32 on survey_cycle_instances;
create policy epas_cycle_select_v32 on survey_cycle_instances for select to authenticated using (
  exists(select 1 from project_members pm where pm.project_id=survey_cycle_instances.project_id and pm.user_id=auth.uid() and pm.active)
  and (
    epas_v29_role() in ('gm','dm')
    or (epas_v29_role()='shipyard' and phase='nsc_survey')
    or (epas_v29_role() in ('owner','ship_management') and phase='in_service')
    or (epas_v29_role()='surveyor' and exists(select 1 from rfis r where r.project_id=survey_cycle_instances.project_id and r.phase=survey_cycle_instances.phase and r.assigned_surveyor_id=auth.uid()))
  )
);

-- Checklist instances are internal to GM/DM and the assigned Surveyor.
drop policy if exists epas_checklist_instance_select_v32 on survey_checklist_instances;
create policy epas_checklist_instance_select_v32 on survey_checklist_instances for select to authenticated using (
  exists(
    select 1 from rfis r join project_members pm on pm.project_id=r.project_id
    where r.id=survey_checklist_instances.rfi_id and pm.user_id=auth.uid() and pm.active
      and (pm.role in ('gm','dm') or (pm.role='surveyor' and r.assigned_surveyor_id=auth.uid()))
  )
);

-- Acknowledgements are only readable by the actor, assigned Surveyor, GM or DM.
drop policy if exists epas_assignment_ack_select_v32 on survey_assignment_acknowledgements;
create policy epas_assignment_ack_select_v32 on survey_assignment_acknowledgements for select to authenticated using (
  acknowledged_by=auth.uid()
  or epas_v29_role() in ('gm','dm')
  or exists(select 1 from survey_assignments a join rfis r on r.id=a.rfi_id where a.id=survey_assignment_acknowledgements.assignment_id and a.surveyor_id=auth.uid())
);

-- Direct client writes remain forbidden; all changes use controlled RPCs.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['survey_cycle_instances','survey_checklist_instances','survey_assignment_acknowledgements','survey_scope_change_events','survey_scope_acknowledgements','survey_drawing_package_acknowledgements','security_events_v29','scheduler_failures_v29','workflow_acceptance_cases_v29','epas_privilege_registry_v30'] LOOP
    EXECUTE format('drop policy if exists epas_%s_write_deny_v32 on %I', replace(t,'_',''), t);
  END LOOP;
END$$;

-- ------------------------------------------------------------------
-- 2. Canonical project health bundle: one RPC for all visible project summaries.
-- ------------------------------------------------------------------
create or replace function epas_project_health_bundle_v32(p_project_ids uuid[])
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare role_name text; uid uuid; result jsonb := '{}'::jsonb; pid uuid; row jsonb;
begin
  uid:=auth.uid(); role_name:=epas_v29_role();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  foreach pid in array coalesce(p_project_ids,'{}'::uuid[]) loop
    if role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=pid and pm.user_id=uid and pm.active) then
      continue;
    end if;
    select jsonb_build_object(
      'completion_pct',coalesce(round(100.0*sum(case when wt.status='completed' then 1 else 0 end)/nullif(count(wt.id),0),1),0),
      'total_tasks',count(wt.id),
      'completed_tasks',sum(case when wt.status='completed' then 1 else 0 end),
      'overdue_tasks',sum(case when wt.status in ('pending','accepted','in_progress') and wt.due_at<now() then 1 else 0 end),
      'open_risks',(select count(*) from project_risks pr where pr.project_id=pid and pr.status not in ('closed','resolved')),
      'plan_drawings',(select count(*) from plan_drawings d where d.project_id=pid),
      'approved_drawings',(select count(*) from plan_drawings d where d.project_id=pid and d.status='approved'),
      'rfis',(select count(*) from rfis r where r.project_id=pid),
      'rfis_approved',(select count(*) from rfis r where r.project_id=pid and r.status in ('approved','certificate_issued','closed')),
      'open_observations',(select count(*) from observations o join rfis r on r.id=o.rfi_id where r.project_id=pid and o.status in ('open','in_progress')),
      'health_status',case
        when exists(select 1 from workflow_tasks wt2 where wt2.project_id=pid and wt2.status in ('pending','accepted','in_progress') and wt2.due_at<now()) then 'attention'
        when exists(select 1 from project_risks pr2 where pr2.project_id=pid and pr2.status not in ('closed','resolved'))
             or exists(select 1 from observations o2 join rfis r2 on r2.id=o2.rfi_id where r2.project_id=pid and o2.status in ('open','in_progress')) then 'watch'
        else 'healthy' end
    ) into row
    from workflow_tasks wt where wt.project_id=pid;
    result := result || jsonb_build_object(pid::text, coalesce(row,'{}'::jsonb));
  end loop;
  return result;
end;$$;
revoke all on function epas_project_health_bundle_v32(uuid[]) from public;
grant execute on function epas_project_health_bundle_v32(uuid[]) to authenticated;

-- ------------------------------------------------------------------
-- 3. Canonical v3.2 read/gate facade. These wrappers are the only active
-- application entry points for the survey control surface.
-- ------------------------------------------------------------------
create or replace function epas_schedule_queue_v32(p_project_id uuid default null)
returns setof record
language plpgsql security definer stable set search_path=public as $$
begin
  return query select * from epas_schedule_queue_v31(p_project_id);
end;$$;
-- PostgreSQL requires the return record shape at call sites; use the same named columns through a view-style wrapper instead.
drop function if exists epas_schedule_queue_v32(uuid);
create or replace function epas_schedule_queue_v32(p_project_id uuid default null)
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
  return query select * from epas_schedule_queue_v31(p_project_id);
end;$$;

create or replace function epas_timeline_v32(p_project_id uuid,p_limit integer default 100)
returns table(event_id uuid,event_type text,occurred_at timestamptz,summary text,phase text,entity_id uuid)
language plpgsql security definer stable set search_path=public as $$
begin
  return query select * from epas_timeline_v31(p_project_id,p_limit);
end;$$;

create or replace function epas_survey_start_gate_v32(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if role_name not in ('gm','dm','surveyor') then raise exception 'Internal survey readiness is not exposed to this role'; end if;
  return epas_survey_start_gate_v30(p_rfi_id);
end;$$;

create or replace function epas_survey_submission_gate_v32(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if role_name not in ('gm','dm','surveyor') then raise exception 'Internal survey submission gate is not exposed to this role'; end if;
  return epas_survey_submission_gate_v30(p_rfi_id);
end;$$;

create or replace function epas_certificate_issuance_gate_v32(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Certificate issuance gate is an internal management control'; end if;
  return epas_certificate_issuance_gate_v30(p_rfi_id,p_cert_type);
end;$$;

create or replace function epas_set_in_service_schedule_basis_v32(p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_basis_date date,p_window_days_before integer default 90,p_window_days_after integer default 30,p_basis_document_id uuid default null)
returns survey_schedules language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Only GM/DM may configure an In-Service schedule'; end if;
  return epas_set_in_service_schedule_basis_v28(p_vessel_id,p_interval_months,p_due_basis,p_basis_reference,p_basis_date,p_window_days_before,p_window_days_after,p_basis_document_id);
end;$$;

create or replace function epas_register_certificate_pdf_v32(p_certificate_id uuid,p_storage_path text,p_sha256 text,p_size_bytes bigint)
returns certificates language plpgsql security definer set search_path=public as $$
begin
  if epas_v29_role()<>'gm' then raise exception 'Only GM may register a certificate PDF'; end if;
  return epas_register_certificate_pdf_v15(p_certificate_id,p_storage_path,p_sha256,p_size_bytes);
end;$$;

-- ------------------------------------------------------------------
-- 4. Canonical survey action wrappers.
-- ------------------------------------------------------------------
create or replace function epas_surveyor_accept_assignment_v32(p_rfi_id uuid,p_note text default '')
returns survey_assignments language plpgsql security definer set search_path=public as $$
begin
  return epas_surveyor_accept_assignment_v28(p_rfi_id,p_note);
end;$$;
create or replace function epas_acknowledge_survey_scope_v32(p_rfi_id uuid,p_note text default '')
returns survey_scope_acknowledgements language plpgsql security definer set search_path=public as $$
begin
  return epas_acknowledge_survey_scope_v28(p_rfi_id,p_note);
end;$$;
create or replace function epas_acknowledge_survey_drawing_package_v32(p_rfi_id uuid,p_note text default '')
returns survey_drawing_package_acknowledgements language plpgsql security definer set search_path=public as $$
begin
  return epas_acknowledge_survey_drawing_package_v27(p_rfi_id,p_note);
end;$$;
create or replace function epas_freeze_survey_execution_basis_v32(p_rfi_id uuid)
returns survey_execution_basis_versions language plpgsql security definer set search_path=public as $$
begin
  return epas_freeze_survey_execution_basis_v28(p_rfi_id);
end;$$;
create or replace function epas_start_survey_execution_v32(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
begin
  return epas_start_survey_execution_v28(p_rfi_id);
end;$$;
create or replace function epas_submit_survey_report_v32(
  p_rfi_id uuid,p_report_note text,p_observations jsonb,p_evidence_path text,p_evidence_sha256 text,
  p_mime_type text,p_size_bytes bigint,p_location text,p_survey_date date,p_attendance text,p_declaration text
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  return epas_submit_survey_report_v30(p_rfi_id,p_report_note,p_observations,p_evidence_path,p_evidence_sha256,p_mime_type,p_size_bytes,p_location,p_survey_date,p_attendance,p_declaration);
end;$$;
create or replace function epas_mark_in_service_cycle_complete_v32(p_rfi_id uuid,p_idempotency_key text)
returns survey_cycle_instances language plpgsql security definer set search_path=public as $$
begin
  return epas_mark_in_service_cycle_complete_v31(p_rfi_id,p_idempotency_key);
end;$$;

-- ------------------------------------------------------------------
-- 5. Explicit privileges: canonical v3.2 wrappers only for survey control.
-- ------------------------------------------------------------------
revoke all on function epas_schedule_queue_v32(uuid) from public;
revoke all on function epas_timeline_v32(uuid,integer) from public;
revoke all on function epas_survey_start_gate_v32(uuid) from public;
revoke all on function epas_survey_submission_gate_v32(uuid) from public;
revoke all on function epas_certificate_issuance_gate_v32(uuid,text) from public;
revoke all on function epas_set_in_service_schedule_basis_v32(uuid,integer,text,text,date,integer,integer,uuid) from public;
revoke all on function epas_register_certificate_pdf_v32(uuid,text,text,bigint) from public;
revoke all on function epas_surveyor_accept_assignment_v32(uuid,text) from public;
revoke all on function epas_acknowledge_survey_scope_v32(uuid,text) from public;
revoke all on function epas_acknowledge_survey_drawing_package_v32(uuid,text) from public;
revoke all on function epas_freeze_survey_execution_basis_v32(uuid) from public;
revoke all on function epas_start_survey_execution_v32(uuid) from public;
revoke all on function epas_submit_survey_report_v32(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) from public;
revoke all on function epas_mark_in_service_cycle_complete_v32(uuid,text) from public;
grant execute on function epas_schedule_queue_v32(uuid) to authenticated;
grant execute on function epas_timeline_v32(uuid,integer) to authenticated;
grant execute on function epas_survey_start_gate_v32(uuid) to authenticated;
grant execute on function epas_survey_submission_gate_v32(uuid) to authenticated;
grant execute on function epas_certificate_issuance_gate_v32(uuid,text) to authenticated;
grant execute on function epas_set_in_service_schedule_basis_v32(uuid,integer,text,text,date,integer,integer,uuid) to authenticated;
grant execute on function epas_register_certificate_pdf_v32(uuid,text,text,bigint) to authenticated;
grant execute on function epas_surveyor_accept_assignment_v32(uuid,text) to authenticated;
grant execute on function epas_acknowledge_survey_scope_v32(uuid,text) to authenticated;
grant execute on function epas_acknowledge_survey_drawing_package_v32(uuid,text) to authenticated;
grant execute on function epas_freeze_survey_execution_basis_v32(uuid) to authenticated;
grant execute on function epas_start_survey_execution_v32(uuid) to authenticated;
grant execute on function epas_submit_survey_report_v32(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;
grant execute on function epas_mark_in_service_cycle_complete_v32(uuid,text) to authenticated;

-- Revoke active direct access to underlying lower-version survey control RPCs.
DO $$
DECLARE r record;
  names text[] := ARRAY[
    'epas_survey_start_gate_v28','epas_survey_start_gate_v29','epas_survey_start_gate_v30',
    'epas_survey_submission_gate_v28','epas_survey_submission_gate_v29','epas_survey_submission_gate_v30',
    'epas_certificate_issuance_gate_v29','epas_certificate_issuance_gate_v30',
    'epas_set_in_service_schedule_basis_v28','epas_register_certificate_pdf_v15',
    'epas_surveyor_accept_assignment_v28','epas_acknowledge_survey_scope_v28','epas_acknowledge_survey_drawing_package_v27',
    'epas_freeze_survey_execution_basis_v28','epas_start_survey_execution_v28','epas_submit_survey_report_v30',
    'epas_mark_in_service_cycle_complete_v31'
  ];
BEGIN
  FOR r IN SELECT p.proname,pg_get_function_identity_arguments(p.oid) args FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname=ANY(names) LOOP
    EXECUTE format('revoke all on function public.%I(%s) from authenticated',r.proname,r.args);
  END LOOP;
END$$;

-- ------------------------------------------------------------------
-- 6. Privilege inventory for final deployment review.
-- ------------------------------------------------------------------
create or replace function epas_privilege_audit_v32()
returns table(routine_name text, identity_args text, authenticated_execute boolean, security_definer boolean, expected_v32_facade boolean)
language sql security definer stable set search_path=public as $$
  select p.proname, pg_get_function_identity_arguments(p.oid),
         has_function_privilege('authenticated',p.oid,'EXECUTE'),
         p.prosecdef,
         p.proname like '%_v32'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'epas_%'
  order by p.proname, pg_get_function_identity_arguments(p.oid);
$$;
revoke all on function epas_privilege_audit_v32() from public;
grant execute on function epas_privilege_audit_v32() to authenticated;

-- ------------------------------------------------------------------
-- 7. Scheduler and failure resilience controls.
-- ------------------------------------------------------------------
create index if not exists idx_scheduler_failures_status_retry_v32 on scheduler_failures_v29(status,next_retry_at,retry_count);
create index if not exists idx_scheduler_runs_started_status_v32 on scheduler_runs(started_at desc,status);

-- ------------------------------------------------------------------
-- 8. Release acceptance cases for every audit category.
-- ------------------------------------------------------------------
insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V32_CANONICAL_RPC_FACADE','all','all','Active Streamlit survey-control operations invoke only v3.2 canonical wrappers',false,'P0'),
('V32_LEGACY_SURVEY_RPC_REVOKED','all','survey','Lower-version survey gate/action RPCs are not executable by authenticated clients',true,'P0'),
('V32_PROJECT_HEALTH_BUNDLE','gm','all','Portfolio health is retrieved by one scoped bundle RPC rather than N+1 project calls',false,'P1'),
('V32_CERTIFICATE_UPLOAD_ROLLBACK','gm','certificate','Failed certificate metadata registration removes the temporary Storage object',false,'P1'),
('V32_SESSION_CACHE_BOUNDED','all','all','Session-local read cache is capped and expires entries',false,'P1'),
('V32_STAKEHOLDER_TIMELINE','shipyard','nsc_survey','Shipyard receives NSC-only released timeline events',true,'P0'),
('V32_STAKEHOLDER_TIMELINE_IS','owner','in_service','Owner receives In-Service business timeline events without internal diagnostics',true,'P0'),
('V32_CRON_RUNTIME','service','scheduler','v3.2 scheduler tick is installed and running every 15 minutes',false,'P0')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


-- ------------------------------------------------------------------
-- 9. Authorized project list for the active role, eliminating page-level
-- N+1 membership checks on stakeholder/designer surfaces.
-- ------------------------------------------------------------------
create or replace function epas_authorized_projects_v32()
returns table(id uuid,project_code text,name text,status text,phases text[],created_at timestamptz,updated_at timestamptz,vessel_name text,vessel_type text,flag_state text)
language plpgsql security definer stable set search_path=public as $$
declare role_name text;
begin
  role_name:=epas_v29_role();
  if role_name is null then raise exception 'Not authenticated'; end if;
  return query
  select p.id,p.project_code,p.name,p.status,p.phases,p.created_at,p.updated_at,
         v.name,v.vessel_type,v.flag_state
  from projects p
  left join vessels v on v.project_id=p.id
  where p.status='active'
    and (
      role_name in ('gm','dm')
      or exists(select 1 from project_members pm where pm.project_id=p.id and pm.user_id=auth.uid() and pm.active and pm.role=role_name)
      or (role_name='designer' and exists(select 1 from project_members pm where pm.project_id=p.id and pm.user_id=auth.uid() and pm.active and pm.role='designer'))
    )
  order by p.created_at desc;
end;$$;
revoke all on function epas_authorized_projects_v32() from public;
grant execute on function epas_authorized_projects_v32() to authenticated;

-- ------------------------------------------------------------------
-- 10. Final scheduler health queue for operations without full-table reads.
-- ------------------------------------------------------------------
create or replace function epas_scheduler_health_v32(p_limit integer default 20)
returns table(run_id uuid,started_at timestamptz,finished_at timestamptz,status text,critical_failures integer,notes text)
language sql security definer stable set search_path=public as $$
  select id,started_at,completed_at,status,coalesce((metadata->>'critical_failures')::integer,0),coalesce(error_message,'')
  from scheduler_runs order by started_at desc limit greatest(1,least(p_limit,50));
$$;
revoke all on function epas_scheduler_health_v32(integer) from public;
grant execute on function epas_scheduler_health_v32(integer) to authenticated;


-- ------------------------------------------------------------------
-- 11. Additional canonical read wrappers used by legacy-compatible query
-- names so the active application still resolves to the v3.2 policy layer.
-- ------------------------------------------------------------------
create or replace function epas_survey_checklist_ready_v32(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm','surveyor') then raise exception 'Checklist state is an internal survey control'; end if;
  return epas_survey_checklist_ready_v29(p_rfi_id);
end;$$;
create or replace function epas_survey_dependency_status_v32(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role() not in ('gm','dm','surveyor') then raise exception 'Survey dependency state is an internal survey control'; end if;
  return epas_survey_dependency_status_v27(p_rfi_id);
end;$$;
revoke all on function epas_survey_checklist_ready_v32(uuid) from public;
revoke all on function epas_survey_dependency_status_v32(uuid) from public;
grant execute on function epas_survey_checklist_ready_v32(uuid) to authenticated;
grant execute on function epas_survey_dependency_status_v32(uuid) to authenticated;
revoke all on function epas_survey_checklist_ready_v29(uuid) from authenticated;
revoke all on function epas_survey_dependency_status_v27(uuid) from authenticated;


-- ------------------------------------------------------------------
-- 12. Canonical v3.2 scheduler wrapper for production deployment.
-- ------------------------------------------------------------------
create or replace function epas_scheduler_tick_v32()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if current_user <> 'service_role' then raise exception 'Service role required'; end if;
  return epas_scheduler_tick_v31();
end;$$;
revoke all on function epas_scheduler_tick_v32() from public;
grant execute on function epas_scheduler_tick_v32() to service_role;

insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority)
values('V32_SCHEDULER_SERVICE_ONLY','service','scheduler','Only service_role can execute the canonical v3.2 scheduler tick',true,'P0')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;

commit;
