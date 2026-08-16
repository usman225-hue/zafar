
-- EPAS v1.5.1 Critical Gap Closure
-- Applies after production_v1_5.sql and production_v1_4_1.sql.
-- Focus:
--   * eliminate legacy permissive SELECT/INSERT/UPDATE/DELETE policies
--   * strict internal vs external stakeholder data boundaries
--   * stakeholder document/milestone release control
--   * protected SECDEF read endpoints
--   * old overloaded RPC execution revoked
--   * stronger SLA/resource conflict calculations
--   * controlled certificate PDF access
--   * audit of stakeholder document/certificate access

begin;

-- ================================================================
-- 1. Role classification helpers
-- ================================================================
create or replace function epas_is_internal_role(p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from profiles p
    where p.id=p_user_id
      and p.role in ('gm','dm','engineer','surveyor')
  );
$$;

create or replace function epas_is_stakeholder_role(p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from profiles p
    where p.id=p_user_id
      and p.role in ('designer','ship_management','owner','shipyard')
  );
$$;

-- ================================================================
-- 2. Stakeholder-visible milestone release
-- ================================================================
alter table project_milestones
  add column if not exists stakeholder_visible boolean not null default false;
alter table project_milestones add column if not exists released_by uuid references profiles(id);
alter table project_milestones add column if not exists released_at timestamptz;
alter table project_milestones add column if not exists release_note text;

create or replace function epas_release_milestone(
  p_milestone_id uuid, p_note text default null
)
returns project_milestones
language plpgsql security definer set search_path=public
as $$
declare v project_milestones;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then
    raise exception 'Only GM or DM may release milestones';
  end if;

  select * into v from project_milestones where id=p_milestone_id for update;
  if v.id is null then raise exception 'Milestone not found'; end if;
  if not epas_is_project_member(v.project_id) then raise exception 'Not authorized for project'; end if;

  update project_milestones
     set stakeholder_visible=true,
         released_by=auth.uid(),
         released_at=now(),
         release_note=coalesce(nullif(trim(p_note),''),'Released for stakeholder viewing.')
   where id=v.id
   returning * into v;

  perform epas_audit(
    v.project_id,'MILESTONE_RELEASED','milestone',v.id,
    'internal','released',p_note,
    jsonb_build_object('stakeholder_visible',true)
  );

  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  select pm.user_id,'Milestone released',
         coalesce(v.code,'Milestone')||' is now visible in the stakeholder project workspace.',
         v.project_id,'project','milestone_release','info','milestone',v.id
  from project_members pm
  where pm.project_id=v.project_id and pm.active
    and pm.role in ('designer','owner','ship_management','shipyard');

  insert into notification_outbox(project_id,recipient_email,subject,body)
  select v.project_id,p.email,'EPAS milestone released',
         coalesce(v.code,'Milestone')||' is now visible in the stakeholder project workspace.'
  from project_members pm join profiles p on p.id=pm.user_id
  where pm.project_id=v.project_id and pm.active
    and pm.role in ('designer','owner','ship_management','shipyard')
    and coalesce(p.email,'')<>'';

  return v;
end;
$$;
grant execute on function epas_release_milestone(uuid,text) to authenticated;

-- ================================================================
-- 3. Remove ALL legacy SELECT policies that can OR together
--    and rebuild strict policies.
-- ================================================================

-- Documents: internal project members may view internal records;
-- external stakeholders may view only released records; Designer and
-- Ship Management may also see their own submitted controlled documents.
drop policy if exists documents_select_prod on documents;
drop policy if exists documents_select_v14 on documents;
drop policy if exists documents_select_v15 on documents;
create policy documents_select_v15 on documents
for select to authenticated
using (
  (
    epas_is_internal_role()
    and epas_is_project_member(project_id)
  )
  or
  (
    exists(
      select 1 from profiles p
      where p.id=auth.uid() and p.role in ('owner','shipyard')
    )
    and stakeholder_visible=true and release_status='released'
    and epas_is_project_member(project_id)
  )
  or
  (
    exists(
      select 1 from profiles p
      where p.id=auth.uid() and p.role in ('designer','ship_management')
    )
    and epas_is_project_member(project_id)
    and (
      (stakeholder_visible=true and release_status='released')
      or uploaded_by=auth.uid()
    )
  )
);

-- Projects: all authenticated stakeholders can see ONLY their own linked
-- project row; internal users see authorized project rows.
drop policy if exists gm_full_access_projects on projects;
drop policy if exists projects_select_prod on projects;
drop policy if exists projects_select_v14 on projects;
drop policy if exists projects_select_v15 on projects;
create policy projects_select_v15 on projects
for select to authenticated
using (
  (epas_is_internal_role() and epas_is_project_member(id))
  or
  (epas_is_stakeholder_role() and epas_is_project_member(id))
);

-- Milestones: internal users see all linked milestones; stakeholders only
-- see milestones explicitly released.
drop policy if exists milestone_select on project_milestones;
drop policy if exists milestone_select_v14 on project_milestones;
drop policy if exists milestone_select_v15 on project_milestones;
create policy milestone_select_v15 on project_milestones
for select to authenticated
using (
  (epas_is_internal_role() and epas_is_project_member(project_id))
  or
  (epas_is_stakeholder_role() and epas_is_project_member(project_id) and stakeholder_visible=true)
);

-- RFIs / internal survey workflow: stakeholders do not get direct RFI access.
drop policy if exists gm_full_access_rfis on rfis;
drop policy if exists rfis_select_prod on rfis;
drop policy if exists rfis_select_v14 on rfis;
drop policy if exists rfis_select_v15 on rfis;
create policy rfis_select_v15 on rfis
for select to authenticated
using (
  epas_is_internal_role() and epas_is_project_member(project_id)
);

-- Survey observations are internal classification records.
drop policy if exists observations_select_prod on observations;
drop policy if exists observations_select_v14 on observations;
drop policy if exists observations_select_v15 on observations;
create policy observations_select_v15 on observations
for select to authenticated
using (
  epas_is_internal_role()
  and exists(
    select 1 from rfis r
    where r.id=observations.rfi_id
      and epas_is_project_member(r.project_id)
  )
);

-- Plan observations are internal.
drop policy if exists plan_obs_select_prod on plan_appraisal_observations;
drop policy if exists plan_obs_select_v14 on plan_appraisal_observations;
drop policy if exists plan_obs_select_v15 on plan_appraisal_observations;
create policy plan_obs_select_v15 on plan_appraisal_observations
for select to authenticated
using (
  epas_is_internal_role()
  and exists(
    select 1 from plan_drawings d
    where d.id=plan_appraisal_observations.drawing_id
      and epas_is_project_member(d.project_id)
  )
);

-- Workflow events/audit are internal management records.
drop policy if exists workflow_events_select_prod on workflow_events;
drop policy if exists workflow_events_select_v14 on workflow_events;
drop policy if exists workflow_events_select_v15 on workflow_events;
create policy workflow_events_select_v15 on workflow_events
for select to authenticated
using (
  epas_is_internal_role()
  and epas_is_project_member(project_id)
);

drop policy if exists audit_log_select_v14 on audit_log;
drop policy if exists audit_log_select_v15 on audit_log;
create policy audit_log_select_v15 on audit_log
for select to authenticated
using (
  epas_has_role('gm')
  or (epas_has_role('dm') and epas_is_project_member(project_id))
);

-- Risks / decisions / escalations are internal governance records.
drop policy if exists escalation_select on workflow_escalations;
drop policy if exists escalation_select_v14 on workflow_escalations;
drop policy if exists escalation_select_v15 on workflow_escalations;
create policy escalation_select_v15 on workflow_escalations
for select to authenticated
using (
  (epas_has_role('gm') or epas_has_role('dm'))
  and epas_is_project_member(project_id)
);

drop policy if exists project_risks_select_v14 on project_risks;
drop policy if exists project_risks_select_v15 on project_risks;
create policy project_risks_select_v15 on project_risks
for select to authenticated
using (
  (epas_has_role('gm') or epas_has_role('dm'))
  and epas_is_project_member(project_id)
);

drop policy if exists project_decisions_select_v14 on project_decisions;
drop policy if exists project_decisions_select_v15 on project_decisions;
create policy project_decisions_select_v15 on project_decisions
for select to authenticated
using (
  (epas_has_role('gm') or epas_has_role('dm'))
  and epas_is_project_member(project_id)
);

-- Corrective actions: internal project team can view; external Ship Mgmt can
-- view only corrective actions explicitly assigned to its account.
drop policy if exists corrective_select on corrective_actions;
drop policy if exists corrective_select_v14 on corrective_actions;
drop policy if exists corrective_select_v15 on corrective_actions;
create policy corrective_select_v15 on corrective_actions
for select to authenticated
using (
  (
    epas_is_internal_role()
    and epas_is_project_member(project_id)
  )
  or
  (
    epas_has_role('ship_management')
    and assigned_to=auth.uid()
  )
);

-- Workflow tasks: internal users see project/task scope; external users only
-- see tasks assigned directly to them or tasks they created.
drop policy if exists workflow_tasks_select_prod on workflow_tasks;
drop policy if exists workflow_tasks_select_v14 on workflow_tasks;
drop policy if exists workflow_tasks_select_v15 on workflow_tasks;
create policy workflow_tasks_select_v15 on workflow_tasks
for select to authenticated
using (
  to_user_id=auth.uid()
  or from_user_id=auth.uid()
  or (epas_has_role('gm') and epas_is_project_member(project_id))
  or (epas_has_role('dm') and epas_is_project_member(project_id))
  or (epas_has_role('engineer') and epas_is_project_member(project_id) and to_user_id=auth.uid())
  or (epas_has_role('surveyor') and epas_is_project_member(project_id) and to_user_id=auth.uid())
);

-- Plan drawings: external Designer sees its own drawings and released drawings;
-- internal personnel see project drawings.
drop policy if exists plan_drawings_select_prod on plan_drawings;
drop policy if exists plan_drawings_select_v14 on plan_drawings;
drop policy if exists plan_drawings_select_v15 on plan_drawings;
create policy plan_drawings_select_v15 on plan_drawings
for select to authenticated
using (
  (epas_is_internal_role() and epas_is_project_member(project_id))
  or
  (
    epas_has_role('designer')
    and epas_is_project_member(project_id)
    and (
      designer_id=auth.uid()
      or exists(
        select 1 from documents d
        where d.id=plan_drawings.document_id
          and d.stakeholder_visible=true
          and d.release_status='released'
      )
    )
  )
);

-- Document revisions: internal users see project revisions; Designer sees its
-- own drawing revisions and released/approved revisions.
drop policy if exists revisions_select_v14 on document_revisions;
drop policy if exists revisions_select_v15 on document_revisions;
create policy revisions_select_v15 on document_revisions
for select to authenticated
using (
  exists(
    select 1 from documents d
    where d.id=document_revisions.document_id
      and (
        (epas_is_internal_role() and epas_is_project_member(d.project_id))
        or
        (epas_has_role('designer') and epas_is_project_member(d.project_id)
          and (d.uploaded_by=auth.uid() or d.release_status='released'))
        or
        (epas_has_role('ship_management') and epas_is_project_member(d.project_id)
          and d.release_status='released')
        or
        (epas_has_role('owner') and epas_is_project_member(d.project_id)
          and d.release_status='released')
        or
        (epas_has_role('shipyard') and epas_is_project_member(d.project_id)
          and d.release_status='released')
      )
  )
);

-- Notifications: only owner of the notification row can read/update;
-- creation is RPC/trigger-only.
drop policy if exists notifications_select_prod on notifications;
drop policy if exists notifications_select_v14 on notifications;
drop policy if exists notifications_select_v15 on notifications;
create policy notifications_select_v15 on notifications
for select to authenticated using (user_id=auth.uid());

drop policy if exists notifications_update_prod on notifications;
drop policy if exists notifications_update_v15 on notifications;
create policy notifications_update_v15 on notifications
for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());

-- Certificates: internal users see project certificates; external stakeholders
-- see only final/issued certificates with safe public status.
drop policy if exists gm_full_access_certificates on certificates;
drop policy if exists certificates_select_v14 on certificates;
drop policy if exists certificates_select_v15 on certificates;
create policy certificates_select_v15 on certificates
for select to authenticated
using (
  (epas_is_internal_role() and epas_is_project_member(project_id))
  or
  (epas_is_stakeholder_role()
   and epas_is_project_member(project_id)
   and status in ('active','superseded'))
);

-- Project membership: stakeholders may see only stakeholder identities in their
-- projects plus self; internal users may resolve internal membership.
drop policy if exists project_members_select on project_members;
drop policy if exists project_members_select_v14 on project_members;
drop policy if exists project_members_select_v15 on project_members;
create policy project_members_select_v15 on project_members
for select to authenticated
using (
  user_id=auth.uid()
  or
  (epas_has_role('gm') and epas_is_project_member(project_id))
  or
  (epas_has_role('dm') and epas_is_project_member(project_id))
  or
  (
    epas_is_stakeholder_role()
    and epas_is_project_member(project_id)
    and member_category='stakeholder'
  )
);

-- ================================================================
-- 4. Harden direct mutations: RPC only, including legacy policies.
-- ================================================================
drop policy if exists tasks_insert_actor on workflow_tasks;
drop policy if exists tasks_update_recipient on workflow_tasks;
drop policy if exists tasks_insert_v15 on workflow_tasks;
drop policy if exists tasks_update_v15 on workflow_tasks;
revoke insert,update,delete on workflow_tasks from anon,authenticated;

drop policy if exists notifications_insert_authenticated on notifications;
drop policy if exists notifications_insert_v15 on notifications;
revoke insert,update,delete on notifications from anon,authenticated;

drop policy if exists plan_drawings_insert_designer_v15 on plan_drawings;
drop policy if exists plan_drawings_update_designer_v15 on plan_drawings;
revoke insert,update,delete on plan_drawings from anon,authenticated;

revoke insert,update,delete on plan_appraisal_observations from anon,authenticated;
revoke insert,update,delete on document_revisions from anon,authenticated;

revoke insert,update,delete on document_releases,document_access_audit,notification_outbox,
  certificate_lifecycle_events,project_closure_checks,project_archives,sla_policies from anon,authenticated;

-- Critical business tables are mutation-RPC-only.
revoke insert,update,delete on projects,project_milestones,rfis,observations,certificates,
  corrective_actions,workflow_escalations,project_risks,project_decisions,
  plan_drawings,plan_appraisal_observations,document_revisions,documents
  from anon,authenticated;
drop policy if exists documents_insert_gm on documents;

-- Remove generic/legacy direct notification or task creation grants.
revoke execute on function epas_create_task(uuid,text,uuid,text,text,uuid,timestamptz,text) from public,anon,authenticated;

-- ================================================================
-- 5. External corrective-action RLS and safe certificate lifecycle access
-- ================================================================
drop policy if exists certificate_lifecycle_events_select_v15 on certificate_lifecycle_events;
create policy certificate_lifecycle_events_select_v15 on certificate_lifecycle_events
for select to authenticated
using (
  (epas_is_internal_role() and exists(
      select 1 from certificates c where c.id=certificate_id and epas_is_project_member(c.project_id)
  ))
);

-- External stakeholders should not access governance tables directly.
drop policy if exists document_access_audit_select_v15 on document_access_audit;
create policy document_access_audit_select_v15 on document_access_audit
for select to authenticated
using (
  epas_has_role('gm')
  or (epas_has_role('dm') and epas_is_project_member(project_id))
);

drop policy if exists document_releases_select_v15 on document_releases;
create policy document_releases_select_v15 on document_releases
for select to authenticated
using (
  (
    epas_is_internal_role()
    and epas_is_project_member(project_id)
  )
  or
  (
    epas_is_stakeholder_role()
    and epas_is_project_member(project_id)
    and (
      audience_role='all_stakeholders'
      or exists(
        select 1 from profiles p
        where p.id=auth.uid() and p.role=audience_role
      )
    )
    and status='released'
  )
);

-- ================================================================
-- 6. Safe internal-only read endpoints
-- ================================================================
create or replace function epas_project_eligible_resources_v15(
  p_project_id uuid,p_role text,p_discipline text,
  p_window_start date,p_window_end date
)
returns table(
  user_id uuid,full_name text,email text,role text,discipline text,
  authorization_valid boolean,competency_valid boolean,available boolean,
  workload_pct numeric,capacity_hours numeric,assigned_hours numeric,
  conflict_count integer
)
language plpgsql security definer set search_path=public stable
as $$
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then
    raise exception 'Only GM/DM may evaluate resource eligibility';
  end if;
  if not epas_is_project_member(p_project_id) then
    raise exception 'Not authorized for project';
  end if;

  return query
  select e.user_id,e.full_name,e.email,e.role,e.discipline,
    e.authorization_valid,e.competency_valid,e.available,
    e.workload_pct,e.capacity_hours,e.assigned_hours,e.conflict_count
  from epas_project_eligible_resources_v15_internal(p_project_id,p_role,p_discipline,p_window_start,p_window_end) e;
end;
$$;

-- Internal implementation helper. SECURITY DEFINER but only callable from the
-- guarded public wrapper above; revoke direct EXECUTE below.
-- Uses the existing v1.5 eligibility logic through a view-like function body.
create or replace function epas_project_eligible_resources_v15_internal(
  p_project_id uuid,p_role text,p_discipline text,
  p_window_start date,p_window_end date
)
returns table(
  user_id uuid,full_name text,email text,role text,discipline text,
  authorization_valid boolean,competency_valid boolean,available boolean,
  workload_pct numeric,capacity_hours numeric,assigned_hours numeric,
  conflict_count integer
)
language sql security definer set search_path=public stable
as $$
  with people as (
    select p.id,p.full_name,p.email,p.role,pm.discipline
    from profiles p
    join project_members pm on pm.user_id=p.id
    where pm.project_id=p_project_id
      and pm.active
      and p.role=p_role
      and (p_discipline is null or pm.discipline=p_discipline)
  ),
  cap as (
    select ac.user_id,
           coalesce(sum(ac.capacity_hours),0)::numeric capacity_hours,
           coalesce(avg(ac.workload_pct),0)::numeric avg_workload
    from resource_availability_calendar ac
    where ac.work_date between p_window_start and p_window_end
    group by ac.user_id
  ),
  assigned as (
    select t.to_user_id,
           coalesce(sum(t.estimated_hours) filter(where t.status not in ('completed','returned')),0)::numeric assigned_hours,
           count(*) filter(where t.status not in ('completed','returned')
             and coalesce(t.planned_start_at,t.created_at) <= p_window_end::timestamptz + interval '23 hours'
             and coalesce(t.planned_end_at,t.due_at) >= p_window_start::timestamptz) active_window_tasks
    from workflow_tasks t
    where t.project_id=p_project_id
      and t.status not in ('completed','returned')
    group by t.to_user_id
  ),
  conflicts as (
    select t1.to_user_id,
           count(*)::integer conflict_count
    from workflow_tasks t1
    join workflow_tasks t2
      on t1.to_user_id=t2.to_user_id
     and t1.id<t2.id
     and t1.status not in ('completed','returned')
     and t2.status not in ('completed','returned')
     and coalesce(t1.planned_start_at,t1.created_at) <= coalesce(t2.planned_end_at,t2.due_at)
     and coalesce(t2.planned_start_at,t2.created_at) <= coalesce(t1.planned_end_at,t1.due_at)
    where t1.project_id=p_project_id and t2.project_id=p_project_id
    group by t1.to_user_id
  )
  select pe.id,pe.full_name,pe.email,pe.role,pe.discipline,
    exists(
      select 1 from authorization_matrix a
      where a.user_id=pe.id and a.active
        and a.discipline=pe.discipline
        and a.valid_until>=p_window_end
    ) as authorization_valid,
    exists(
      select 1 from competency_records c
      where c.user_id=pe.id and c.status='competent'
        and c.discipline=pe.discipline
        and c.valid_until>=p_window_end
    ) as competency_valid,
    not exists(
      select 1 from resource_availability_calendar ac
      where ac.user_id=pe.id
        and ac.work_date between p_window_start and p_window_end
        and coalesce(ac.status,'available') in ('leave','unavailable')
    ) as available,
    coalesce(cap.avg_workload,0),
    coalesce(cap.capacity_hours,0),
    coalesce(assigned.assigned_hours,0),
    coalesce(conflicts.conflict_count,0)
  from people pe
  left join cap on cap.user_id=pe.id
  left join assigned on assigned.to_user_id=pe.id
  left join conflicts on conflicts.to_user_id=pe.id;
$$;
revoke execute on function epas_project_eligible_resources_v15_internal(uuid,text,text,date,date) from authenticated;

-- Guard project health / closure / workload reads.
create or replace function epas_project_health_v15(p_project_id uuid)
returns table(
  project_id uuid,completion_pct numeric,health_status text,
  plan_completion_pct numeric,survey_completion_pct numeric,
  open_tasks integer,overdue_tasks integer,open_escalations integer,
  open_risks integer,plan_open_observations integer,survey_open_observations integer,
  active_certificates integer,closure_ready boolean
)
language plpgsql security definer set search_path=public stable
as $$
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then
    raise exception 'Only GM/DM may view internal project health';
  end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  return query
  select * from epas_project_health_v15_internal(p_project_id);
end;
$$;

create or replace function epas_project_health_v15_internal(p_project_id uuid)
returns table(
  project_id uuid,completion_pct numeric,health_status text,
  plan_completion_pct numeric,survey_completion_pct numeric,
  open_tasks integer,overdue_tasks integer,open_escalations integer,
  open_risks integer,plan_open_observations integer,survey_open_observations integer,
  active_certificates integer,closure_ready boolean
)
language sql security definer set search_path=public stable
as $$
  with d as (
    select count(*) total,count(*) filter(where status='approved') done from plan_drawings where project_id=p_project_id
  ), r as (
    select count(*) total,count(*) filter(where status in ('approved_no_observations','approved_with_observations','certificate_issued','closed')) done from rfis where project_id=p_project_id
  ), t as (
    select count(*) open,count(*) filter(where status not in ('completed','returned') and due_at<now()) overdue from workflow_tasks where project_id=p_project_id
  ), x as (
    select count(*) cnt from workflow_escalations where project_id=p_project_id and status in ('open','acknowledged')
  ), rr as (
    select count(*) cnt from project_risks where project_id=p_project_id and status='open'
  ), po as (
    select count(*) cnt from plan_appraisal_observations o join plan_drawings d2 on d2.id=o.drawing_id where d2.project_id=p_project_id and o.status='open'
  ), so as (
    select count(*) cnt from observations o join rfis r2 on r2.id=o.rfi_id where r2.project_id=p_project_id and o.status='open'
  ), c as (
    select count(*) cnt from certificates where project_id=p_project_id and status='active'
  )
  select p_project_id,
    case when coalesce(d.total,0)+coalesce(r.total,0)=0 then 0 else round(
      100.0*(coalesce(d.done,0)+coalesce(r.done,0)) / nullif(coalesce(d.total,0)+coalesce(r.total,0),0),1) end,
    case when coalesce(t.overdue,0)>0 or coalesce(x.cnt,0)>0 or coalesce(po.cnt,0)+coalesce(so.cnt,0)>5 then 'attention'
         when coalesce(po.cnt,0)+coalesce(so.cnt,0)>0 then 'watch' else 'healthy' end,
    case when coalesce(d.total,0)=0 then 100 else round(100.0*d.done/nullif(d.total,0),1) end,
    case when coalesce(r.total,0)=0 then 100 else round(100.0*r.done/nullif(r.total,0),1) end,
    coalesce(t.open,0),coalesce(t.overdue,0),coalesce(x.cnt,0),coalesce(rr.cnt,0),coalesce(po.cnt,0),coalesce(so.cnt,0),coalesce(c.cnt,0),
    (coalesce(po.cnt,0)=0 and coalesce(so.cnt,0)=0 and coalesce(t.open,0)=0)
  from d,r,t,x,rr,po,so,c;
$$;
revoke execute on function epas_project_health_v15_internal(uuid) from authenticated;

create or replace function epas_project_closure_check(p_project_id uuid)
returns table(check_code text,check_title text,passed boolean,details text)
language plpgsql security definer set search_path=public stable
as $$
begin
  if not epas_has_role('gm') then raise exception 'Only GM may view closure checklist'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  return query select * from epas_project_closure_check_internal(p_project_id);
end;
$$;

create or replace function epas_project_closure_check_internal(p_project_id uuid)
returns table(check_code text,check_title text,passed boolean,details text)
language sql security definer set search_path=public stable
as $$
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
revoke execute on function epas_project_closure_check_internal(uuid) from authenticated;

-- Keep the original resource_workload public function name but make it internal
-- only. The v1.5 SQL already calculates working data; this wrapper is guarded.
drop function if exists epas_resource_workload(uuid);
create or replace function epas_resource_workload(p_project_id uuid)
returns table(
  user_id uuid,full_name text,role text,discipline text,workload_pct numeric,capacity_pct numeric,
  assigned_tasks integer,overdue_tasks integer,due_7d integer,same_due_date_conflicts integer,
  overlapping_tasks integer,availability_status text
)
language plpgsql security definer set search_path=public stable
as $$
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM/DM may view resource workload'; end if;
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project'; end if;
  return query
  select * from epas_resource_workload_internal(p_project_id);
end;
$$;

create or replace function epas_resource_workload_internal(p_project_id uuid)
returns table(
  user_id uuid,full_name text,role text,discipline text,workload_pct numeric,capacity_pct numeric,
  assigned_tasks integer,overdue_tasks integer,due_7d integer,same_due_date_conflicts integer,
  overlapping_tasks integer,availability_status text,capacity_hours numeric,assigned_hours numeric,
  utilization_pct numeric
)
language sql security definer set search_path=public stable as $$
  with base as (
    select pm.user_id,p.full_name,p.role,pm.discipline,
           coalesce(ac.status,'available') availability_status,
           coalesce(ac.capacity_hours,8)::numeric capacity_hours,
           coalesce(ac.workload_pct,0)::numeric calendar_workload
    from project_members pm
    join profiles p on p.id=pm.user_id
    left join resource_availability_calendar ac
      on ac.user_id=pm.user_id and ac.work_date=current_date
    where pm.project_id=p_project_id
      and pm.active
      and pm.role in ('dm','engineer','surveyor')
  ),
  work as (
    select t.to_user_id,
           count(*) filter(where t.status not in ('completed','returned')) assigned_tasks,
           count(*) filter(where t.status not in ('completed','returned') and t.due_at<now()) overdue_tasks,
           count(*) filter(where t.status not in ('completed','returned') and t.due_at between now() and now()+interval '7 days') due_7d,
           coalesce(sum(t.estimated_hours) filter(where t.status not in ('completed','returned')),0)::numeric assigned_hours,
           count(*) filter(where t.status not in ('completed','returned') and t.due_at::date in (
             select x.due_at::date
             from workflow_tasks x
             where x.to_user_id=t.to_user_id
               and x.project_id=p_project_id
               and x.status not in ('completed','returned')
               and x.id<>t.id
           )) same_due_date_conflicts
    from workflow_tasks t
    where t.project_id=p_project_id
    group by t.to_user_id
  ),
  overlaps as (
    select t1.to_user_id,count(*)::integer overlap_pairs
    from workflow_tasks t1
    join workflow_tasks t2
      on t1.to_user_id=t2.to_user_id
     and t1.id<t2.id
     and t1.status not in ('completed','returned')
     and t2.status not in ('completed','returned')
     and coalesce(t1.planned_start_at,t1.created_at) <= coalesce(t2.planned_end_at,t2.due_at)
     and coalesce(t2.planned_start_at,t2.created_at) <= coalesce(t1.planned_end_at,t1.due_at)
    where t1.project_id=p_project_id and t2.project_id=p_project_id
    group by t1.to_user_id
  )
  select b.user_id,b.full_name,b.role,b.discipline,
         greatest(b.calendar_workload,
           case when b.capacity_hours>0 then least(100,round(coalesce(w.assigned_hours,0)/b.capacity_hours*100,1)) else 0 end) workload_pct,
         greatest(0,100-greatest(b.calendar_workload,
           case when b.capacity_hours>0 then least(100,round(coalesce(w.assigned_hours,0)/b.capacity_hours*100,1)) else 0 end)) capacity_pct,
         coalesce(w.assigned_tasks,0),coalesce(w.overdue_tasks,0),coalesce(w.due_7d,0),
         coalesce(w.same_due_date_conflicts,0),coalesce(o.overlap_pairs,0),b.availability_status,
         b.capacity_hours,coalesce(w.assigned_hours,0),
         case when b.capacity_hours>0 then least(999,round(coalesce(w.assigned_hours,0)/b.capacity_hours*100,1)) else 0 end
  from base b
  left join work w on w.to_user_id=b.user_id
  left join overlaps o on o.to_user_id=b.user_id;
$$;
revoke execute on function epas_resource_workload_internal(uuid) from authenticated;

-- Replace guarded wrapper signature so the additional capacity/utilization fields
-- are exposed to the DM assurance dashboard.
drop function if exists epas_resource_workload(uuid);
create or replace function epas_resource_workload(p_project_id uuid)
returns table(
  user_id uuid,full_name text,role text,discipline text,workload_pct numeric,capacity_pct numeric,
  assigned_tasks integer,overdue_tasks integer,due_7d integer,same_due_date_conflicts integer,
  overlapping_tasks integer,availability_status text,capacity_hours numeric,assigned_hours numeric,
  utilization_pct numeric
)
language plpgsql security definer set search_path=public stable as $$
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then
    raise exception 'Only GM/DM may view resource workload';
  end if;
  if not epas_is_project_member(p_project_id) then
    raise exception 'Not authorized for project';
  end if;
  return query select * from epas_resource_workload_internal(p_project_id);
end;
$$;
grant execute on function epas_resource_workload(uuid) to authenticated;

-- ================================================================
-- 7. Controlled certificate PDF access endpoint
-- ================================================================
create or replace function epas_can_access_certificate(p_certificate_id uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1
    from certificates c
    join project_members pm on pm.project_id=c.project_id and pm.user_id=auth.uid() and pm.active
    where c.id=p_certificate_id
      and (
        epas_is_internal_role()
        or (epas_is_stakeholder_role() and c.status in ('active','superseded'))
      )
  );
$$;
grant execute on function epas_can_access_certificate(uuid) to authenticated;

-- ================================================================
-- 8. Revoke outdated overloaded RPCs so legacy client calls cannot bypass
-- the stricter v1.5 signatures.
-- ================================================================
revoke execute on function epas_submit_survey_report(uuid,text,jsonb) from authenticated;
revoke execute on function epas_assignee_submit_corrective(uuid,text) from authenticated;
revoke execute on function epas_designer_submit_revision(uuid,text,text,text) from authenticated;
revoke execute on function epas_designer_submit_initial_drawing(uuid,text,text,text,text,text,text) from authenticated;
revoke execute on function epas_register_project_document(uuid,text,text,text,integer) from authenticated;
revoke execute on function epas_register_certificate_pdf(uuid,text) from authenticated;
revoke execute on function epas_gm_add_risk(uuid,text,text,text,text,text,text,uuid,date) from authenticated;



-- ================================================================
-- 9. Stakeholder-safe certificate access endpoint
-- ================================================================
create or replace function epas_certificate_pdf_path(p_certificate_id uuid)
returns text
language plpgsql security definer set search_path=public stable
as $$
declare v_path text; v_project uuid; v_status text;
begin
  select pdf_storage_path,project_id,status into v_path,v_project,v_status
  from certificates where id=p_certificate_id;
  if v_path is null then raise exception 'Certificate PDF is not available'; end if;
  if not epas_is_project_member(v_project) then raise exception 'Not authorized for certificate'; end if;
  if epas_is_stakeholder_role() and v_status not in ('active','superseded') then
    raise exception 'Certificate is not released to stakeholders';
  end if;
  perform epas_audit(v_project,'CERTIFICATE_VIEW','certificate',p_certificate_id,null,null,'Certificate PDF access',jsonb_build_object('role',(select role from profiles where id=auth.uid())));
  return v_path;
end;
$$;
grant execute on function epas_certificate_pdf_path(uuid) to authenticated;

-- ================================================================
-- 10. Security-definer endpoint grants
-- ================================================================
grant execute on function epas_project_eligible_resources_v15(uuid,text,text,date,date) to authenticated;
grant execute on function epas_project_health_v15(uuid) to authenticated;
grant execute on function epas_project_closure_check(uuid) to authenticated;
grant execute on function epas_resource_workload(uuid) to authenticated;



-- Harden storage read policy for external Designer own submissions.
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
        and (
          (d.stakeholder_visible=true and d.release_status='released')
          or (d.uploaded_by=auth.uid() and (select role from profiles where id=auth.uid())='designer')
        )
        and exists (
          select 1 from project_members pm
          where pm.project_id=d.project_id and pm.user_id=auth.uid() and pm.active
            and pm.role in ('owner','designer','ship_management','shipyard')
        )
    )
  )
);
commit;
