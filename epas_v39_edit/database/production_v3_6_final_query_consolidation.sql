-- EPAS v3.6 final query/service facade and privilege hardening.
-- Apply after v3.5.

-- Canonical v3.6 schedule read facade. Delegates only to the already self-contained v3.5 query logic.
create or replace function epas_schedule_queue_v36(p_project_id uuid default null)
returns table(schedule_id uuid,project_id uuid,vessel_id uuid,phase text,cycle_number integer,schedule_status text,schedule_config_status text,due_basis text,due_basis_reference text,due_basis_date date,next_due_date date,window_start date,window_end date,current_rfi_id uuid,stakeholder_safe boolean)
language sql security definer stable set search_path=public as $$
  select * from epas_schedule_queue_v35(p_project_id);
$$;

create or replace function epas_scheduler_health_v36(p_limit integer default 20)
returns table(run_id uuid,started_at timestamptz,finished_at timestamptz,status text,critical_failures integer,notes text)
language sql security definer stable set search_path=public as $$
  select * from epas_scheduler_health_v35(p_limit);
$$;

create or replace function epas_project_phase_workflow_v36(p_project_id uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select epas_project_phase_workflow_v35(p_project_id);
$$;

create or replace function epas_role_dashboard_bundle_v36()
returns jsonb language sql security definer stable set search_path=public as $$
  select epas_role_dashboard_bundle_v35();
$$;

-- Canonical critical survey gates.
create or replace function epas_survey_start_gate_v36(p_rfi_id uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select epas_survey_start_gate_v35(p_rfi_id);
$$;

create or replace function epas_survey_submission_gate_v36(p_rfi_id uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select epas_survey_submission_gate_v35(p_rfi_id);
$$;

create or replace function epas_mark_in_service_cycle_complete_v36(p_rfi_id uuid,p_idempotency_key text)
returns survey_cycle_instances language sql security definer set search_path=public as $$
  select epas_mark_in_service_cycle_complete_v35(p_rfi_id,p_idempotency_key);
$$;

create or replace function epas_set_in_service_schedule_basis_v36(p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_basis_date date,p_window_days_before integer default 90,p_window_days_after integer default 30,p_basis_document_id uuid default null)
returns survey_schedules language sql security definer set search_path=public as $$
  select epas_set_in_service_schedule_basis_v35(p_vessel_id,p_interval_months,p_due_basis,p_basis_reference,p_basis_date,p_window_days_before,p_window_days_after,p_basis_document_id);
$$;

-- Only the v3.6 facade is public application surface for these routines.
revoke all on function epas_schedule_queue_v36(uuid) from public;
grant execute on function epas_schedule_queue_v36(uuid) to authenticated;
revoke all on function epas_scheduler_health_v36(integer) from public;
grant execute on function epas_scheduler_health_v36(integer) to authenticated;
revoke all on function epas_project_phase_workflow_v36(uuid) from public;
grant execute on function epas_project_phase_workflow_v36(uuid) to authenticated;
revoke all on function epas_role_dashboard_bundle_v36() from public;
grant execute on function epas_role_dashboard_bundle_v36() to authenticated;
revoke all on function epas_survey_start_gate_v36(uuid) from public;
grant execute on function epas_survey_start_gate_v36(uuid) to authenticated;
revoke all on function epas_survey_submission_gate_v36(uuid) from public;
grant execute on function epas_survey_submission_gate_v36(uuid) to authenticated;
revoke all on function epas_mark_in_service_cycle_complete_v36(uuid,text) from public;
grant execute on function epas_mark_in_service_cycle_complete_v36(uuid,text) to authenticated;
revoke all on function epas_set_in_service_schedule_basis_v36(uuid,integer,text,text,date,integer,integer,uuid) from public;
grant execute on function epas_set_in_service_schedule_basis_v36(uuid,integer,text,text,date,integer,integer,uuid) to authenticated;

-- Retire authenticated access to older facade names.
do $$
declare r record;
  names text[] := array['epas_schedule_queue_v35','epas_timeline_v35','epas_survey_start_gate_v35','epas_survey_submission_gate_v35','epas_scheduler_health_v35','epas_mark_in_service_cycle_complete_v35','epas_set_in_service_schedule_basis_v35'];
begin
  for r in select p.proname,pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(names) loop
    execute format('revoke all on function public.%I(%s) from authenticated',r.proname,r.args);
  end loop;
end $$;

create index if not exists ix_project_members_user_role_active_v36 on project_members(user_id,role,active,project_id);
create index if not exists ix_survey_schedules_project_phase_status_v36 on survey_schedules(project_id,phase,status,next_due_date);
create index if not exists ix_rfis_project_phase_status_v36 on rfis(project_id,phase,status,created_at desc);
create index if not exists ix_workflow_tasks_to_user_status_due_v36 on workflow_tasks(to_user_id,status,due_at);
create index if not exists ix_documents_project_release_v36 on documents(project_id,release_status,uploaded_at desc);

insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V36_QUERY_FACADE_SINGLE_PUBLIC_SURFACE','all','all','Active application reads use the v3.6 production facade and legacy public facade execution is revoked',false,'P0'),
('V36_OWNER_FLEET_DRILLDOWN','owner','in_service','Fleet focus filters authorized vessels without cross-project leakage',false,'P1'),
('V36_SHIPYARD_NSC_JOURNEY','shipyard','nsc_survey','NSC journey is visible and no In-Service controls are exposed',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


-- v3.6 canonical action/read facade. Active app never calls lower-version RPCs directly.
create or replace function epas_scheduler_tick_v36()
returns jsonb language plpgsql security definer set search_path=public as $$
BEGIN
  IF current_user <> 'service_role' THEN RAISE EXCEPTION 'Service role required'; END IF;
  RETURN epas_scheduler_tick_v35();
END;$$;

create or replace function epas_survey_checklist_ready_v36(p_rfi_id uuid)
returns jsonb language sql security definer stable set search_path=public as $$ select epas_survey_checklist_ready_v33(p_rfi_id); $$;
create or replace function epas_acknowledge_survey_scope_v36(p_rfi_id uuid,p_note text default '')
returns jsonb language sql security definer set search_path=public as $$ select epas_acknowledge_survey_scope_v33(p_rfi_id,p_note); $$;
create or replace function epas_surveyor_accept_assignment_v36(p_rfi_id uuid,p_note text default '')
returns jsonb language sql security definer set search_path=public as $$ select epas_surveyor_accept_assignment_v33(p_rfi_id,p_note); $$;
create or replace function epas_acknowledge_survey_drawing_package_v36(p_rfi_id uuid,p_note text default '')
returns jsonb language sql security definer set search_path=public as $$ select epas_acknowledge_survey_drawing_package_v33(p_rfi_id); $$;
create or replace function epas_start_survey_execution_v36(p_rfi_id uuid)
returns jsonb language sql security definer set search_path=public as $$ select epas_start_survey_execution_v33(p_rfi_id); $$;
create or replace function epas_register_certificate_pdf_v36(p_certificate_id uuid,p_storage_path text,p_sha256 text,p_size_bytes bigint)
returns jsonb language sql security definer set search_path=public as $$ select epas_register_certificate_pdf_v33(p_certificate_id,p_storage_path,p_sha256,p_size_bytes); $$;
create or replace function epas_submit_survey_report_v36(p_rfi_id uuid,p_report_note text,p_observations jsonb,p_evidence_path text,p_evidence_sha256 text,p_mime_type text,p_size_bytes bigint,p_location text,p_survey_date date,p_attendance text,p_declaration text)
returns jsonb language sql security definer set search_path=public as $$ select epas_submit_survey_report_v33(p_rfi_id,p_report_note,p_observations,p_evidence_path,p_evidence_sha256,p_mime_type,p_size_bytes,p_location,p_survey_date,p_attendance,p_declaration); $$;
create or replace function epas_certificate_issuance_gate_v36(p_rfi_id uuid,p_cert_type text)
returns jsonb language sql security definer stable set search_path=public as $$ select epas_certificate_issuance_gate_v33(p_rfi_id,p_cert_type); $$;
create or replace function epas_set_in_service_schedule_basis_v36(p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_basis_date date,p_window_days_before integer default 90,p_window_days_after integer default 30,p_basis_document_id uuid default null)
returns survey_schedules language sql security definer set search_path=public as $$ select epas_set_in_service_schedule_basis_v35(p_vessel_id,p_interval_months,p_due_basis,p_basis_reference,p_basis_date,p_window_days_before,p_window_days_after,p_basis_document_id); $$;
create or replace function epas_mark_in_service_cycle_complete_v36(p_rfi_id uuid,p_idempotency_key text)
returns survey_cycle_instances language sql security definer set search_path=public as $$ select epas_mark_in_service_cycle_complete_v35(p_rfi_id,p_idempotency_key); $$;

-- Final facade privileges and retirement of application execution on v3.5 facade names.
do $$
declare r record; names text[] := array['epas_schedule_queue_v35','epas_scheduler_health_v35','epas_survey_start_gate_v35','epas_survey_submission_gate_v35','epas_mark_in_service_cycle_complete_v35','epas_set_in_service_schedule_basis_v35','epas_role_dashboard_bundle_v35'];
begin
  for r in select p.proname,pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(names) loop
    execute format('revoke all on function public.%I(%s) from authenticated',r.proname,r.args);
  end loop;
end$$;

revoke all on function epas_scheduler_tick_v36() from public,authenticated;
grant execute on function epas_scheduler_tick_v36() to service_role;
revoke all on function epas_survey_checklist_ready_v36(uuid) from public;
grant execute on function epas_survey_checklist_ready_v36(uuid) to authenticated;
revoke all on function epas_acknowledge_survey_scope_v36(uuid,text) from public;
grant execute on function epas_acknowledge_survey_scope_v36(uuid,text) to authenticated;
revoke all on function epas_surveyor_accept_assignment_v36(uuid,text) from public;
grant execute on function epas_surveyor_accept_assignment_v36(uuid,text) to authenticated;
revoke all on function epas_acknowledge_survey_drawing_package_v36(uuid,text) from public;
grant execute on function epas_acknowledge_survey_drawing_package_v36(uuid,text) to authenticated;
revoke all on function epas_start_survey_execution_v36(uuid) from public;
grant execute on function epas_start_survey_execution_v36(uuid) to authenticated;
revoke all on function epas_register_certificate_pdf_v36(uuid,text,text,bigint) from public;
grant execute on function epas_register_certificate_pdf_v36(uuid,text,text,bigint) to authenticated;
revoke all on function epas_submit_survey_report_v36(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) from public;
grant execute on function epas_submit_survey_report_v36(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;
revoke all on function epas_certificate_issuance_gate_v36(uuid,text) from public;
grant execute on function epas_certificate_issuance_gate_v36(uuid,text) to authenticated;
revoke all on function epas_set_in_service_schedule_basis_v36(uuid,integer,text,text,date,integer,integer,uuid) from public;
grant execute on function epas_set_in_service_schedule_basis_v36(uuid,integer,text,text,date,integer,integer,uuid) to authenticated;
revoke all on function epas_mark_in_service_cycle_complete_v36(uuid,text) from public;
grant execute on function epas_mark_in_service_cycle_complete_v36(uuid,text) to authenticated;

insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V36_ACTIVE_RPC_LAYER','all','all','Active production query layer calls v3.6 facade names; no active wrapper targets v3.3/v3.2 business RPCs',false,'P0'),
('V36_LEGACY_QUERY_ARCHIVED','all','all','database.queries contains no demo/in-memory business implementation',false,'P0')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


create or replace function epas_authorized_projects_v36()
returns table(project_id uuid,project_code text,name text,status text,phases text[]) language sql security definer stable set search_path=public as $$
  select p.id,p.project_code,p.name,p.status,p.phases from projects p join project_members pm on pm.project_id=p.id where pm.user_id=auth.uid() and pm.active;
$$;
create or replace function epas_role_dashboard_bundle_v36() returns jsonb language sql security definer stable set search_path=public as $$ select epas_role_dashboard_bundle_v35(); $$;
create or replace function epas_surveyor_accept_assignment_v36(p_rfi_id uuid,p_note text default '') returns jsonb language sql security definer set search_path=public as $$ select epas_surveyor_accept_assignment_v33(p_rfi_id,p_note); $$;
create or replace function epas_acknowledge_survey_drawing_package_v36(p_rfi_id uuid,p_note text default '') returns jsonb language sql security definer set search_path=public as $$ select epas_acknowledge_survey_drawing_package_v33(p_rfi_id); $$;
create or replace function epas_submit_survey_report_v36(p_rfi_id uuid,p_report_note text,p_observations jsonb,p_evidence_path text,p_evidence_sha256 text,p_mime_type text,p_size_bytes bigint,p_location text,p_survey_date date,p_attendance text,p_declaration text) returns jsonb language sql security definer set search_path=public as $$ select epas_submit_survey_report_v33(p_rfi_id,p_report_note,p_observations,p_evidence_path,p_evidence_sha256,p_mime_type,p_size_bytes,p_location,p_survey_date,p_attendance,p_declaration); $$;
create or replace function epas_start_survey_execution_v36(p_rfi_id uuid) returns jsonb language sql security definer set search_path=public as $$ select epas_start_survey_execution_v33(p_rfi_id); $$;
create or replace function epas_survey_checklist_ready_v36(p_rfi_id uuid) returns jsonb language sql security definer stable set search_path=public as $$ select epas_survey_checklist_ready_v33(p_rfi_id); $$;

revoke all on function epas_authorized_projects_v36() from public; grant execute on function epas_authorized_projects_v36() to authenticated;
revoke all on function epas_role_dashboard_bundle_v36() from public; grant execute on function epas_role_dashboard_bundle_v36() to authenticated;
revoke all on function epas_surveyor_accept_assignment_v36(uuid,text) from public; grant execute on function epas_surveyor_accept_assignment_v36(uuid,text) to authenticated;
revoke all on function epas_acknowledge_survey_drawing_package_v36(uuid,text) from public; grant execute on function epas_acknowledge_survey_drawing_package_v36(uuid,text) to authenticated;
revoke all on function epas_submit_survey_report_v36(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) from public; grant execute on function epas_submit_survey_report_v36(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;
revoke all on function epas_start_survey_execution_v36(uuid) from public; grant execute on function epas_start_survey_execution_v36(uuid) to authenticated;
revoke all on function epas_survey_checklist_ready_v36(uuid) from public; grant execute on function epas_survey_checklist_ready_v36(uuid) to authenticated;


create or replace function epas_owner_fleet_bundle_v36() returns jsonb language sql security definer stable set search_path=public as $$ select epas_owner_fleet_bundle_v35(); $$;
create or replace function epas_owner_fleet_vessels_v36() returns setof jsonb language sql security definer stable set search_path=public as $$ select to_jsonb(x) from epas_owner_fleet_vessels_v35() x; $$;
create or replace function epas_ship_management_bundle_v36() returns jsonb language sql security definer stable set search_path=public as $$ select epas_ship_management_bundle_v35(); $$;
create or replace function epas_ship_management_actions_v36() returns setof jsonb language sql security definer stable set search_path=public as $$ select to_jsonb(x) from epas_ship_management_actions_v35() x; $$;
create or replace function epas_shipyard_nsc_bundle_v36() returns jsonb language sql security definer stable set search_path=public as $$ select epas_shipyard_nsc_bundle_v35(); $$;
create or replace function epas_shipyard_nsc_projects_v36() returns setof jsonb language sql security definer stable set search_path=public as $$ select to_jsonb(x) from epas_shipyard_nsc_projects_v35() x; $$;
create or replace function epas_coordination_timeline_v36(p_project_id uuid,p_limit integer default 100) returns setof jsonb language sql security definer stable set search_path=public as $$ select to_jsonb(x) from epas_coordination_timeline_v35(p_project_id,p_limit) x; $$;
create or replace function epas_project_phase_workflow_v36(p_project_id uuid) returns jsonb language sql security definer stable set search_path=public as $$ select epas_project_phase_workflow_v35(p_project_id); $$;
create or replace function epas_role_dashboard_bundle_v36() returns jsonb language sql security definer stable set search_path=public as $$ select epas_role_dashboard_bundle_v35(); $$;
create or replace function epas_register_certificate_pdf_v36(p_certificate_id uuid,p_storage_path text,p_sha256 text,p_size_bytes bigint) returns jsonb language sql security definer set search_path=public as $$ select epas_register_certificate_pdf_v33(p_certificate_id,p_storage_path,p_sha256,p_size_bytes); $$;

revoke all on function epas_owner_fleet_bundle_v36() from public; grant execute on function epas_owner_fleet_bundle_v36() to authenticated;
revoke all on function epas_ship_management_bundle_v36() from public; grant execute on function epas_ship_management_bundle_v36() to authenticated;
revoke all on function epas_shipyard_nsc_bundle_v36() from public; grant execute on function epas_shipyard_nsc_bundle_v36() to authenticated;
revoke all on function epas_project_phase_workflow_v36(uuid) from public; grant execute on function epas_project_phase_workflow_v36(uuid) to authenticated;
revoke all on function epas_role_dashboard_bundle_v36() from public; grant execute on function epas_role_dashboard_bundle_v36() to authenticated;
revoke all on function epas_register_certificate_pdf_v36(uuid,text,text,bigint) from public; grant execute on function epas_register_certificate_pdf_v36(uuid,text,text,bigint) to authenticated;


-- v3.6 active service facade marker for legacy workflow actions.
insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V36_ACTIVE_COMPONENTS_CANONICAL','all','all','All active Streamlit components reference production v3.6 service names instead of legacy query module/version names',false,'P0')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


-- Self-contained v3.6 scheduler implementation. No call to an older scheduler routine.
create or replace function epas_scheduler_tick_v36()
returns jsonb
language plpgsql security definer set search_path=public as $$
declare run scheduler_runs; s record; n integer:=0; err integer:=0; critical integer:=0; msg text:='';
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  insert into scheduler_runs(run_type,status,started_at,metadata) values('EPAS_V3_6','RUNNING',now(),jsonb_build_object('version','3.6')) returning * into run;
  begin
    update survey_schedules
      set status=case
        when schedule_config_status='CONFIGURATION_REQUIRED' then 'SUSPENDED'
        when current_rfi_id is not null then 'RFI_OPEN'
        when next_due_date<current_date then 'OVERDUE'
        when next_due_date<=current_date+30 then 'DUE'
        when next_due_date<=current_date+90 then 'DUE_SOON'
        else 'SCHEDULED' end,
        updated_at=now(),row_version=coalesce(row_version,1)+1
    where active;

    for s in select * from survey_schedules where active and status in ('DUE_SOON','DUE','OVERDUE') loop
      begin
        update survey_cycle_instances c set status=case when s.current_rfi_id is not null then 'RFI_OPEN' when s.status='OVERDUE' then 'DUE' else 'DUE' end, updated_at=now()
        where c.schedule_id=s.id and c.cycle_number=s.cycle_number and c.status not in ('COMPLETED','CANCELLED');
        for m in select pm.user_id,pm.role from project_members pm join survey_notification_policy p on p.role_name=pm.role and p.phase=s.phase and p.event_type='SURVEY_DUE' and p.allowed where pm.project_id=s.project_id and pm.active loop
          if not exists(select 1 from notifications x where x.user_id=m.user_id and x.project_id=s.project_id and x.link_page='survey_schedule:'||s.id::text and x.created_at::date=current_date) then
            insert into notifications(user_id,title,body,project_id,link_page)
            values(m.user_id,
              case s.status when 'OVERDUE' then 'Survey overdue' when 'DUE' then 'Survey due' else 'Survey window approaching' end,
              format('%s %s survey cycle %s due %s.',s.survey_type,(select name from vessels where id=s.vessel_id),s.cycle_number,s.next_due_date),
              s.project_id,'survey_schedule:'||s.id::text);
            n:=n+1;
          end if;
        end loop;
        update vessels v set survey_status=case when s.status='OVERDUE' then 'IN_SERVICE_OVERDUE' when s.status in ('DUE','DUE_SOON') then 'IN_SERVICE_DUE' when s.current_rfi_id is not null then 'IN_SERVICE_IN_PROGRESS' else 'IN_SERVICE_ACTIVE' end where v.id=s.vessel_id and s.phase='in_service';
      exception when others then
        err:=err+1;
        if s.status='OVERDUE' then critical:=critical+1; end if;
        insert into scheduler_failures_v29(status,next_retry_at,retry_count,error_message,metadata) values('FAILED',now()+interval '15 minutes',1,sqlerrm,jsonb_build_object('version','3.6','schedule_id',s.id,'vessel_id',s.vessel_id));
      end;
    end loop;
    update scheduler_runs set completed_at=now(),status=case when err>0 then 'SUCCEEDED_WITH_ERRORS' else 'SUCCEEDED' end,processed_count=n,error_count=err,health_state=case when critical>0 then 'DEGRADED' else 'HEALTHY' end,metadata=jsonb_build_object('version','3.6','notifications',n,'errors',err,'critical_failures',critical) where id=run.id;
  exception when others then
    msg:=sqlerrm;
    update scheduler_runs set completed_at=now(),status='FAILED',error_message=msg,error_count=1,health_state='DEGRADED',metadata=jsonb_build_object('version','3.6','fatal',true) where id=run.id;
    raise;
  end;
  return jsonb_build_object('run_id',run.id,'version','3.6','status',case when err>0 then 'SUCCEEDED_WITH_ERRORS' else 'SUCCEEDED' end,'notifications',n,'errors',err,'critical_failures',critical);
end;$$;
revoke all on function epas_scheduler_tick_v36() from public,authenticated;
grant execute on function epas_scheduler_tick_v36() to service_role;
