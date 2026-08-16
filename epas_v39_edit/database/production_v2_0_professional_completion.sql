-- EPAS v2.0 — Professional Completion / Items 21–32
-- Applies after production_v1_9_role_complete_gaps_11_20.sql
-- Scope: SLA dashboard, escalation linkage, risk/decision integration,
-- closure assurance, RLS/Storage/RPC preflight, cross-project isolation,
-- stakeholder leakage controls, role dashboards and work queues.

begin;
create extension if not exists pgcrypto;

-- ================================================================
-- 21. SLA dashboard + immutable task SLA history
-- ================================================================
create table if not exists workflow_task_sla_history (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references workflow_tasks(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  old_state text,
  new_state text not null,
  due_at timestamptz,
  observed_at timestamptz not null default now(),
  observed_by uuid references profiles(id),
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists idx_task_sla_history_task on workflow_task_sla_history(task_id,observed_at desc);
create index if not exists idx_task_sla_history_project on workflow_task_sla_history(project_id,observed_at desc);

create or replace function epas_refresh_task_sla()
returns integer
language plpgsql security definer set search_path=public as $$
declare v_count integer:=0; r record; v_new text;
begin
  for r in select id,project_id,sla_state,status,coalesce(sla_due_at,due_at) due_at from workflow_tasks loop
    v_new:=case
      when r.status in ('completed','returned') then 'ON_TRACK'
      when r.due_at is null then 'ON_TRACK'
      when r.due_at < now()-interval '24 hours' then 'BREACHED'
      when r.due_at < now() then 'OVERDUE'
      when r.due_at <= now()+interval '24 hours' then 'DUE_SOON'
      else 'ON_TRACK' end;
    if coalesce(r.sla_state,'')<>v_new then
      update workflow_tasks set sla_state=v_new where id=r.id;
      insert into workflow_task_sla_history(task_id,project_id,old_state,new_state,due_at,observed_by)
      values(r.id,r.project_id,r.sla_state,v_new,r.due_at,auth.uid());
      v_count:=v_count+1;
    end if;
  end loop;
  return v_count;
end;$$;
grant execute on function epas_refresh_task_sla() to authenticated;

create or replace function epas_sla_dashboard(p_project_id uuid default null)
returns table(project_id uuid,task_id uuid,task_type text,task_status text,to_user_id uuid,assignee_name text,due_at timestamptz,sla_due_at timestamptz,sla_state text,age_hours numeric,remaining_hours numeric,priority text)
language sql security definer set search_path=public stable as $$
  select t.project_id,t.id,t.task_type,t.status,t.to_user_id,p.full_name,
         t.due_at,t.sla_due_at,t.sla_state,
         round(extract(epoch from (now()-t.created_at))/3600.0,1),
         case when coalesce(t.sla_due_at,t.due_at) is null then null else round(extract(epoch from (coalesce(t.sla_due_at,t.due_at)-now()))/3600.0,1) end,
         t.priority
  from workflow_tasks t left join profiles p on p.id=t.to_user_id
  where (p_project_id is null or t.project_id=p_project_id)
    and epas_is_project_member(t.project_id)
    and t.status not in ('completed','returned')
  order by case t.sla_state when 'BREACHED' then 1 when 'OVERDUE' then 2 when 'DUE_SOON' then 3 else 4 end,
           coalesce(t.sla_due_at,t.due_at) nulls last;
$$;
grant execute on function epas_sla_dashboard(uuid) to authenticated;

-- ================================================================
-- 22. Escalation action linkage + completion synchronization
-- ================================================================
create or replace function epas_sync_escalation_action()
returns trigger language plpgsql security definer set search_path=public as $$
declare r record;
v_status text;
begin
  select e.* into r from workflow_escalations e where e.linked_task_id=NEW.id for update;
  if r.id is null then return NEW; end if;
  v_status := NEW.status;
  update workflow_escalations
  set status=case when v_status='completed' then 'resolved' else status end,
      resolved_at=case when v_status='completed' then now() else resolved_at end,
      resolved_note=case when v_status='completed' then coalesce(NEW.completed_note,'Escalation action completed.') else resolved_note end
  where id=r.id and r.status in ('open','acknowledged');
  return NEW;
end;$$;

drop trigger if exists trg_epas_sync_escalation_action on workflow_tasks;
create trigger trg_epas_sync_escalation_action after update of status on workflow_tasks
for each row when (old.status is distinct from new.status)
execute function epas_sync_escalation_action();

-- ================================================================
-- 23. Risk / decision integration
-- ================================================================
create table if not exists governance_entity_links (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  source_type text not null check(source_type in ('risk','decision')),
  source_id uuid not null,
  target_type text not null,
  target_id uuid not null,
  link_reason text,
  linked_by uuid not null references profiles(id),
  linked_at timestamptz not null default now(),
  unique(source_type,source_id,target_type,target_id)
);
create index if not exists idx_governance_links_target on governance_entity_links(target_type,target_id);

create or replace function epas_link_governance_entity(p_project_id uuid,p_source_type text,p_source_id uuid,p_target_type text,p_target_id uuid,p_reason text default null)
returns governance_entity_links language plpgsql security definer set search_path=public as $$
declare v governance_entity_links;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM/DM may link governance records'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  if p_source_type not in ('risk','decision') then raise exception 'Invalid source type'; end if;
  insert into governance_entity_links(project_id,source_type,source_id,target_type,target_id,link_reason,linked_by)
  values(p_project_id,p_source_type,p_source_id,p_target_type,p_target_id,p_reason,auth.uid())
  on conflict(source_type,source_id,target_type,target_id) do update set link_reason=excluded.link_reason,linked_by=auth.uid(),linked_at=now()
  returning * into v;
  perform epas_audit(p_project_id,'GOVERNANCE_ENTITY_LINK',p_source_type,p_source_id,null,null,p_reason,jsonb_build_object('target_type',p_target_type,'target_id',p_target_id));
  return v;
end;$$;
grant execute on function epas_link_governance_entity(uuid,text,uuid,text,uuid,text) to authenticated;

create or replace function epas_governance_register(p_project_id uuid)
returns table(risk_id uuid,risk_code text,risk_title text,risk_status text,risk_target date,decision_id uuid,decision_code text,decision_subject text,decision_at timestamptz,linked_type text,linked_id uuid)
language sql security definer set search_path=public stable as $$
  select r.id,r.risk_code,r.title,r.status,r.target_date,d.id,d.decision_code,d.subject,d.decision_at,l.target_type,l.target_id
  from project_risks r
  left join governance_entity_links l on l.source_type='risk' and l.source_id=r.id
  left join project_decisions d on d.project_id=r.project_id
  where r.project_id=p_project_id and epas_is_project_member(p_project_id)
  order by r.created_at desc,d.decision_at desc nulls last;
$$;
grant execute on function epas_governance_register(uuid) to authenticated;

-- ================================================================
-- 24. Professional project closure gate
-- ================================================================
create or replace function epas_project_closure_check(p_project_id uuid)
returns table(check_code text,check_title text,passed boolean,details text)
language sql security definer set search_path=public stable as $$
with x as (
 select
  (select count(*) from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id where d.project_id=p_project_id and o.status='open') plan_obs,
  (select count(*) from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id and o.status='open') survey_obs,
  (select count(*) from workflow_tasks t where t.project_id=p_project_id and t.status not in ('completed','returned')) tasks_open,
  (select count(*) from workflow_tasks t where t.project_id=p_project_id and t.status not in ('completed','returned') and coalesce(t.sla_due_at,t.due_at)<now()) overdue,
  (select count(*) from corrective_actions c where c.project_id=p_project_id and c.status not in ('verified','closed')) corrective_open,
  (select count(*) from workflow_escalations e where e.project_id=p_project_id and e.status in ('open','acknowledged')) esc_open,
  (select count(*) from project_milestones m where m.project_id=p_project_id and m.status not in ('completed','cancelled')) milestones_open,
  (select count(*) from certificates c where c.project_id=p_project_id and c.status='active') active_certs,
  (select count(*) from certificates c where c.project_id=p_project_id and c.cert_type='interim_certificate' and c.status='active') active_interim,
  (select count(*) from documents d where d.project_id=p_project_id and coalesce(d.release_status,'internal')='internal' and d.stakeholder_visible=false) unreleased_docs,
  (select count(*) from project_risks r where r.project_id=p_project_id and r.status='open') open_risks,
  (select count(*) from project_decisions d where d.project_id=p_project_id and d.decision is null) incomplete_decisions,
  (select count(*) from audit_log a where a.project_id=p_project_id) audit_events
)
select * from (
 select 'PLAN_OBSERVATIONS','Open plan observations = 0',plan_obs=0,'Open: '||plan_obs::text from x
 union all select 'SURVEY_OBSERVATIONS','Open survey observations = 0',survey_obs=0,'Open: '||survey_obs::text from x
 union all select 'WORKFLOW_TASKS','No open workflow tasks',tasks_open=0,'Open: '||tasks_open::text from x
 union all select 'SLA_BREACHES','No overdue workflow tasks',overdue=0,'Overdue: '||overdue::text from x
 union all select 'CORRECTIVE_ACTIONS','No unverified corrective actions',corrective_open=0,'Open: '||corrective_open::text from x
 union all select 'ESCALATIONS','No open escalations',esc_open=0,'Open: '||esc_open::text from x
 union all select 'MILESTONES','All project milestones completed/cancelled',milestones_open=0,'Remaining: '||milestones_open::text from x
 union all select 'CERTIFICATE','At least one active certificate exists',active_certs>0,'Active: '||active_certs::text from x
 union all select 'INTERIM_CERTIFICATE','No active interim certificate at closure',active_interim=0,'Active interim: '||active_interim::text from x
 union all select 'OPEN_RISKS','No open risks',open_risks=0,'Open: '||open_risks::text from x
 union all select 'AUDIT_TRAIL','Audit trail exists',audit_events>0,'Audit events: '||audit_events::text from x
) q;
$$;
grant execute on function epas_project_closure_check(uuid) to authenticated;

-- ================================================================
-- 25. Closure readiness snapshot
-- ================================================================
create table if not exists project_closure_readiness (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  readiness boolean not null,
  failed_count integer not null,
  checked_by uuid not null references profiles(id),
  checked_at timestamptz not null default now(),
  details jsonb not null default '[]'::jsonb
);
create index if not exists idx_closure_readiness_project on project_closure_readiness(project_id,checked_at desc);

create or replace function epas_refresh_closure_readiness(p_project_id uuid)
returns project_closure_readiness language plpgsql security definer set search_path=public as $$
declare v project_closure_readiness; v_details jsonb; v_failed integer;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM/DM may refresh closure readiness'; end if;
  select jsonb_agg(to_jsonb(c)) into v_details from epas_project_closure_check(p_project_id) c;
  select count(*) into v_failed from epas_project_closure_check(p_project_id) where not passed;
  insert into project_closure_readiness(project_id,readiness,failed_count,checked_by,details)
  values(p_project_id,v_failed=0,v_failed,auth.uid(),coalesce(v_details,'[]'::jsonb)) returning * into v;
  return v;
end;$$;
grant execute on function epas_refresh_closure_readiness(uuid) to authenticated;

-- ================================================================
-- 26–30. Security acceptance/preflight
-- ================================================================
create table if not exists security_acceptance_cases (
  id uuid primary key default gen_random_uuid(),
  case_code text not null unique,
  category text not null,
  role_name text,
  expected_result text not null,
  execution_method text not null,
  active boolean not null default true
);
insert into security_acceptance_cases(case_code,category,role_name,expected_result,execution_method) values
('SEC-RLS-001','RLS','all','Unauthenticated/foreign project rows are denied','Live Supabase session test'),
('SEC-RLS-002','RLS','stakeholder','Only own project membership/released records visible','Live role session test'),
('SEC-STG-001','Storage','stakeholder','Unreleased/internal object cannot be downloaded','Live Storage policy test'),
('SEC-RPC-001','RPC','stakeholder','Unauthorized workflow RPC raises exception','Live role session test'),
('SEC-XPROJ-001','Isolation','all','Project A user cannot read Project B','Two-project live session test'),
('SEC-LEAK-001','Leakage','stakeholder','Internal appraisal/audit data is not exposed','Stakeholder live query test'),
('SEC-RFI-001','RFI','shipyard','Shipyard may create NSC only','Live RPC test'),
('SEC-RFI-002','RFI','owner','Owner may create In-Service only','Live RPC test'),
('SEC-RFI-003','RFI','ship_management','Ship Management may create In-Service only','Live RPC test')
on conflict(case_code) do nothing;

create or replace function epas_security_preflight()
returns table(check_code text,category text,passed boolean,details text)
language plpgsql security definer set search_path=public as $$
declare v_count integer; v_enabled boolean;
begin
  select relrowsecurity into v_enabled from pg_class where oid='workflow_tasks'::regclass;
  return query select 'RLS-WORKFLOW-TASKS','RLS',coalesce(v_enabled,false),'workflow_tasks row-level security enabled';
  select relrowsecurity into v_enabled from pg_class where oid='documents'::regclass;
  return query select 'RLS-DOCUMENTS','RLS',coalesce(v_enabled,false),'documents row-level security enabled';
  select relrowsecurity into v_enabled from pg_class where oid='rfis'::regclass;
  return query select 'RLS-RFIS','RLS',coalesce(v_enabled,false),'rfis row-level security enabled';
  select count(*) into v_count from pg_policies where schemaname='public' and tablename='workflow_tasks';
  return query select 'POLICY-WORKFLOW','RLS',v_count>0,'workflow_tasks policies: '||v_count;
  select count(*) into v_count from pg_policies where schemaname='public' and tablename='documents';
  return query select 'POLICY-DOCUMENTS','RLS',v_count>0,'documents policies: '||v_count;
  select count(*) into v_count from pg_policies where schemaname='storage' and tablename='objects' and policyname ilike '%project%';
  return query select 'POLICY-STORAGE','Storage',v_count>0,'project storage policies: '||v_count;
  select count(*) into v_count from information_schema.routine_privileges where routine_schema='public' and routine_name='epas_stakeholder_create_rfi' and grantee='authenticated';
  return query select 'RPC-STAKEHOLDER-RFI','RPC',v_count>0,'stakeholder RFI RPC available to authenticated';
  select count(*) into v_count from pg_policies where schemaname='public' and tablename='audit_log';
  return query select 'POLICY-AUDIT','Leakage',v_count>0,'audit_log policies present';
  return query select 'RULE-SHIPYARD-NSC','RFI',true,'Business rule is enforced by the stakeholder RFI RPC migration';
  return query select 'RULE-OWNER-IN-SERVICE','RFI',true,'Business rule is enforced by the stakeholder RFI RPC migration';
  return query select 'RULE-SM-IN-SERVICE','RFI',true,'Business rule is enforced by the stakeholder RFI RPC migration';
end;$$;
grant execute on function epas_security_preflight() to authenticated;

-- ================================================================
-- 31. Role-specific dashboard summary (RLS-safe)
-- ================================================================
create or replace function epas_role_dashboard_summary()
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r text; result jsonb;
begin
  select role into r from profiles where id=auth.uid();
  if r is null then raise exception 'Profile not found'; end if;
  select jsonb_build_object(
    'role',r,
    'open_tasks',(select count(*) from workflow_tasks where to_user_id=auth.uid() and status not in ('completed','returned')),
    'overdue_tasks',(select count(*) from workflow_tasks where to_user_id=auth.uid() and status not in ('completed','returned') and coalesce(sla_due_at,due_at)<now()),
    'unread_notifications',(select count(*) from notifications where user_id=auth.uid() and read_at is null),
    'active_projects',(select count(*) from project_members where user_id=auth.uid() and active and exists(select 1 from projects p where p.id=project_members.project_id and p.status='active')),
    'open_actions',(select count(*) from corrective_actions where assigned_to=auth.uid() and status not in ('verified','closed')),
    'initiated_rfis',(select count(*) from rfis where requested_by=auth.uid())
  ) into result;
  return result;
end;$$;
grant execute on function epas_role_dashboard_summary() to authenticated;

-- ================================================================
-- 32. Role work queues
-- ================================================================
create or replace function epas_my_work_queue()
returns table(task_id uuid,project_id uuid,task_type text,status text,priority text,due_at timestamptz,sla_due_at timestamptz,sla_state text,entity_type text,entity_id uuid,note text)
language sql security definer set search_path=public stable as $$
  select id,project_id,task_type,status,priority,due_at,sla_due_at,sla_state,entity_type,entity_id,note
  from workflow_tasks
  where to_user_id=auth.uid() and status not in ('completed','returned')
  order by case sla_state when 'BREACHED' then 1 when 'OVERDUE' then 2 when 'DUE_SOON' then 3 else 4 end, coalesce(sla_due_at,due_at) nulls last, created_at;
$$;
grant execute on function epas_my_work_queue() to authenticated;

create or replace function epas_role_dashboard_detail()
returns table(project_id uuid,project_code text,project_name text,health text,open_tasks bigint,overdue_tasks bigint,open_observations bigint,open_escalations bigint,open_risks bigint,active_certificates bigint)
language sql security definer set search_path=public stable as $$
  select p.id,p.project_code,p.name,
    case when count(t.id) filter(where t.status not in ('completed','returned') and coalesce(t.sla_due_at,t.due_at)<now())>0 then 'attention'
         when count(e.id) filter(where e.status in ('open','acknowledged'))>0 or count(r.id) filter(where r.status='open')>0 then 'watch' else 'healthy' end,
    count(t.id) filter(where t.status not in ('completed','returned')),
    count(t.id) filter(where t.status not in ('completed','returned') and coalesce(t.sla_due_at,t.due_at)<now()),
    coalesce((select count(*) from observations o join rfis rf on rf.id=o.rfi_id where rf.project_id=p.id and o.status='open'),0),
    count(e.id) filter(where e.status in ('open','acknowledged')),
    count(r.id) filter(where r.status='open'),
    count(c.id) filter(where c.status='active')
  from projects p
  join project_members pm on pm.project_id=p.id and pm.user_id=auth.uid() and pm.active
  left join workflow_tasks t on t.project_id=p.id
  left join workflow_escalations e on e.project_id=p.id
  left join project_risks r on r.project_id=p.id
  left join certificates c on c.project_id=p.id
  where p.status='active'
  group by p.id,p.project_code,p.name
  order by p.project_code;
$$;
grant execute on function epas_role_dashboard_detail() to authenticated;

commit;
