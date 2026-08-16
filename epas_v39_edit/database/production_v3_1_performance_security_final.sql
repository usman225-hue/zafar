-- EPAS v3.1 — final multi-user session, performance, storage and security hardening
-- Baseline: v3.0
begin;
create extension if not exists pgcrypto;

-- ------------------------------------------------------------------
-- 1. RLS: reassert deny-by-default operational tables and add RLS to
-- privilege registry / scheduler metadata where appropriate.
-- ------------------------------------------------------------------
alter table epas_privilege_registry_v30 enable row level security;
drop policy if exists epas_privilege_registry_select_v31 on epas_privilege_registry_v30;
create policy epas_privilege_registry_select_v31 on epas_privilege_registry_v30
for select to authenticated using (epas_v29_role() in ('gm','dm'));
drop policy if exists epas_privilege_registry_write_v31 on epas_privilege_registry_v30;
create policy epas_privilege_registry_write_v31 on epas_privilege_registry_v30
for all to authenticated using(false) with check(false);

-- Direct client writes to workflow/system tables remain forbidden.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'survey_cycle_instances','survey_checklist_instances','survey_assignment_acknowledgements',
    'survey_scope_change_events','survey_scope_acknowledgements','survey_drawing_package_acknowledgements',
    'security_events_v29','scheduler_failures_v29','workflow_acceptance_cases_v29','epas_privilege_registry_v30'
  ] LOOP
    EXECUTE format('alter table %I enable row level security', t);
  END LOOP;
END$$;

-- ------------------------------------------------------------------
-- 2. Final stakeholder-safe schedule/timeline access: role + phase.
-- ------------------------------------------------------------------
create or replace function epas_schedule_queue_v31(p_project_id uuid default null)
returns table(
  schedule_id uuid, project_id uuid, vessel_id uuid, phase text, cycle_number integer,
  schedule_status text, schedule_config_status text, due_basis text, due_basis_reference text,
  due_basis_date date, next_due_date date, window_start date, window_end date, current_rfi_id uuid,
  stakeholder_safe boolean
)
language plpgsql security definer stable set search_path=public as $$
declare role_name text;
begin
  role_name:=epas_v29_role();
  if role_name is null then raise exception 'Not authenticated'; end if;
  if p_project_id is not null and not exists(
    select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active
  ) and role_name not in ('gm','dm') then raise exception 'Not authorized for project'; end if;
  return query
  select s.id,s.project_id,s.vessel_id,s.phase,s.cycle_number,s.status,s.schedule_config_status,
         case when role_name in ('gm','dm') then s.due_basis else null end,
         case when role_name in ('gm','dm') then s.due_basis_reference else null end,
         case when role_name in ('gm','dm') then s.due_basis_date else null end,
         s.next_due_date,s.window_start,s.window_end,s.current_rfi_id,
         role_name not in ('gm','dm')
  from survey_schedules s
  where s.active
    and (p_project_id is null or s.project_id=p_project_id)
    and (
      role_name in ('gm','dm')
      or (role_name='shipyard' and s.phase='nsc_survey' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=auth.uid() and pm.active))
      or (role_name in ('owner','ship_management') and s.phase='in_service' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=auth.uid() and pm.active))
      or (role_name='surveyor' and exists(select 1 from rfis r where r.id=s.current_rfi_id and r.assigned_surveyor_id=auth.uid()))
    )
  order by s.next_due_date nulls last,s.window_start nulls last,s.phase;
end;$$;
grant execute on function epas_schedule_queue_v31(uuid) to authenticated;

create or replace function epas_timeline_v31(p_project_id uuid,p_limit integer default 100)
returns table(event_id uuid,event_type text,occurred_at timestamptz,summary text,phase text,entity_id uuid)
language plpgsql security definer stable set search_path=public as $$
declare role_name text;
begin
  role_name:=epas_v29_role();
  if role_name is null then raise exception 'Not authenticated'; end if;
  if role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active) then raise exception 'Not authorized for project timeline'; end if;
  return query
  select le.id,le.event_type,le.created_at,
    case
      when role_name in ('gm','dm') then coalesce(le.note,le.event_type)
      when role_name='shipyard' and coalesce(le.metadata->>'phase', '')='nsc_survey' then coalesce(le.event_type,'NSC workflow event')
      when role_name in ('owner','ship_management') and coalesce(le.metadata->>'phase', '')='in_service' then coalesce(le.event_type,'In-Service workflow event')
      when role_name='surveyor' and exists(select 1 from rfis r where r.id=le.entity_id and r.assigned_surveyor_id=auth.uid()) then coalesce(le.event_type,'Survey workflow event')
      when role_name in ('engineer','designer') and coalesce(le.metadata->>'phase','')='plan_appraisal' then coalesce(le.event_type,'Plan workflow event')
      else 'Authorized workflow event'
    end,
    coalesce(le.metadata->>'phase', case when le.entity_type='rfi' then (select r.phase from rfis r where r.id=le.entity_id) end), le.entity_id
  from lifecycle_events le
  where le.project_id=p_project_id
    and (
      role_name in ('gm','dm')
      or (role_name='shipyard' and coalesce(le.metadata->>'phase','')='nsc_survey')
      or (role_name in ('owner','ship_management') and coalesce(le.metadata->>'phase','')='in_service')
      or (role_name='surveyor' and exists(select 1 from rfis r where r.id=le.entity_id and r.assigned_surveyor_id=auth.uid()))
      or (role_name in ('engineer','designer') and coalesce(le.metadata->>'phase','')='plan_appraisal')
    )
  order by le.created_at desc limit greatest(1,least(p_limit,200));
end;$$;
grant execute on function epas_timeline_v31(uuid,integer) to authenticated;

-- ------------------------------------------------------------------
-- 3. Compact per-role dashboard bundle. One RPC replaces repeated KPI
-- reads and reduces Streamlit rerun database calls.
-- ------------------------------------------------------------------
create or replace function epas_role_dashboard_bundle_v31()
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare role_name text; uid uuid; active_projects integer:=0; open_tasks integer:=0; overdue_tasks integer:=0; open_actions integer:=0; pending_decisions integer:=0; open_certificates integer:=0; schedule_due integer:=0; schedule_overdue integer:=0;
begin
  uid:=auth.uid(); role_name:=epas_v29_role();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if role_name in ('gm','dm') then
    select count(*) into active_projects from projects where status='active';
  else
    select count(distinct pm.project_id) into active_projects from project_members pm where pm.user_id=uid and pm.active;
  end if;
  select count(*) into open_tasks from workflow_tasks wt where wt.to_user_id=uid and wt.status in ('pending','accepted','in_progress');
  select count(*) into overdue_tasks from workflow_tasks wt where wt.to_user_id=uid and wt.status in ('pending','accepted','in_progress') and coalesce(wt.due_at,now())<now();
  if role_name='gm' then
    select count(*) into pending_decisions from rfis r where r.status='pending_gm_approval';
  elsif role_name='dm' then
    select count(*) into pending_decisions from workflow_tasks wt where wt.to_user_id=uid and wt.status in ('pending','accepted','in_progress');
  end if;
  if role_name in ('gm','dm') then
    select count(*) into open_actions from observations o where o.status in ('open','in_progress');
    select count(*) into open_certificates from certificates c where c.status in ('draft','pending_approval','gm_approved','pending_dm_ack','ready_for_issuance');
  elsif role_name in ('owner','ship_management') then
    select count(*) into schedule_due from survey_schedules s where s.active and s.phase='in_service' and s.status in ('DUE','DUE_SOON','OVERDUE') and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
    select count(*) into schedule_overdue from survey_schedules s where s.active and s.phase='in_service' and s.status='OVERDUE' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
    select count(*) into open_actions from corrective_actions ca where ca.assignee_id=uid and ca.status not in ('verified','closed');
  elsif role_name='shipyard' then
    select count(*) into schedule_due from survey_schedules s where s.active and s.phase='nsc_survey' and s.status in ('DUE','DUE_SOON','OVERDUE') and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active);
  end if;
  return jsonb_build_object('role',role_name,'active_projects',active_projects,'open_tasks',open_tasks,'overdue_tasks',overdue_tasks,
    'open_actions',open_actions,'pending_decisions',pending_decisions,'open_certificates',open_certificates,'schedule_due',schedule_due,'schedule_overdue',schedule_overdue);
end;$$;
grant execute on function epas_role_dashboard_bundle_v31() to authenticated;

-- ------------------------------------------------------------------
-- 4. Row-versioning for concurrency-safe operational edits.
-- ------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['survey_scopes','survey_assignments','survey_executions','survey_cycle_instances','survey_checklist_instances'] LOOP
    EXECUTE format('alter table %I add column if not exists row_version bigint not null default 1', t);
    EXECUTE format('create index if not exists idx_%s_row_version on %I(id,row_version)', lower(t), t);
  END LOOP;
END$$;

create or replace function epas_touch_row_version_v31()
returns trigger language plpgsql as $$
begin
  new.row_version:=coalesce(old.row_version,1)+1;
  return new;
end;$$;

drop trigger if exists trg_scopes_row_version_v31 on survey_scopes;
create trigger trg_scopes_row_version_v31 before update on survey_scopes for each row execute function epas_touch_row_version_v31();
drop trigger if exists trg_assignments_row_version_v31 on survey_assignments;
create trigger trg_assignments_row_version_v31 before update on survey_assignments for each row execute function epas_touch_row_version_v31();
drop trigger if exists trg_executions_row_version_v31 on survey_executions;
create trigger trg_executions_row_version_v31 before update on survey_executions for each row execute function epas_touch_row_version_v31();
drop trigger if exists trg_cycles_row_version_v31 on survey_cycle_instances;
create trigger trg_cycles_row_version_v31 before update on survey_cycle_instances for each row execute function epas_touch_row_version_v31();
drop trigger if exists trg_checklist_instance_row_version_v31 on survey_checklist_instances;
create trigger trg_checklist_instance_row_version_v31 before update on survey_checklist_instances for each row execute function epas_touch_row_version_v31();

-- ------------------------------------------------------------------
-- 5. Performance indexes for the high-frequency dashboard/workflow reads.
-- ------------------------------------------------------------------
create index if not exists idx_workflow_tasks_user_status_due_v31 on workflow_tasks(to_user_id,status,due_at,created_at desc);
create index if not exists idx_notifications_user_read_created_v31 on notifications(user_id,read_at,created_at desc);
create index if not exists idx_projects_status_created_v31 on projects(status,created_at desc);
create index if not exists idx_project_members_user_active_v31 on project_members(user_id,active,project_id);
create index if not exists idx_rfis_project_status_updated_v31 on rfis(project_id,status,updated_at desc);
create index if not exists idx_rfis_assigned_surveyor_status_v31 on rfis(assigned_surveyor_id,status,updated_at desc);
create index if not exists idx_plan_drawings_project_updated_v31 on plan_drawings(project_id,updated_at desc);
create index if not exists idx_observations_rfi_status_v31 on observations(rfi_id,status,raised_at desc);
create index if not exists idx_corrective_actions_assignee_status_v31 on corrective_actions(assignee_id,status,due_at);
create index if not exists idx_survey_schedules_phase_due_v31 on survey_schedules(project_id,phase,active,next_due_date);
create index if not exists idx_survey_cycles_schedule_status_due_v31 on survey_cycle_instances(schedule_id,status,due_date);
create index if not exists idx_lifecycle_events_project_created_v31 on lifecycle_events(project_id,created_at desc);

-- ------------------------------------------------------------------
-- 6. Storage final policy: internal access + released stakeholder access;
-- no direct client update/delete. Uploads must belong to a project member.
-- ------------------------------------------------------------------
drop policy if exists epas_project_documents_select_v31 on storage.objects;
create policy epas_project_documents_select_v31 on storage.objects
for select to authenticated using (
  bucket_id='project-documents' and (
    exists(
      select 1 from documents d join project_members pm on pm.project_id=d.project_id
      where d.storage_path=name and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')
    )
    or exists(
      select 1 from documents d join project_members pm on pm.project_id=d.project_id
      where d.storage_path=name and d.stakeholder_visible=true and d.release_status='released'
        and pm.user_id=auth.uid() and pm.active and pm.role in ('owner','shipyard','ship_management','designer')
    )
    or exists(select 1 from documents d where d.storage_path=name and d.uploaded_by=auth.uid())
    or exists(
      select 1 from survey_rfi_drawings srd join rfis r on r.id=srd.rfi_id
      where srd.storage_path=name and r.assigned_surveyor_id=auth.uid() and srd.package_state='ACTIVE'
    )
  )
);
drop policy if exists epas_project_documents_insert_v31 on storage.objects;
create policy epas_project_documents_insert_v31 on storage.objects
for insert to authenticated with check (
  bucket_id='project-documents'
  and split_part(name,'/',1)='projects'
  and split_part(name,'/',2) ~ '^[0-9a-fA-F-]{36}$'
  and exists(select 1 from project_members pm where pm.project_id=(split_part(name,'/',2))::uuid and pm.user_id=auth.uid() and pm.active)
);
drop policy if exists epas_project_documents_update_v31 on storage.objects;
create policy epas_project_documents_update_v31 on storage.objects for update to authenticated using(false) with check(false);
drop policy if exists epas_project_documents_delete_v31 on storage.objects;
create policy epas_project_documents_delete_v31 on storage.objects for delete to authenticated using(false);

-- ------------------------------------------------------------------
-- 7. Final privilege audit helper: GM-only visibility of SECURITY DEFINER
-- routines granted to authenticated, for deployment verification.
-- ------------------------------------------------------------------
create or replace function epas_security_privilege_audit_v31()
returns table(routine_name text, identity_args text, security_definer boolean, authenticated_execute boolean)
language plpgsql security definer stable set search_path=public as $$
begin
  if epas_v29_role()<>'gm' then raise exception 'Security privilege audit is GM-only'; end if;
  return query
  select p.proname, pg_get_function_identity_arguments(p.oid), p.prosecdef,
         has_function_privilege('authenticated',p.oid,'EXECUTE')
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and p.prosecdef
  order by p.proname, identity_args;
end;$$;
grant execute on function epas_security_privilege_audit_v31() to authenticated;

-- ------------------------------------------------------------------
-- 8. Scheduler health: escalate repeated failures automatically.
-- ------------------------------------------------------------------
alter table scheduler_failures_v29 add column if not exists retry_count integer not null default 0;
alter table scheduler_failures_v29 add column if not exists last_attempt_at timestamptz;
create index if not exists idx_scheduler_failures_status_retry_v31 on scheduler_failures_v29(status,next_retry_at,created_at);

create or replace function epas_scheduler_health_v31()
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare open_failures integer; critical_failures integer; recent_errors integer; latest scheduler_runs;
begin
  if epas_v29_role() not in ('gm','dm') then raise exception 'Scheduler health is internal'; end if;
  select count(*) into open_failures from scheduler_failures_v29 where status in ('OPEN','RETRYING');
  select count(*) into critical_failures from scheduler_failures_v29 where status in ('OPEN','RETRYING') and coalesce(retry_count,0)>=3;
  select count(*) into recent_errors from scheduler_runs where error_count>0 and started_at>now()-interval '24 hours';
  select * into latest from scheduler_runs order by started_at desc limit 1;
  return jsonb_build_object('open_failures',open_failures,'critical_failures',critical_failures,'recent_error_runs',recent_errors,'latest_run',to_jsonb(latest),
    'health_state',case when critical_failures>0 or recent_errors>0 then 'DEGRADED' when open_failures>0 then 'WARNING' else 'HEALTHY' end);
end;$$;
grant execute on function epas_scheduler_health_v31() to authenticated;


-- ------------------------------------------------------------------

-- ------------------------------------------------------------------
-- 9A. Production scheduler v3.1 wrapper with retry/error bookkeeping.
-- ------------------------------------------------------------------
create or replace function epas_scheduler_tick_v31()
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb; degraded integer:=0;
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  result:=epas_scheduler_tick_v29();
  update scheduler_failures_v29
    set retry_count=coalesce(retry_count,0)+1,last_attempt_at=now(),
        status=case when coalesce(retry_count,0)>=2 then 'RETRYING' else status end,
        next_retry_at=case when coalesce(retry_count,0)>=2 then now()+interval '15 minutes' else now()+interval '5 minutes' end
  where status in ('OPEN','RETRYING') and (next_retry_at is null or next_retry_at<=now());
  select count(*) into degraded from scheduler_failures_v29 where status in ('OPEN','RETRYING') and coalesce(retry_count,0)>=3;
  return result || jsonb_build_object('version','3.1','critical_failures',degraded);
end;$$;
grant execute on function epas_scheduler_tick_v31() to service_role;
revoke all on function epas_scheduler_tick_v31() from authenticated;

-- 9. Final recurring-cycle completion: no silent interval fallback.
-- ------------------------------------------------------------------
create or replace function epas_mark_in_service_cycle_complete_v31(p_rfi_id uuid,p_idempotency_key text)
returns survey_cycle_instances
language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_schedules; c survey_cycle_instances; n survey_cycle_instances; role_name text; next_no integer; next_due date;
begin
  if coalesce(trim(p_idempotency_key),'')='' then raise exception 'Idempotency key is required'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null or r.phase<>'in_service' then raise exception 'In-Service RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name not in ('gm','dm') then raise exception 'Only GM/DM may complete an In-Service cycle'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not authorized for project'; end if;
  select * into s from survey_schedules where project_id=r.project_id and vessel_id=r.vessel_id and phase='in_service' and active order by updated_at desc limit 1 for update;
  if s.id is null then raise exception 'Active In-Service schedule not found'; end if;
  if s.schedule_config_status<>'CONFIGURED' or coalesce(s.survey_interval_months,0)<=0 then raise exception 'Survey schedule interval/basis is not configured'; end if;
  select * into c from survey_cycle_instances where rfi_id=r.id for update;
  if c.id is null then raise exception 'Survey cycle instance not found'; end if;
  if c.status='COMPLETED' then return c; end if;
  if c.completion_idempotency_key is not null then
    if c.completion_idempotency_key=p_idempotency_key then return c; end if;
    raise exception 'This cycle has already been completed with another idempotency key';
  end if;
  update survey_cycle_instances set status='COMPLETED',completed_at=coalesce(completed_at,now()),completion_idempotency_key=p_idempotency_key,phase_lifecycle='ACTIVE',updated_at=now() where id=c.id;
  next_no:=c.cycle_number+1;
  next_due:=coalesce(s.next_due_date,c.due_date,current_date)+(s.survey_interval_months * interval '1 month');
  select * into n from survey_cycle_instances where schedule_id=s.id and cycle_number=next_no limit 1 for update;
  if n.id is null then
    insert into survey_cycle_instances(schedule_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,source_certificate_id,schedule_basis,schedule_basis_reference,phase_lifecycle)
    values(s.id,s.project_id,s.vessel_id,'in_service',next_no,'DUE',next_due::date,(next_due::date-coalesce(s.window_days_before,90)),(next_due::date+coalesce(s.window_days_after,30)),s.source_certificate_id,s.due_basis,s.due_basis_reference,'ACTIVE') returning * into n;
  end if;
  update survey_schedules set cycle_number=n.cycle_number,next_due_date=n.due_date,window_start=n.window_start,window_end=n.window_end,current_rfi_id=null,cycle_instance_id=n.id,phase_lifecycle='ACTIVE',last_cycle_idempotency_key=p_idempotency_key,updated_at=now() where id=s.id;
  return n;
end;$$;
grant execute on function epas_mark_in_service_cycle_complete_v31(uuid,text) to authenticated;
revoke all on function epas_mark_in_service_cycle_complete_v30(uuid,text) from authenticated;

-- ------------------------------------------------------------------
-- 10. Operational acceptance cases for v3.1.
-- ------------------------------------------------------------------
insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V31_SESSION_ISOLATION','all','all','Each Streamlit session maintains its own authenticated Supabase client; no cross-user JWT/session reuse',true,'P0'),
('V31_DB_INDEXES','all','all','High-frequency workflow queries use project/user/status/date indexes',false,'P1'),
('V31_STORAGE_SCOPE','owner','in_service','Owner cannot read unreleased/internal project files or NSC-only files',true,'P0'),
('V31_SCHEDULE_SCOPE','shipyard','nsc_survey','Shipyard cannot retrieve In-Service schedule rows',true,'P0'),
('V31_PRIVILEGE_AUDIT','gm','all','GM can inspect SECURITY DEFINER functions executable by authenticated and confirm allowlist',false,'P0'),
('V31_UPLOAD_ROLLBACK','surveyor','nsc_survey|in_service','Failed artifact registration removes the temporary storage object',false,'P1'),
('V31_ROW_VERSION','dm','nsc_survey|in_service','Operational edits increment row_version to expose concurrent changes',false,'P1'),
('V31_DASHBOARD_BUNDLE','all','all','Role dashboard metrics can be loaded with one compact RPC',false,'P1'),
('V31_NO_SILENT_INTERVAL','gm','in_service','Cycle completion is blocked when the survey interval is not explicitly configured',true,'P0')
on conflict(case_code) do update set expected_result=excluded.expected_result,negative=excluded.negative,priority=excluded.priority;

commit;
