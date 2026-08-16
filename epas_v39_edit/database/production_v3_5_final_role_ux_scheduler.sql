-- EPAS v3.5 — final role UX, self-contained scheduler, security policy and acceptance hardening
-- Apply after production_v3_4 / v3.3 cumulative release.
begin;
create extension if not exists pgcrypto;

-- ================================================================
-- 1. Explicit role-scoped stakeholder bundles: Owner / Ship Management / Shipyard.
-- ================================================================
create or replace function epas_owner_fleet_bundle_v35()
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare uid uuid:=auth.uid(); role_name text:=epas_v29_role(); result jsonb;
begin
  if uid is null or role_name <> 'owner' then raise exception 'Owner-only fleet bundle'; end if;
  select jsonb_build_object(
    'total_vessels', count(distinct v.id),
    'surveys_due', count(distinct s.id) filter (where s.phase='in_service' and s.status in ('DUE','DUE_SOON')),
    'surveys_overdue', count(distinct s.id) filter (where s.phase='in_service' and s.status='OVERDUE'),
    'certificates_expiring', (select count(*) from certificates c join project_members pm on pm.project_id=c.project_id where pm.user_id=uid and pm.active and pm.role='owner' and c.expiry_date between current_date and current_date+interval '90 days' and c.status not in ('expired','superseded')),
    'open_released_actions', (select count(*) from observations o join rfis r on r.id=o.rfi_id join project_members pm on pm.project_id=r.project_id where pm.user_id=uid and pm.active and pm.role='owner' and r.phase='in_service' and o.status in ('open','in_progress')),
    'in_class', count(distinct v.id) filter (where v.class_status='active')
  ) into result
  from project_members pm join vessels v on v.project_id=pm.project_id left join survey_schedules s on s.vessel_id=v.id and s.active
  where pm.user_id=uid and pm.active and pm.role='owner';
  return coalesce(result,'{}'::jsonb);
end;$$;

create or replace function epas_owner_fleet_vessels_v35()
returns table(vessel_id uuid,vessel_name text,imo_number text,class_status text,survey_status text,next_survey_due date,last_survey_date date,days_to_due integer,current_survey_type text,current_rfi_code text)
language sql security definer stable set search_path=public as $$
  select v.id,v.name,v.imo_number,v.class_status,v.survey_status,v.next_survey_due,v.last_survey_date,
         case when v.next_survey_due is null then null else (v.next_survey_due-current_date) end,
         s.survey_type,r.rfi_code
  from vessels v join project_members pm on pm.project_id=v.project_id and pm.user_id=auth.uid() and pm.active and pm.role='owner'
  left join survey_schedules s on s.vessel_id=v.id and s.active and s.phase='in_service'
  left join rfis r on r.id=s.current_rfi_id
  order by v.name;
$$;

create or replace function epas_ship_management_bundle_v35()
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare uid uuid:=auth.uid(); result jsonb;
begin
  if uid is null or epas_v29_role()<>'ship_management' then raise exception 'Ship Management-only bundle'; end if;
  select jsonb_build_object(
    'surveys_due', count(*) filter (where s.status in ('DUE','DUE_SOON')),
    'surveys_overdue', count(*) filter (where s.status='OVERDUE'),
    'open_corrective_actions', (select count(*) from corrective_actions ca join project_members pm on pm.project_id=ca.project_id where pm.user_id=uid and pm.active and pm.role='ship_management' and ca.assignee_id=uid and ca.status not in ('verified','closed')),
    'evidence_pending', (select count(*) from corrective_actions ca join project_members pm on pm.project_id=ca.project_id where pm.user_id=uid and pm.active and pm.role='ship_management' and ca.assignee_id=uid and ca.status in ('submitted','awaiting_verification')),
    'next_survey', min(s.next_due_date)
  ) into result
  from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='ship_management'
  where s.active and s.phase='in_service';
  return coalesce(result,'{}'::jsonb);
end;$$;

create or replace function epas_ship_management_actions_v35()
returns table(action_id uuid,action_code text,status text,requirement text,deficiency text,responsible_party text,target_date date,corrective_action text,evidence_status text,verification_status text,vessel_name text)
language sql security definer stable set search_path=public as $$
  select ca.id,'CA-'||right(ca.id::text,8),ca.status,
         coalesce(o.rule_reference,'—'),coalesce(o.description,'—'),coalesce(o.responsible_party,'—'),ca.due_at::date,
         coalesce(ca.instruction,'—'),
         case when exists(select 1 from observation_evidence oe where oe.corrective_action_id=ca.id) then 'SUBMITTED' else 'REQUIRED' end,
         case when ca.status in ('verified','closed') then 'VERIFIED' when ca.status='rejected' then 'REJECTED' else 'PENDING' end,
         v.name
  from corrective_actions ca
  left join observations o on o.corrective_action_id=ca.id
  left join rfis r on r.id=ca.rfi_id
  left join vessels v on v.id=r.vessel_id
  where ca.assignee_id=auth.uid() and ca.status not in ('verified','closed')
  order by ca.due_at nulls last,ca.created_at desc;
$$;

create or replace function epas_shipyard_nsc_bundle_v35()
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare uid uuid:=auth.uid(); result jsonb;
begin
  if uid is null or epas_v29_role()<>'shipyard' then raise exception 'Shipyard-only bundle'; end if;
  select jsonb_build_object(
    'nsc_projects',count(distinct s.project_id),
    'nsc_rfis',count(distinct r.id) filter (where r.phase='nsc_survey' and r.status not in ('closed','certificate_issued')),
    'surveys_due',count(distinct s.id) filter (where s.phase='nsc_survey' and s.status in ('DUE','DUE_SOON')),
    'open_released_observations',(select count(*) from observations o join rfis r2 on r2.id=o.rfi_id join project_members pm2 on pm2.project_id=r2.project_id where pm2.user_id=uid and pm2.active and pm2.role='shipyard' and r2.phase='nsc_survey' and o.status in ('open','in_progress')),
    'certificates',(select count(*) from certificates c join project_members pm3 on pm3.project_id=c.project_id where pm3.user_id=uid and pm3.active and pm3.role='shipyard' and c.status in ('active','issued'))
  ) into result
  from project_members pm join survey_schedules s on s.project_id=pm.project_id and s.active and s.phase='nsc_survey'
       left join rfis r on r.id=s.current_rfi_id
  where pm.user_id=uid and pm.active and pm.role='shipyard';
  return coalesce(result,'{}'::jsonb);
end;$$;

create or replace function epas_shipyard_nsc_projects_v35()
returns table(project_id uuid,project_code text,project_name text,vessel_name text,rfi_code text,rfi_status text,next_survey_due date,survey_status text)
language sql security definer stable set search_path=public as $$
  select p.id,p.project_code,p.name,v.name,r.rfi_code,r.status,s.next_due_date,v.survey_status
  from project_members pm join projects p on p.id=pm.project_id and pm.user_id=auth.uid() and pm.active and pm.role='shipyard'
  left join vessels v on v.project_id=p.id
  left join survey_schedules s on s.project_id=p.id and s.phase='nsc_survey' and s.active
  left join rfis r on r.id=s.current_rfi_id and r.phase='nsc_survey'
  where p.status='active'
  order by p.created_at desc;
$$;

-- ================================================================
-- 2. Cross-role coordination timeline: one authoritative, phase-filtered view.
-- ================================================================
create or replace function epas_coordination_timeline_v35(p_project_id uuid,p_limit integer default 100)
returns table(event_id uuid,occurred_at timestamptz,actor_role text,event_type text,phase text,summary text,entity_id uuid,visibility text)
language plpgsql security definer stable set search_path=public as $$
declare uid uuid:=auth.uid(); role_name text:=epas_v29_role();
begin
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=uid and pm.active) then raise exception 'Not authorized for coordination timeline'; end if;
  return query
  with base as (
    select le.id,le.created_at,coalesce(le.metadata->>'actor_role',case when le.actor_id is not null then (select role from profiles where id=le.actor_id) end,'system') actor_role,
           le.event_type,coalesce(le.metadata->>'phase',case when le.entity_type='rfi' then (select r.phase from rfis r where r.id=le.entity_id) end) phase_resolved,
           coalesce(le.note,le.action,le.event_type) summary,le.entity_id
    from lifecycle_events le where le.project_id=p_project_id
  )
  select b.id,b.created_at,b.actor_role,b.event_type,b.phase_resolved,b.summary,b.entity_id,
         case
           when role_name in ('gm','dm') then 'INTERNAL'
           when role_name='shipyard' and b.phase_resolved='nsc_survey' then 'NSC'
           when role_name in ('owner','ship_management') and b.phase_resolved='in_service' then 'IN_SERVICE'
           when role_name='surveyor' and exists(select 1 from rfis r where r.id=b.entity_id and r.assigned_surveyor_id=uid) then 'ASSIGNED_SURVEY'
           when role_name in ('engineer','designer') and b.phase_resolved='plan_appraisal' then 'PLAN'
           else 'GENERAL'
         end
  from base b
  where role_name in ('gm','dm')
     or (role_name='shipyard' and b.phase_resolved='nsc_survey')
     or (role_name in ('owner','ship_management') and b.phase_resolved='in_service')
     or (role_name='surveyor' and exists(select 1 from rfis r where r.id=b.entity_id and r.assigned_surveyor_id=uid))
     or (role_name in ('engineer','designer') and b.phase_resolved='plan_appraisal')
  order by b.created_at desc
  limit greatest(1,least(p_limit,200));
end;$$;

-- ================================================================
-- 3. Project phase workflow summary: plan-only / NSC / recurring In-Service.
-- ================================================================
create or replace function epas_project_phase_workflow_v35(p_project_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); phases text[]; plan_state text:='NOT_APPLICABLE'; nsc_state text:='NOT_APPLICABLE'; is_state text:='NOT_APPLICABLE';
begin
  if role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active) then raise exception 'Not authorized for project'; end if;
  select p.phases into phases from projects p where p.id=p_project_id;
  if phases is null then raise exception 'Project not found'; end if;
  if 'plan_appraisal'=any(phases) then
    if exists(select 1 from plan_drawings d where d.project_id=p_project_id and d.status not in ('approved','released','superseded')) then plan_state:='IN_PROGRESS'; else plan_state:='COMPLETED'; end if;
  end if;
  if 'nsc_survey'=any(phases) then
    if exists(select 1 from rfis r where r.project_id=p_project_id and r.phase='nsc_survey' and r.status in ('pending_gm_approval','approved','assigned','in_progress','pending_dm_verification')) then nsc_state:='IN_PROGRESS';
    elsif exists(select 1 from rfis r where r.project_id=p_project_id and r.phase='nsc_survey' and r.status in ('certificate_issued','closed')) then nsc_state:='COMPLETED';
    elsif coalesce(plan_state,'NOT_APPLICABLE') in ('COMPLETED','NOT_APPLICABLE') then nsc_state:='READY'; else nsc_state:='LOCKED'; end if;
  end if;
  if 'in_service'=any(phases) then
    if 'nsc_survey'=any(phases) and nsc_state not in ('COMPLETED','NOT_APPLICABLE') then is_state:='LOCKED'; else is_state:='ACTIVE'; end if;
  end if;
  return jsonb_build_object('project_id',p_project_id,'plan',plan_state,'nsc',nsc_state,'in_service',is_state,'phase_sequence',jsonb_build_array('PLAN','NSC','IN_SERVICE'));
end;$$;

-- ================================================================
-- 4. Final v3.5 self-contained scheduler. No older scheduler function call.
-- ================================================================
create or replace function epas_scheduler_tick_v35()
returns jsonb
language plpgsql security definer set search_path=public as $$
declare run scheduler_runs; s record; n integer:=0; err integer:=0; critical integer:=0; msg text:='';
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  insert into scheduler_runs(run_type,status,started_at,metadata) values('EPAS_V3_5','RUNNING',now(),jsonb_build_object('version','3.5')) returning * into run;
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
    end loop;
    update scheduler_runs set completed_at=now(),status=case when err>0 then 'SUCCEEDED_WITH_ERRORS' else 'SUCCEEDED' end,processed_count=n,error_count=err,health_state=case when critical>0 then 'DEGRADED' else 'HEALTHY' end,metadata=jsonb_build_object('version','3.5','notifications',n,'errors',err,'critical_failures',critical) where id=run.id;
  exception when others then
    msg:=sqlerrm;
    update scheduler_runs set completed_at=now(),status='FAILED',error_message=msg,error_count=1,health_state='DEGRADED',metadata=jsonb_build_object('version','3.5','fatal',true) where id=run.id;
    raise;
  end;
  return jsonb_build_object('run_id',run.id,'version','3.5','status','SUCCEEDED','notifications',n,'errors',err,'critical_failures',critical);
end;$$;

-- ================================================================
-- 5. Security allowlist, internal gate protection and RLS reassertion.
-- ================================================================
create or replace function epas_privilege_audit_v35()
returns table(routine_name text,identity_args text,authenticated_execute boolean,security_definer boolean,allowed_v35 boolean)
language sql security definer stable set search_path=public as $$
  select p.proname,pg_get_function_identity_arguments(p.oid),has_function_privilege('authenticated',p.oid,'EXECUTE'),p.prosecdef,
         p.proname = any(array['epas_schedule_queue_v35','epas_coordination_timeline_v35','epas_project_phase_workflow_v35','epas_owner_fleet_bundle_v35','epas_owner_fleet_vessels_v35','epas_ship_management_bundle_v35','epas_ship_management_actions_v35','epas_shipyard_nsc_bundle_v35','epas_shipyard_nsc_projects_v35','epas_survey_start_gate_v35','epas_survey_submission_gate_v35','epas_scheduler_health_v35','epas_role_dashboard_bundle_v35'])
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'epas_%' order by p.proname;
$$;

create or replace function epas_audit_chain_verify_v35(p_project_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=public as $$
declare prev text:='GENESIS'; e record; checked integer:=0; broken integer:=0;
begin
  if epas_v29_role() not in ('gm','dm') and not epas_is_project_member(p_project_id) then raise exception 'Not authorized for audit verification'; end if;
  for e in select id,previous_hash,event_hash,action,actor_id,project_id,details,created_at from audit_log where project_id=p_project_id order by created_at,id loop
    checked:=checked+1;
    if coalesce(e.previous_hash,'GENESIS')<>coalesce(prev,'GENESIS') then broken:=broken+1; end if;
    if coalesce(e.event_hash,'')<>encode(digest(coalesce(prev,'GENESIS')||'|'||coalesce(e.action,'')||'|'||coalesce(e.actor_id::text,'')||'|'||coalesce(e.project_id::text,'')||'|'||coalesce(e.details::text,'')||'|'||coalesce(e.created_at::text,''),'sha256'),'hex') then broken:=broken+1; end if;
    prev:=e.event_hash;
  end loop;
  return jsonb_build_object('project_id',p_project_id,'events_checked',checked,'broken_links',broken,'valid',broken=0);
end;$$;

-- Reassert RLS on operational/audit tables introduced by prior releases.
do $$
declare t text; tables text[]:=array['survey_cycle_instances','survey_checklist_instances','survey_assignment_acknowledgements','survey_scope_change_events','survey_scope_acknowledgements','survey_drawing_package_acknowledgements','epas_live_acceptance_runs_v33','scheduler_failures_v29','security_events_v29'];
begin
  foreach t in array tables loop
    execute format('alter table if exists public.%I enable row level security',t);
  end loop;
end$$;

create index if not exists ix_survey_schedules_phase_status_due_v35 on survey_schedules(phase,status,next_due_date,project_id);
create index if not exists ix_survey_cycles_schedule_status_v35 on survey_cycle_instances(schedule_id,status,cycle_number desc);
create index if not exists ix_lifecycle_events_project_created_v35 on lifecycle_events(project_id,created_at desc);
create index if not exists ix_notifications_user_created_v35 on notifications(user_id,created_at desc);
create index if not exists ix_corrective_actions_assignee_status_due_v35 on corrective_actions(assignee_id,status,target_date);
create index if not exists ix_observations_rfi_status_v35 on observations(rfi_id,status);

-- v3.5 public facade only. Older wrappers remain internally chained but are not the public product interface.
revoke all on function epas_schedule_queue_v33(uuid) from authenticated;
revoke all on function epas_timeline_v33(uuid,integer) from authenticated;
revoke all on function epas_survey_start_gate_v33(uuid) from authenticated;
revoke all on function epas_survey_submission_gate_v33(uuid) from authenticated;
revoke all on function epas_survey_checklist_ready_v33(uuid) from authenticated;
revoke all on function epas_certificate_issuance_gate_v33(uuid,text) from authenticated;

grant execute on function epas_owner_fleet_bundle_v35() to authenticated;
grant execute on function epas_owner_fleet_vessels_v35() to authenticated;
grant execute on function epas_ship_management_bundle_v35() to authenticated;
grant execute on function epas_ship_management_actions_v35() to authenticated;
grant execute on function epas_shipyard_nsc_bundle_v35() to authenticated;
grant execute on function epas_shipyard_nsc_projects_v35() to authenticated;
grant execute on function epas_coordination_timeline_v35(uuid,integer) to authenticated;
grant execute on function epas_project_phase_workflow_v35(uuid) to authenticated;
grant execute on function epas_privilege_audit_v35() to authenticated;
grant execute on function epas_audit_chain_verify_v35(uuid) to authenticated;
grant execute on function epas_scheduler_tick_v35() to service_role;
revoke all on function epas_scheduler_tick_v35() from authenticated,public;

insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V35_OWNER_FLEET','owner','in_service','Owner receives fleet-level status, due, overdue, expiring certificate and released-action summary',false,'P1'),
('V35_SHIP_MGMT_ACTION_CARD','ship_management','in_service','Corrective actions present requirement, deficiency, responsible party, due, action, evidence and verification in one authorized queue',false,'P1'),
('V35_SHIPYARD_NSC_CONSOLE','shipyard','nsc_survey','Shipyard receives NSC-only operations data and no In-Service schedule data',true,'P0'),
('V35_COORDINATION_TIMELINE','all','all','Cross-role handoffs are visible only within the role/phase data boundary',true,'P0'),
('V35_PHASE_WORKFLOW','gm','all','Plan-only, Plan+NSC, and Plan+NSC+In-Service sequencing is explicit',false,'P1'),
('V35_RECURRING_IN_SERVICE','owner','in_service','Completed cycle creates next cycle while In-Service phase remains ACTIVE',false,'P0'),
('V35_SELF_CONTAINED_SCHEDULER','service','scheduler','Scheduler status synchronization and due notifications execute without calling historical scheduler wrappers',false,'P0'),
('V35_GATE_DATA_MINIMIZATION','shipyard','nsc_survey','Stakeholder cannot receive internal gate diagnostics',true,'P0'),
('V35_AUDIT_CHAIN','gm','all','Audit chain can be verified and ordinary users cannot modify audit history',true,'P0'),
('V35_FILE_SECURITY','surveyor','all','Controlled upload requires signature, MIME, size, SHA-256 and configured malware policy',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


-- ================================================================
-- 6. v3.5 public read facade: the active application no longer calls v3.3
-- schedule/timeline wrappers directly.
-- ================================================================
create or replace function epas_schedule_queue_v35(p_project_id uuid default null)
returns table(schedule_id uuid,project_id uuid,vessel_id uuid,phase text,cycle_number integer,schedule_status text,schedule_config_status text,due_basis text,due_basis_reference text,due_basis_date date,next_due_date date,window_start date,window_end date,current_rfi_id uuid,stakeholder_safe boolean)
language plpgsql security definer stable set search_path=public as $$
declare role_name text; uid uuid;
begin
  uid:=auth.uid(); role_name:=epas_v29_role();
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if p_project_id is not null and role_name not in ('gm','dm') and not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=uid and pm.active) then raise exception 'Not authorized for project'; end if;
  return query
  select s.id,s.project_id,s.vessel_id,s.phase,s.cycle_number,s.status,s.schedule_config_status,
         case when role_name in ('gm','dm') then s.due_basis else null end,
         case when role_name in ('gm','dm') then s.due_basis_reference else null end,
         case when role_name in ('gm','dm') then s.due_basis_date else null end,
         s.next_due_date,s.window_start,s.window_end,s.current_rfi_id,role_name not in ('gm','dm')
  from survey_schedules s
  where s.active and (p_project_id is null or s.project_id=p_project_id)
    and (
      role_name in ('gm','dm')
      or (role_name='shipyard' and s.phase='nsc_survey' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='shipyard'))
      or (role_name in ('owner','ship_management') and s.phase='in_service' and exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role=role_name))
      or (role_name='surveyor' and exists(select 1 from rfis r where r.id=s.current_rfi_id and r.assigned_surveyor_id=uid))
    )
  order by s.next_due_date nulls last,s.phase,s.project_id;
end;$$;

create or replace function epas_timeline_v35(p_project_id uuid,p_limit integer default 100)
returns table(event_id uuid,event_type text,occurred_at timestamptz,summary text,phase text,entity_id uuid)
language sql security definer stable set search_path=public as $$
  select event_id,event_type,occurred_at,summary,phase,entity_id from epas_coordination_timeline_v35(p_project_id,p_limit);
$$;

create or replace function epas_survey_start_gate_v35(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if role_name not in ('gm','dm','surveyor') then raise exception 'Internal survey readiness is not exposed to this role'; end if;
  return epas_survey_start_gate_v33(p_rfi_id);
end;$$;

create or replace function epas_survey_submission_gate_v35(p_rfi_id uuid)
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare r rfis; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=epas_v29_role();
  if role_name='surveyor' and r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  if role_name='dm' and r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  if role_name not in ('gm','dm','surveyor') then raise exception 'Internal survey submission is not exposed to this role'; end if;
  return epas_survey_submission_gate_v33(p_rfi_id);
end;$$;

revoke all on function epas_schedule_queue_v35(uuid) from public;
revoke all on function epas_timeline_v35(uuid,integer) from public;
revoke all on function epas_survey_start_gate_v35(uuid) from public;
revoke all on function epas_survey_submission_gate_v35(uuid) from public;
grant execute on function epas_schedule_queue_v35(uuid) to authenticated;
grant execute on function epas_timeline_v35(uuid,integer) to authenticated;
grant execute on function epas_survey_start_gate_v35(uuid) to authenticated;
grant execute on function epas_survey_submission_gate_v35(uuid) to authenticated;

-- Remove public application execution of older active facades.
revoke all on function epas_schedule_queue_v33(uuid) from authenticated;
revoke all on function epas_timeline_v33(uuid,integer) from authenticated;
revoke all on function epas_survey_start_gate_v33(uuid) from authenticated;
revoke all on function epas_survey_submission_gate_v33(uuid) from authenticated;

insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority) values
('V35_CANONICAL_PUBLIC_READS','all','all','Active Streamlit reads call v3.5 schedule/timeline/gate facades only',false,'P0'),
('V35_PUBLIC_V33_REVOKED','all','all','v3.3 schedule/timeline/gate facades are not executable by authenticated application users',true,'P0')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


-- ================================================================
-- 7. v3.5 compact role dashboard bundle with no page-level project loops.
-- ================================================================
create or replace function epas_role_dashboard_bundle_v35()
returns jsonb language plpgsql security definer stable set search_path=public as $$
declare role_name text:=epas_v29_role(); uid uuid:=auth.uid(); active_projects integer:=0; open_tasks integer:=0; overdue_tasks integer:=0; open_actions integer:=0; schedule_due integer:=0; schedule_overdue integer:=0; pending_decisions integer:=0; open_certificates integer:=0;
begin
  if uid is null or role_name is null then raise exception 'Not authenticated'; end if;
  if role_name in ('gm','dm') then select count(*) into active_projects from projects where status='active';
  else select count(distinct pm.project_id) into active_projects from project_members pm where pm.user_id=uid and pm.active and pm.role=role_name; end if;
  select count(*) into open_tasks from workflow_tasks where to_user_id=uid and status in ('pending','accepted','in_progress');
  select count(*) into overdue_tasks from workflow_tasks where to_user_id=uid and status in ('pending','accepted','in_progress') and coalesce(due_at,now())<now();
  if role_name='gm' then
    select count(*) into pending_decisions from rfis where status='pending_gm_approval';
    select count(*) into open_certificates from certificates where status in ('draft','pending_approval','gm_approved','pending_dm_ack','ready_for_issuance');
  elsif role_name='dm' then
    select count(*) into open_actions from corrective_actions ca where ca.assigned_by=uid and ca.status not in ('verified','closed');
  elsif role_name='engineer' then
    select count(*) into open_actions from plan_appraisal_observations o where o.response_by=uid and o.status not in ('closed','approved');
  elsif role_name='surveyor' then
    select count(*) into open_actions from workflow_tasks wt where wt.to_user_id=uid and wt.task_type='CORRECTIVE_ACTION_EXECUTION' and wt.status not in ('completed','closed');
  elsif role_name='owner' then
    select count(*) into schedule_due from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='owner' where s.active and s.phase='in_service' and s.status in ('DUE','DUE_SOON');
    select count(*) into schedule_overdue from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='owner' where s.active and s.phase='in_service' and s.status='OVERDUE';
  elsif role_name='ship_management' then
    select count(*) into schedule_due from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='ship_management' where s.active and s.phase='in_service' and s.status in ('DUE','DUE_SOON');
    select count(*) into schedule_overdue from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='ship_management' where s.active and s.phase='in_service' and s.status='OVERDUE';
    select count(*) into open_actions from corrective_actions ca where ca.assignee_id=uid and ca.status not in ('verified','closed');
  elsif role_name='shipyard' then
    select count(*) into schedule_due from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='shipyard' where s.active and s.phase='nsc_survey' and s.status in ('DUE','DUE_SOON');
    select count(*) into schedule_overdue from survey_schedules s join project_members pm on pm.project_id=s.project_id and pm.user_id=uid and pm.active and pm.role='shipyard' where s.active and s.phase='nsc_survey' and s.status='OVERDUE';
  end if;
  return jsonb_build_object('role',role_name,'active_projects',active_projects,'open_tasks',open_tasks,'overdue_tasks',overdue_tasks,'open_actions',open_actions,'schedule_due',schedule_due,'schedule_overdue',schedule_overdue,'pending_decisions',pending_decisions,'open_certificates',open_certificates);
end;$$;
revoke all on function epas_role_dashboard_bundle_v35() from public;
grant execute on function epas_role_dashboard_bundle_v35() to authenticated;

insert into workflow_acceptance_cases_v29(case_code,role_name,phase,expected_result,negative,priority)
values('V35_ROLE_DASHBOARD_BUNDLE','all','all','Role dashboard loads a compact role-specific bundle without N+1 project health calls',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,priority=excluded.priority;


-- Reassert the authoritative stakeholder RFI policy in the final migration.
insert into rfi_creation_policy(role_name,phase,allowed,description) values
('shipyard','nsc_survey',true,'Shipyard may initiate NSC Survey RFI'),
('shipyard','in_service',false,'Shipyard may not initiate In-Service Survey RFI'),
('owner','nsc_survey',false,'Owner may not initiate NSC Survey RFI'),
('owner','in_service',true,'Owner may initiate In-Service Survey RFI'),
('ship_management','nsc_survey',false,'Ship Management may not initiate NSC Survey RFI'),
('ship_management','in_service',true,'Ship Management may initiate In-Service Survey RFI')
on conflict(role_name,phase) do update set allowed=excluded.allowed,description=excluded.description;

commit;
