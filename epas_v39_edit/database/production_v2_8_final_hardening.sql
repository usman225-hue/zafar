-- EPAS v2.8 — Final production hardening and workflow-complete lifecycle
-- Cumulative after v2.7.
-- Closes remaining audited gaps: recurring In-Service cycle semantics,
-- exact version/fingerprint acknowledgements, dependency invalidation,
-- secure lifecycle RPCs, schedule basis enforcement, report/certificate
-- evidence freezing, role boundaries, and production scheduler controls.

begin;
create extension if not exists pgcrypto;

-- ================================================================
-- 1. Explicit survey-cycle entity: phase remains active, cycles recur.
-- ================================================================
create table if not exists survey_cycle_instances (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references survey_schedules(id) on delete cascade,
  rfi_id uuid unique references rfis(id) on delete set null,
  project_id uuid not null references projects(id) on delete cascade,
  vessel_id uuid not null references vessels(id) on delete cascade,
  phase text not null check (phase='in_service'),
  cycle_number integer not null,
  status text not null default 'DUE' check (status in ('PLANNED','DUE','RFI_OPEN','IN_PROGRESS','COMPLETED','CANCELLED','BLOCKED')),
  due_date date,
  window_start date,
  window_end date,
  started_at timestamptz,
  completed_at timestamptz,
  source_certificate_id uuid references certificates(id),
  schedule_basis text,
  schedule_basis_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(schedule_id,cycle_number)
);
create index if not exists idx_survey_cycle_instances_vessel on survey_cycle_instances(vessel_id,cycle_number desc);
create index if not exists idx_survey_cycle_instances_status on survey_cycle_instances(project_id,status,due_date);

alter table survey_schedules add column if not exists due_basis_date date;
alter table survey_schedules add column if not exists schedule_basis_snapshot jsonb not null default '{}'::jsonb;
alter table survey_schedules add column if not exists cycle_instance_id uuid references survey_cycle_instances(id);
alter table survey_schedules add column if not exists phase_lifecycle text not null default 'ACTIVE';

-- Never allow a configured recurring schedule with a missing interval or basis.
update survey_schedules
set schedule_config_status='CONFIGURATION_REQUIRED'
where phase='in_service'
  and (survey_interval_months is null or survey_interval_months<=0 or due_basis is null or trim(coalesce(due_basis_reference,''))='');

-- ================================================================
-- 2. Seed one cycle instance per existing active schedule.
-- ================================================================
insert into survey_cycle_instances(schedule_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,rfi_id,source_certificate_id,schedule_basis,schedule_basis_reference)
select s.id,s.project_id,s.vessel_id,'in_service',coalesce(s.cycle_number,1),
       case when s.current_rfi_id is not null then 'RFI_OPEN' when s.status='OVERDUE' then 'DUE' when s.status in ('DUE','DUE_SOON','SCHEDULED') then 'DUE' else 'PLANNED' end,
       s.next_due_date,s.window_start,s.window_end,s.current_rfi_id,s.source_certificate_id,s.due_basis,s.due_basis_reference
from survey_schedules s
where s.phase='in_service' and s.active
  and not exists(select 1 from survey_cycle_instances c where c.schedule_id=s.id and c.cycle_number=coalesce(s.cycle_number,1));

update survey_schedules s
set cycle_instance_id=c.id
from survey_cycle_instances c
where c.schedule_id=s.id and c.cycle_number=s.cycle_number and s.cycle_instance_id is null;

-- ================================================================
-- 3. Package acknowledgement: immutable package fingerprint + scope version.
-- ================================================================
alter table survey_drawing_package_acknowledgements add column if not exists scope_version integer;
alter table survey_drawing_package_acknowledgements add column if not exists acknowledgement_fingerprint text;
alter table survey_drawing_package_acknowledgements add column if not exists ack_status text not null default 'ACTIVE';
alter table survey_drawing_package_acknowledgements add column if not exists invalidated_at timestamptz;
alter table survey_drawing_package_acknowledgements add column if not exists invalidation_reason text;

drop constraint if exists survey_drawing_package_ack_status_check on survey_drawing_package_acknowledgements;
alter table survey_drawing_package_acknowledgements
  add constraint survey_drawing_package_ack_status_check check (ack_status in ('ACTIVE','INVALIDATED','SUPERSEDED'));

update survey_drawing_package_acknowledgements a
set acknowledgement_fingerprint=a.package_fingerprint,
    ack_status=coalesce(a.ack_status,'ACTIVE')
where a.acknowledgement_fingerprint is null;

create or replace function epas_invalidate_survey_package_acknowledgements(p_rfi_id uuid,p_reason text)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  update survey_drawing_package_acknowledgements
  set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason=p_reason
  where rfi_id=p_rfi_id and ack_status='ACTIVE';
  get diagnostics n=row_count;
  return n;
end;$$;

-- ================================================================
-- 4. Scope acknowledgement must bind exact scope fingerprint and invalidate on change.
-- ================================================================
alter table survey_scope_acknowledgements add column if not exists scope_sha256 text;
alter table survey_scope_acknowledgements add column if not exists ack_status text not null default 'ACTIVE';

create or replace function epas_scope_version_sha256(p_rfi_id uuid,p_version integer)
returns text language sql security definer set search_path=public stable as $$
  select encode(digest(coalesce((select scope_text from survey_scope_versions where rfi_id=p_rfi_id and version_no=p_version),''),'sha256'),'hex');
$$;

create or replace function epas_acknowledge_survey_scope_v28(p_rfi_id uuid,p_note text default '')
returns survey_scope_acknowledgements language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_scopes; a survey_scope_acknowledgements; role_name text; fp text;
begin
  role_name:=(select role from profiles where id=auth.uid());
  if role_name<>'surveyor' then raise exception 'Only Surveyor may acknowledge survey scope'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  select * into s from survey_scopes where rfi_id=p_rfi_id for update;
  if r.id is null or s.id is null then raise exception 'Survey scope not found'; end if;
  if r.assigned_surveyor_id<>auth.uid() or not epas_is_project_member(r.project_id) then raise exception 'Survey is not assigned to this Surveyor'; end if;
  fp:=epas_scope_version_sha256(r.id,s.current_version);
  update survey_scope_acknowledgements
  set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason='Superseded by current scope acknowledgement'
  where rfi_id=r.id and acknowledged_by=auth.uid() and ack_status='ACTIVE' and scope_version<>s.current_version;
  insert into survey_scope_acknowledgements(rfi_id,scope_version,acknowledged_by,acknowledged_role,note,scope_sha256)
  values(r.id,s.current_version,auth.uid(),'surveyor',nullif(trim(p_note),''),fp)
  on conflict(rfi_id,scope_version,acknowledged_by) do update set acknowledged_at=now(),note=excluded.note,scope_sha256=excluded.scope_sha256,ack_status='ACTIVE',invalidated_at=null,invalidation_reason=null
  returning * into a;
  update survey_executions set scope_acknowledged_at=a.acknowledged_at,scope_acknowledged_version=a.scope_version,updated_at=now() where rfi_id=r.id and surveyor_id=auth.uid();
  return a;
end;$$;
grant execute on function epas_acknowledge_survey_scope_v28(uuid,text) to authenticated;

-- ================================================================
-- 5. Scope amendments invalidate all dependent artifacts transactionally.
-- ================================================================
create or replace function epas_dm_decide_rfi_scope_amendment(p_amendment_id uuid,p_approve boolean,p_note text)
returns survey_scope_amendments language plpgsql security definer set search_path=public as $$
declare a survey_scope_amendments; r rfis; s survey_scopes; next_ver integer;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide scope amendments'; end if;
  select * into a from survey_scope_amendments where id=p_amendment_id for update;
  if a.id is null then raise exception 'Amendment not found'; end if;
  if a.status<>'PENDING' then raise exception 'Amendment already decided'; end if;
  select * into r from rfis where id=a.rfi_id for update;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may decide this amendment'; end if;
  select * into s from survey_scopes where rfi_id=r.id for update;
  if p_approve then
    next_ver:=coalesce(s.current_version,s.scope_version,1)+1;
    insert into survey_scope_versions(rfi_id,version_no,scope_text,survey_type,phase,created_by,source_amendment_id)
    values(r.id,next_ver,coalesce(nullif(a.proposed_scope,''),s.scope_text),s.survey_type,s.phase,auth.uid(),a.id);
    update survey_scopes set scope_text=coalesce(nullif(a.proposed_scope,''),scope_text),scope_version=next_ver,current_version=next_ver,status='SUBMITTED',amended_at=now(),amended_by=auth.uid(),updated_at=now() where rfi_id=r.id;
    update rfis set scope_note=coalesce(nullif(a.proposed_scope,''),scope_note),updated_at=now() where id=r.id;
    update survey_scope_acknowledgements
      set ack_status='INVALIDATED',invalidated_at=now(),invalidation_reason='Scope amendment approved'
      where rfi_id=r.id and ack_status='ACTIVE';
    perform epas_invalidate_survey_package_acknowledgements(r.id,'Scope amendment approved');
    update survey_checklist_items set status='pending' where rfi_id=r.id;
    update survey_executions
      set basis_frozen_at=null,basis_sha256=null,execution_basis_version=null,
          scope_acknowledged_at=null,scope_acknowledged_version=null,
          drawing_package_ack_version=null,scope_version=next_ver,
          drawing_package_version=null,checklist_version=null,
          updated_at=now()
      where rfi_id=r.id and status in ('NOT_STARTED','IN_PROGRESS');
    insert into survey_scope_change_events(rfi_id,old_version,new_version,invalidated_scope_ack,invalidated_drawing_package,invalidated_checklist,invalidated_execution_basis,changed_by,reason)
    values(r.id,next_ver-1,next_ver,true,true,true,true,auth.uid(),coalesce(p_note,'Scope amendment approved'));
    update survey_scope_amendments set status='APPROVED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  else
    update survey_scope_amendments set status='REJECTED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  end if;
  select * into a from survey_scope_amendments where id=a.id;
  return a;
end;$$;
grant execute on function epas_dm_decide_rfi_scope_amendment(uuid,boolean,text) to authenticated;

-- ================================================================
-- 6. Versioned checklist instance/fingerprint.
-- ================================================================
create table if not exists survey_checklist_instances (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null unique references rfis(id) on delete cascade,
  phase text not null,
  checklist_version integer not null,
  definition_id uuid references survey_checklist_definitions(id),
  definition_sha256 text not null,
  status text not null default 'OPEN' check(status in ('OPEN','COMPLETE','INVALIDATED')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  invalidated_at timestamptz,
  invalidation_reason text
);

create or replace function epas_initialize_survey_checklist_v28(p_rfi_id uuid)
returns survey_checklist_instances language plpgsql security definer set search_path=public as $$
declare r rfis; d survey_checklist_definitions; fp text; x survey_checklist_instances;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not(epas_has_role('gm') or epas_has_role('dm') or (epas_has_role('surveyor') and r.assigned_surveyor_id=auth.uid())) then raise exception 'Not authorized to initialize checklist'; end if;
  select * into d from survey_checklist_definitions where phase=r.phase and active order by checklist_version desc limit 1;
  if d.id is null then raise exception 'No active checklist definition'; end if;
  fp:=epas_survey_checklist_definition_fingerprint(r.phase,d.checklist_version);
  insert into survey_checklist_instances(rfi_id,phase,checklist_version,definition_id,definition_sha256,status)
  values(r.id,r.phase,d.checklist_version,d.id,fp,'OPEN')
  on conflict(rfi_id) do update set phase=excluded.phase,checklist_version=excluded.checklist_version,definition_id=excluded.definition_id,definition_sha256=excluded.definition_sha256,status='OPEN',invalidated_at=null,invalidation_reason=null
  returning * into x;
  perform epas_initialize_survey_checklist(r.id);
  update survey_checklist_items set definition_id=d.id,checklist_version=d.checklist_version where rfi_id=r.id;
  return x;
end;$$;
grant execute on function epas_initialize_survey_checklist_v28(uuid) to authenticated;

create or replace function epas_survey_checklist_ready_v28(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public volatile as $$
declare r rfis; x survey_checklist_instances; pending integer; fp text;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into x from survey_checklist_instances where rfi_id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if x.id is null then return jsonb_build_object('ready',false,'reason','CHECKLIST_INSTANCE_MISSING'); end if;
  fp:=epas_survey_checklist_definition_fingerprint(r.phase,x.checklist_version);
  if fp<>x.definition_sha256 then return jsonb_build_object('ready',false,'reason','CHECKLIST_DEFINITION_CHANGED','fingerprint',fp,'stored',x.definition_sha256); end if;
  select count(*) into pending from survey_checklist_items where rfi_id=r.id and mandatory and status<>'complete';
  if pending>0 then return jsonb_build_object('ready',false,'reason','MANDATORY_ITEMS_PENDING','pending',pending,'version',x.checklist_version,'fingerprint',fp); end if;
  update survey_checklist_instances set status='COMPLETE',completed_at=coalesce(completed_at,now()) where id=x.id and status<>'COMPLETE';
  return jsonb_build_object('ready',true,'version',x.checklist_version,'fingerprint',fp);
end;$$;
grant execute on function epas_survey_checklist_ready_v28(uuid) to authenticated;

-- ================================================================
-- 7. Assignment version and explicit acknowledgement context.
-- ================================================================
alter table survey_assignments add column if not exists assignment_version integer not null default 1;
alter table survey_assignments add column if not exists accepted_by uuid references profiles(id);
alter table survey_assignments add column if not exists acceptance_note text;

create table if not exists survey_assignment_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references survey_assignments(id) on delete cascade,
  assignment_version integer not null,
  surveyor_id uuid not null references profiles(id),
  acknowledged_at timestamptz not null default now(),
  note text,
  assignment_fingerprint text not null,
  unique(assignment_id,assignment_version,surveyor_id)
);

create or replace function epas_assignment_fingerprint(p_assignment_id uuid)
returns text language sql security definer set search_path=public stable as $$
  select encode(digest(coalesce((select surveyor_id::text||'|'||coalesce(scheduled_date::text,'')||'|'||coalesce(assigned_by::text,'')||'|'||assignment_version::text from survey_assignments where id=p_assignment_id),''),'sha256'),'hex');
$$;

create or replace function epas_surveyor_accept_assignment_v28(p_rfi_id uuid,p_note text default '')
returns survey_assignments language plpgsql security definer set search_path=public as $$
declare a survey_assignments; r rfis; fp text;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may accept assignment'; end if;
  select * into a from survey_assignments where rfi_id=p_rfi_id for update;
  select * into r from rfis where id=p_rfi_id for update;
  if a.id is null or r.id is null then raise exception 'Survey assignment not found'; end if;
  if a.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Assignment belongs to another Surveyor'; end if;
  if a.status not in ('ASSIGNED','REASSIGNED') then raise exception 'Assignment is not awaiting acceptance'; end if;
  fp:=epas_assignment_fingerprint(a.id);
  update survey_assignments set status='ACCEPTED',accepted_at=now(),accepted_by=auth.uid(),acceptance_note=nullif(trim(p_note),''),notes=coalesce(p_note,notes) where id=a.id returning * into a;
  insert into survey_assignment_acknowledgements(assignment_id,assignment_version,surveyor_id,note,assignment_fingerprint)
  values(a.id,a.assignment_version,auth.uid(),nullif(trim(p_note),''),fp)
  on conflict(assignment_id,assignment_version,surveyor_id) do update set acknowledged_at=now(),note=excluded.note,assignment_fingerprint=excluded.assignment_fingerprint;
  update survey_executions set assignment_accepted_at=a.accepted_at,assignment_version=a.assignment_version,updated_at=now() where rfi_id=r.id;
  return a;
end;$$;
grant execute on function epas_surveyor_accept_assignment_v28(uuid,text) to authenticated;

-- ================================================================
-- 8. Revision impact decision freezes comparison evidence.
-- ================================================================
alter table survey_drawing_impact_decisions add column if not exists shared_revision integer;
alter table survey_drawing_impact_decisions add column if not exists shared_sha256 text;
alter table survey_drawing_impact_decisions add column if not exists current_revision integer;
alter table survey_drawing_impact_decisions add column if not exists current_sha256 text;
alter table survey_drawing_impact_decisions add column if not exists comparison_sha256 text;

create or replace function epas_dm_decide_drawing_revision_impact(p_package_id uuid,p_impact text,p_note text)
returns survey_drawing_impact_decisions language plpgsql security definer set search_path=public as $$
declare s survey_rfi_drawings; r rfis; d survey_drawing_impact_decisions; current_revision integer; current_sha text; comparison_fp text;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide drawing revision impact'; end if;
  if p_impact not in ('NO_IMPACT','REISSUE_REQUIRED','NOT_APPLICABLE') then raise exception 'Invalid impact decision'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Decision note is required'; end if;
  select * into s from survey_rfi_drawings where id=p_package_id for update;
  if s.id is null then raise exception 'Drawing package not found'; end if;
  select * into r from rfis where id=s.rfi_id;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may decide this package impact'; end if;
  select pd.revision,doc.sha256 into current_revision,current_sha from plan_drawings pd join documents doc on doc.id=pd.document_id where pd.id=s.drawing_id;
  comparison_fp:=encode(digest(coalesce(s.shared_revision::text,'')||'|'||coalesce(s.shared_sha256,'')||'|'||coalesce(current_revision::text,'')||'|'||coalesce(current_sha,''),'sha256'),'hex');
  if s.shared_revision=current_revision and coalesce(s.shared_sha256,'')=coalesce(current_sha,'') and p_impact='REISSUE_REQUIRED' then raise exception 'No revision/hash change exists; REISSUE_REQUIRED is invalid'; end if;
  insert into survey_drawing_impact_decisions(rfi_id,package_id,impact,note,decided_by,shared_revision,shared_sha256,current_revision,current_sha256,comparison_sha256)
  values(r.id,s.id,p_impact,p_note,auth.uid(),s.shared_revision,s.shared_sha256,current_revision,current_sha,comparison_fp)
  on conflict(package_id) do update set impact=excluded.impact,note=excluded.note,decided_by=excluded.decided_by,decided_at=now(),shared_revision=excluded.shared_revision,shared_sha256=excluded.shared_sha256,current_revision=excluded.current_revision,current_sha256=excluded.current_sha256,comparison_sha256=excluded.comparison_sha256
  returning * into d;
  return d;
end;$$;
grant execute on function epas_dm_decide_drawing_revision_impact(uuid,text,text) to authenticated;

-- ================================================================
-- 9. Strong start gate: exact assignment/scope/package/checklist fingerprints and impact.
-- ================================================================
create or replace function epas_survey_start_gate_v28(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r rfis; a survey_assignments; e survey_executions; s survey_scopes; pkgver integer; pkgfp text; checklist jsonb; scope_fp text; assign_ack boolean; scope_ack boolean; package_ack boolean; revision_clear boolean;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into a from survey_assignments where rfi_id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  if r.id is null or e.id is null or a.id is null or s.id is null then raise exception 'Controlled survey execution context is incomplete'; end if;
  pkgver:=coalesce((select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),0);
  pkgfp:=epas_survey_drawing_package_fingerprint(r.id,pkgver);
  scope_fp:=epas_scope_version_sha256(r.id,s.current_version);
  checklist:=epas_survey_checklist_ready_v28(r.id);
  assign_ack:=exists(select 1 from survey_assignment_acknowledgements x where x.assignment_id=a.id and x.assignment_version=a.assignment_version and x.surveyor_id=a.surveyor_id and x.assignment_fingerprint=epas_assignment_fingerprint(a.id));
  scope_ack:=exists(select 1 from survey_scope_acknowledgements x where x.rfi_id=r.id and x.scope_version=s.current_version and x.scope_sha256=scope_fp and x.ack_status='ACTIVE' and x.acknowledged_by=r.assigned_surveyor_id);
  package_ack:=exists(select 1 from survey_drawing_package_acknowledgements x where x.rfi_id=r.id and x.package_version=pkgver and x.package_fingerprint=pkgfp and x.ack_status='ACTIVE' and x.acknowledged_by=r.assigned_surveyor_id);
  revision_clear:=not exists(select 1 from survey_drawing_impact_decisions x join survey_rfi_drawings p on p.id=x.package_id where x.rfi_id=r.id and p.package_state='ACTIVE' and x.impact='REISSUE_REQUIRED');
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
    'revision_clear',revision_clear,
    'ready',a.status in ('ACCEPTED','IN_PROGRESS','COMPLETED') and assign_ack and scope_ack and package_ack and coalesce((checklist->>'ready')::boolean,false) and revision_clear
  );
end;$$;
grant execute on function epas_survey_start_gate_v28(uuid) to authenticated;

-- ================================================================
-- 10. Execution basis/report freeze anchors.
-- ================================================================
alter table survey_execution_basis_versions add column if not exists report_hash text;
alter table survey_executions add column if not exists report_id uuid;
alter table survey_executions add column if not exists report_sha256 text;
alter table survey_executions add column if not exists report_completed_at timestamptz;
alter table survey_reports add column if not exists report_sha256 text;
alter table survey_reports add column if not exists report_completed_at timestamptz;
alter table survey_reports add column if not exists execution_basis_version integer;

-- ================================================================
-- 11. Certificate package must freeze report/declaration hashes and exact execution basis.
-- ================================================================
alter table certificate_decision_packages add column if not exists survey_report_sha256 text;
alter table certificate_decision_packages add column if not exists declaration_sha256 text;
alter table certificate_decision_packages add column if not exists package_state text not null default 'ACTIVE';

drop constraint if exists certificate_decision_packages_state_check on certificate_decision_packages;
alter table certificate_decision_packages add constraint certificate_decision_packages_state_check check(package_state in ('ACTIVE','SUPERSEDED','ISSUED','VOID'));

create or replace function epas_freeze_certificate_decision_package(p_rfi_id uuid,p_decision text)
returns certificate_decision_packages language plpgsql security definer set search_path=public as $$
declare r rfis; p projects; v certificate_decision_packages; ver integer; c uuid; snapshot jsonb; sha text; e survey_executions; sr survey_reports; d survey_execution_declarations; report_sha text; dec_sha text;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may freeze a certificate decision package'; end if;
  if p_decision not in ('APPROVED','INTERIM','RETURNED') then raise exception 'Invalid certificate decision'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null then raise exception 'RFI not found'; end if;
  select * into p from projects where id=r.project_id;
  select * into e from survey_executions where rfi_id=r.id order by created_at desc limit 1;
  select * into sr from survey_reports where rfi_id=r.id order by submitted_at desc limit 1;
  select * into d from survey_execution_declarations where execution_id=e.id;
  if e.id is null or e.basis_frozen_at is null then raise exception 'Survey execution basis must be frozen before certificate decision package'; end if;
  if d.id is null then raise exception 'Surveyor professional declaration is required before certificate decision package'; end if;
  if sr.id is null then raise exception 'Final survey report is required before certificate decision package'; end if;
  report_sha:=coalesce(sr.report_sha256,encode(digest(coalesce(sr.report_note,''),'sha256'),'hex'));
  dec_sha:=encode(digest(coalesce(d.declaration_text,'')||'|'||d.declared_at::text,'sha256'),'hex');
  select coalesce(max(package_version),0)+1 into ver from certificate_decision_packages where rfi_id=r.id;
  update certificate_decision_packages set package_state='SUPERSEDED' where rfi_id=r.id and package_state='ACTIVE';
  select id into c from certificates where rfi_id=r.id order by created_at desc limit 1;
  snapshot:=jsonb_build_object('rfi_id',r.id,'project_id',p.id,'vessel_id',r.vessel_id,'decision',p_decision,
    'survey_execution',(select to_jsonb(x) from survey_executions x where x.id=e.id),
    'execution_basis',(select to_jsonb(x) from survey_execution_basis_versions x where x.execution_id=e.id order by basis_version desc limit 1),
    'survey_report',(select to_jsonb(x) from survey_reports x where x.id=sr.id),
    'survey_report_sha256',report_sha,
    'declaration',(select to_jsonb(x) from survey_execution_declarations x where x.id=d.id),
    'declaration_sha256',dec_sha,
    'observations',(select coalesce(jsonb_agg(to_jsonb(o)),'[]'::jsonb) from observations o where o.rfi_id=r.id),
    'corrective_actions',(select coalesce(jsonb_agg(to_jsonb(ca)),'[]'::jsonb) from corrective_actions ca where ca.rfi_id=r.id),
    'drawing_package',(select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from survey_rfi_drawings s where s.rfi_id=r.id and s.revoked_at is null),
    'scope_version',(select current_version from survey_scopes where rfi_id=r.id),
    'gm_decision',(select coalesce(to_jsonb(g),'{}'::jsonb) from gm_decisions g where g.rfi_id=r.id order by decided_at desc limit 1));
  sha:=encode(digest(snapshot::text,'sha256'),'hex');
  insert into certificate_decision_packages(certificate_id,rfi_id,project_id,vessel_id,package_version,decision,frozen_by,survey_snapshot,observation_snapshot,corrective_action_snapshot,drawing_package_snapshot,gm_decision_snapshot,dm_ack_snapshot,package_sha256,scope_version,execution_basis_version,execution_basis_sha256,survey_report_sha256,declaration_sha256,package_state)
  values(c,r.id,p.id,r.vessel_id,ver,p_decision,auth.uid(),snapshot->'survey_execution',snapshot->'observations',snapshot->'corrective_actions',snapshot->'drawing_package',snapshot->'gm_decision','{}'::jsonb,sha,(snapshot->>'scope_version')::integer,(snapshot->'execution_basis'->>'basis_version')::integer,(snapshot->'execution_basis'->>'basis_sha256'),report_sha,dec_sha,'ACTIVE')
  returning * into v;
  return v;
end;$$;
grant execute on function epas_freeze_certificate_decision_package(uuid,text) to authenticated;

-- Exact package/ack gate; old ACKs can never satisfy a newer package.
create or replace function epas_certificate_issuance_gate(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare p certificate_decision_packages; r rfis; open_obs integer; dm_ack boolean; gate boolean; latest_ack certificate_decision_acknowledgements;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not (epas_has_role('gm') or epas_is_project_member(r.project_id)) then raise exception 'Not authorized for certificate gate'; end if;
  select count(*) into open_obs from observations where rfi_id=r.id and status='open';
  select * into p from certificate_decision_packages where rfi_id=r.id and package_state='ACTIVE' order by package_version desc limit 1;
  select * into latest_ack from certificate_decision_acknowledgements where package_id=p.id order by acknowledged_at desc limit 1;
  dm_ack:=latest_ack.id is not null and latest_ack.package_version=p.package_version and latest_ack.package_sha256=p.package_sha256;
  gate:=p.id is not null and p.package_sha256 is not null and dm_ack and r.status in ('approved_no_observations','approved_with_observations')
    and ((open_obs=0 and p_cert_type<>'interim_certificate' and p.decision='APPROVED') or (open_obs>0 and p_cert_type='interim_certificate' and p.decision='INTERIM'));
  return jsonb_build_object('gate_passed',gate,'decision_package_id',p.id,'package_version',p.package_version,'package_sha256',p.package_sha256,'dm_acknowledged',dm_ack,'open_observations',open_obs,'certificate_type',p_cert_type,'survey_report_sha256',p.survey_report_sha256,'declaration_sha256',p.declaration_sha256);
end;$$;
grant execute on function epas_certificate_issuance_gate(uuid,text) to authenticated;

-- ================================================================
-- 12. Evidence authorization: surveyor restricted to exact survey observation.
-- ================================================================
create or replace function epas_register_observation_evidence(
  p_observation_id uuid,p_corrective_action_id uuid,p_file_name text,p_storage_path text,
  p_sha256 text,p_mime_type text,p_size_bytes bigint,p_evidence_type text default 'CORRECTIVE_EVIDENCE'
) returns observation_evidence language plpgsql security definer set search_path=public as $$
declare o observations; ca corrective_actions; r rfis; e observation_evidence; role_name text;
begin
  select * into o from observations where id=p_observation_id for update;
  if o.id is null then raise exception 'Observation not found'; end if;
  select * into r from rfis where id=o.rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=(select role from profiles where id=auth.uid());
  if role_name not in ('ship_management','surveyor','dm') then raise exception 'Role cannot submit observation evidence'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not an active project member'; end if;
  if p_corrective_action_id is null then raise exception 'Evidence must be bound to an exact corrective action'; end if;
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
grant execute on function epas_register_observation_evidence(uuid,uuid,text,text,text,text,bigint,text) to authenticated;

-- ================================================================
-- 13. Persistent In-Service phase + explicit recurring cycle creation.
-- ================================================================
alter function epas_phase_gate_status(uuid,text) rename to epas_phase_gate_status_v27_original;

create or replace function epas_phase_gate_status(p_project_id uuid,p_phase text)
returns table(status text,gate_passed boolean,note text)
language plpgsql security definer set search_path=public stable as $$
declare phases text[]; plan_ok boolean:=true; nsc_ok boolean:=true; in_open integer:=0; in_done integer:=0; in_any boolean:=false;
begin
  select p.phases into phases from projects p where p.id=p_project_id;
  if phases is null then raise exception 'Project not found'; end if;
  if p_phase='in_service' then
    if not ('in_service'=any(phases)) then return query select 'NOT_APPLICABLE',false,'In-Service not selected'; return; end if;
    if 'nsc_survey'=any(phases) then
      select status='COMPLETED' into nsc_ok from project_phase_control where project_id=p_project_id and phase='nsc_survey';
      if not coalesce(nsc_ok,false) then return query select 'LOCKED',false,'In-Service is locked until NSC completes'; return; end if;
    elsif 'plan_appraisal'=any(phases) then
      select status='COMPLETED' into plan_ok from project_phase_control where project_id=p_project_id and phase='plan_appraisal';
      if not coalesce(plan_ok,false) then return query select 'LOCKED',false,'In-Service is locked until Plan Appraisal completes'; return; end if;
    end if;
    select count(*) into in_open from rfis where project_id=p_project_id and phase='in_service' and status not in ('certificate_issued','closed');
    select count(*) into in_done from rfis where project_id=p_project_id and phase='in_service' and status in ('certificate_issued','closed');
    in_any := in_open+in_done>0;
    if in_open>0 then return query select 'IN_PROGRESS',true,format('An In-Service cycle is open; %s completed cycles retained in history',in_done); return; end if;
    if in_any then return query select 'IN_PROGRESS',true,format('In-Service remains ACTIVE; %s completed cycle(s), next cycle governed by the survey schedule',in_done); return; end if;
    return query select 'READY',true,'In-Service phase is ACTIVE and waiting for Owner / Ship Management RFI'; return;
  end if;
  return query select * from epas_phase_gate_status_v27_original(p_project_id,p_phase);
end;$$;
-- Alias the pre-v2.8 implementation once, so non-In-Service phases preserve prior behavior.

-- ================================================================
-- 14. Secure lifecycle helpers: service role for autonomous state changes,
-- project-scoped GM/DM for explicit human actions only.
-- ================================================================
revoke all on function epas_refresh_vessel_survey_status_v27(uuid) from authenticated;
grant execute on function epas_refresh_vessel_survey_status_v27(uuid) to service_role;

create or replace function epas_refresh_vessel_status_as_manager_v28(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  if not epas_is_project_member(v.project_id) then raise exception 'Not authorized for vessel'; end if;
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM/DM may refresh vessel status manually'; end if;
  return epas_refresh_vessel_survey_status_v27(p_vessel_id);
end;$$;
grant execute on function epas_refresh_vessel_status_as_manager_v28(uuid) to authenticated;

create or replace function epas_mark_in_service_cycle_complete_v28(p_rfi_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_schedules; e survey_executions; base_date date; due date; cycle_id uuid;
begin
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null or r.phase<>'in_service' then raise exception 'RFI is not an In-Service survey'; end if;
  if not(epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only project GM/DM may complete an In-Service cycle'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not authorized for project'; end if;
  select * into e from survey_executions where rfi_id=r.id;
  if e.id is null or e.status not in ('REPORT_SUBMITTED','DM_REVIEW','GM_REVIEW','COMPLETED') then raise exception 'Survey execution is not complete'; end if;
  select * into s from survey_schedules where vessel_id=r.vessel_id and phase='in_service' and active for update;
  if s.id is null then raise exception 'Active In-Service schedule not found'; end if;
  if s.schedule_config_status<>'CONFIGURED' or s.survey_interval_months is null then raise exception 'Configure explicit schedule basis before completing cycle'; end if;
  base_date:=coalesce((e.completed_at at time zone 'UTC')::date,(select max(coalesce(completed_at,submitted_at))::date from survey_reports where rfi_id=r.id),current_date);
  due:=(base_date+make_interval(months=>s.survey_interval_months))::date;
  update survey_schedules set last_completed_date=base_date,last_survey_completed_at=coalesce(last_survey_completed_at,now()),due_basis_date=base_date,next_due_date=due,window_start=(due-due_window_days_before)::date,window_end=(due+window_days_after)::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=r.id,cycle_completed_at=now(),cycle_number=cycle_number+1,lifecycle_state='ACTIVE',phase_lifecycle='ACTIVE',intent_action='CREATE_IN_SERVICE_RFI',updated_at=now() where id=s.id returning * into s;
  insert into survey_cycle_instances(schedule_id,rfi_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,source_certificate_id,schedule_basis,schedule_basis_reference,completed_at)
  values(s.id,null,r.project_id,r.vessel_id,'in_service',s.cycle_number,'DUE',s.next_due_date,s.window_start,s.window_end,s.source_certificate_id,s.due_basis,s.due_basis_reference,null)
  on conflict(schedule_id,cycle_number) do update set status='DUE',due_date=excluded.due_date,window_start=excluded.window_start,window_end=excluded.window_end,updated_at=now() returning id into cycle_id;
  update survey_cycle_instances set status='COMPLETED',completed_at=now() where schedule_id=s.id and rfi_id=r.id;
  update survey_schedules set cycle_instance_id=cycle_id where id=s.id;
  perform epas_refresh_project_phase_state(r.project_id);
  perform epas_audit(r.project_id,'IN_SERVICE_CYCLE_COMPLETED','rfi',r.id,'dm','COMPLETED','In-Service cycle completed; persistent phase remains active',jsonb_build_object('schedule_id',s.id,'completed_cycle',s.cycle_number-1,'next_cycle',s.cycle_number,'next_due_date',s.next_due_date));
  return s;
end;$$;
grant execute on function epas_mark_in_service_cycle_complete_v28(uuid) to authenticated;

-- ================================================================
-- 15. Secure guided RFI creation: persistent phase accepts IN_PROGRESS.
-- ================================================================
create or replace function epas_stakeholder_create_scheduled_in_service_rfi(
  p_schedule_id uuid,p_survey_type text,p_requested_date date,p_priority text,p_scope_note text
) returns rfis language plpgsql security definer set search_path=public as $$
declare s survey_schedules; v_role text; r rfis; code text; gate text;
begin
  select * into s from survey_schedules where id=p_schedule_id and active for update;
  if s.id is null then raise exception 'Survey schedule not found'; end if;
  v_role:=(select role from profiles where id=auth.uid());
  if v_role not in ('owner','ship_management') then raise exception 'Only Owner or Ship Management may initiate In-Service RFI'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=auth.uid() and pm.active and pm.role=v_role) then raise exception 'Not an active stakeholder member of this project'; end if;
  if s.phase<>'in_service' then raise exception 'Schedule is not In-Service'; end if;
  if s.schedule_config_status<>'CONFIGURED' or s.survey_interval_months is null or s.due_basis is null or trim(coalesce(s.due_basis_reference,''))='' then raise exception 'Schedule configuration is incomplete'; end if;
  if s.status not in ('DUE_SOON','DUE','OVERDUE','SCHEDULED') then raise exception 'Survey cycle is not currently eligible for initiation: %',s.status; end if;
  select status into gate from project_phase_control where project_id=s.project_id and phase='in_service';
  if coalesce(gate,'LOCKED') not in ('READY','IN_PROGRESS') then raise exception 'Persistent In-Service phase is not currently open'; end if;
  if s.current_rfi_id is not null and exists(select 1 from rfis x where x.id=s.current_rfi_id and x.status not in ('certificate_issued','closed')) then raise exception 'An In-Service RFI is already open for the current cycle'; end if;
  if coalesce(trim(p_scope_note),'')='' then raise exception 'Survey scope is required'; end if;
  code:='RFI-SCH-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(s.project_id,s.vessel_id,'in_service',p_survey_type,code,'pending_allocation',auth.uid(),coalesce(p_requested_date,current_date),p_priority,p_scope_note,v_role)
  returning * into r;
  insert into survey_scopes(rfi_id,scope_text,survey_type,phase,status,current_version)
  values(r.id,p_scope_note,p_survey_type,'in_service','SUBMITTED',1);
  update survey_schedules set current_rfi_id=r.id,source_rfi_id=r.id,status='RFI_OPEN',current_cycle_started_at=now(),intent_action='RFI_OPEN',updated_at=now() where id=s.id;
  update survey_cycle_instances set rfi_id=r.id,status='RFI_OPEN',updated_at=now() where id=s.cycle_instance_id;
  if not found then
    insert into survey_cycle_instances(schedule_id,rfi_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,source_certificate_id,schedule_basis,schedule_basis_reference)
    values(s.id,r.id,s.project_id,s.vessel_id,'in_service',s.cycle_number,'RFI_OPEN',s.next_due_date,s.window_start,s.window_end,s.source_certificate_id,s.due_basis,s.due_basis_reference);
  end if;
  perform epas_audit(r.project_id,'IN_SERVICE_RFI_INITIATED_FROM_SCHEDULE','rfi',r.id,v_role,'pending_allocation','Guided In-Service RFI created for recurring cycle',jsonb_build_object('schedule_id',s.id,'cycle_number',s.cycle_number,'next_due_date',s.next_due_date));
  return r;
end;$$;
grant execute on function epas_stakeholder_create_scheduled_in_service_rfi(uuid,text,date,text,text) to authenticated;

-- ================================================================
-- 16. Explicit schedule-basis date and audit history.
-- ================================================================
alter table survey_schedule_basis_history add column if not exists old_basis_date date;
alter table survey_schedule_basis_history add column if not exists new_basis_date date;
alter table survey_schedules add column if not exists due_basis_date date;
alter table survey_schedules add column if not exists schedule_basis_snapshot jsonb not null default '{}'::jsonb;

create or replace function epas_set_in_service_schedule_basis_v28(
  p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_basis_date date,
  p_window_days_before integer,p_window_days_after integer default 30,p_basis_document_id uuid default null
) returns survey_schedules language plpgsql security definer set search_path=public as $$
declare s survey_schedules; old survey_schedules; v_project_id uuid; fp text; basis_date date; due_date date;
begin
  select project_id into v_project_id from vessels where id=p_vessel_id;
  if v_project_id is null then raise exception 'Vessel not found'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Only project GM or DM may configure the In-Service schedule'; end if;
  if p_interval_months is null or p_interval_months<=0 then raise exception 'Schedule interval must be explicitly configured and positive'; end if;
  if p_due_basis not in ('CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED') then raise exception 'Invalid schedule basis'; end if;
  if coalesce(trim(p_basis_reference),'')='' then raise exception 'Schedule basis reference is mandatory'; end if;
  if p_basis_date is null then raise exception 'Basis date is mandatory'; end if;
  select * into old from survey_schedules where vessel_id=p_vessel_id and phase='in_service' and active for update;
  if old.id is null then raise exception 'Active In-Service schedule not found'; end if;
  basis_date:=p_basis_date; due_date:=(basis_date+make_interval(months=>p_interval_months))::date;
  fp:=encode(digest(p_due_basis||'|'||p_basis_reference||'|'||p_basis_date::text||'|'||p_interval_months::text,'sha256'),'hex');
  insert into survey_schedule_basis_history(schedule_id,old_interval_months,new_interval_months,old_due_basis,new_due_basis,old_basis_reference,new_basis_reference,old_basis_date,new_basis_date,changed_by,reason)
  values(old.id,old.survey_interval_months,p_interval_months,old.due_basis,p_due_basis,old.due_basis_reference,p_basis_reference,old.due_basis_date,basis_date,auth.uid(),'v2.8 explicit schedule basis/date configuration');
  update survey_schedules set survey_interval_months=p_interval_months,interval_months=p_interval_months,due_basis=p_due_basis,due_basis_reference=p_basis_reference,due_basis_date=basis_date,next_due_date=due_date,due_window_days_before=greatest(1,p_window_days_before),window_days_after=greatest(1,p_window_days_after),schedule_config_status='CONFIGURED',schedule_basis_document_id=p_basis_document_id,schedule_basis_approved_by=auth.uid(),schedule_basis_approved_at=now(),schedule_basis_sha256=fp,schedule_basis_snapshot=jsonb_build_object('basis',p_due_basis,'reference',p_basis_reference,'basis_date',basis_date,'interval_months',p_interval_months,'document_id',p_basis_document_id,'fingerprint',fp),configured_by=auth.uid(),configured_at=now(),window_start=(due_date-greatest(1,p_window_days_before))::date,window_end=(due_date+greatest(1,p_window_days_after))::date,status='SCHEDULED',intent_action=case when due_date<=current_date+90 then 'CREATE_IN_SERVICE_RFI' else 'MONITOR' end,updated_at=now() where id=old.id returning * into s;
  update survey_cycle_instances set due_date=s.next_due_date,window_start=s.window_start,window_end=s.window_end,schedule_basis=p_due_basis,schedule_basis_reference=p_basis_reference,updated_at=now() where schedule_id=s.id and cycle_number=s.cycle_number and status in ('PLANNED','DUE','BLOCKED');
  return s;
end;$$;
grant execute on function epas_set_in_service_schedule_basis_v28(uuid,integer,text,text,date,integer,integer,uuid) to authenticated;

-- ================================================================
-- 16. Status projection: explicit last-date semantics and cycle awareness.
-- ================================================================
create or replace function epas_refresh_vessel_survey_status_v28(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; new_status text; old_status text; last_date date; last_phase text; next_due date; source_id uuid;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v.project_id;
  if current_user<>'service_role' then
    if not epas_is_project_member(v.project_id) then raise exception 'Not authorized for vessel status'; end if;
    if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM/DM may refresh vessel status manually'; end if;
  end if;
  old_status:=v.survey_status;
  select max(coalesce(sr.completed_at,sr.submitted_at)::date),(array_agg(r.phase order by coalesce(sr.completed_at,sr.submitted_at) desc nulls last))[1]
    into last_date,last_phase
  from survey_reports sr join rfis r on r.id=sr.rfi_id where r.vessel_id=v.id;
  select next_due_date into next_due from survey_schedules where vessel_id=v.id and active order by next_due_date limit 1;
  select r.id into source_id from rfis r where r.vessel_id=v.id order by r.updated_at desc limit 1;
  if p.status='closed' then new_status:='PROJECT_CLOSED';
  elsif exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='in_service' and r.status not in ('certificate_issued','closed')) then new_status:='IN_SERVICE_IN_PROGRESS';
  elsif exists(select 1 from survey_schedules s where s.vessel_id=v.id and s.active and s.status='OVERDUE') then new_status:='IN_SERVICE_OVERDUE';
  elsif exists(select 1 from survey_schedules s where s.vessel_id=v.id and s.active and s.status in ('DUE','DUE_SOON')) then new_status:='IN_SERVICE_DUE';
  elsif exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey' and r.status not in ('certificate_issued','closed')) then new_status:='NSC_IN_PROGRESS';
  elsif exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey' and r.status in ('certificate_issued','closed')) then new_status:='CLASS_ACTIVE';
  elsif 'in_service'=any(coalesce(p.phases,'{}'::text[])) then new_status:='IN_SERVICE_DUE';
  elsif 'nsc_survey'=any(coalesce(p.phases,'{}'::text[])) then new_status:='NSC_DUE';
  else new_status:='PLAN_APPRAISAL'; end if;
  update vessels set survey_status=new_status,survey_status_updated_at=now(),last_survey_date=last_date,last_survey_phase=last_phase,next_survey_due=next_due where id=v.id returning * into v;
  if old_status is distinct from new_status then
    insert into vessel_survey_status_history(vessel_id,project_id,status,phase,source_type,source_id,note) values(v.id,v.project_id,new_status,last_phase,'SYSTEM',source_id,'v2.8 centralized survey status engine');
  end if;
  return v;
end;$$;
grant execute on function epas_refresh_vessel_survey_status_v28(uuid) to authenticated,service_role;

-- ================================================================
-- 17. Role-safe manager status refresh wrapper.
-- ================================================================
create or replace function epas_refresh_vessel_status_as_manager_v28(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels;
begin
  select * into v from vessels where id=p_vessel_id;
  if v.id is null then raise exception 'Vessel not found'; end if;
  if not epas_is_project_member(v.project_id) then raise exception 'Not authorized for vessel'; end if;
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM/DM may refresh vessel status manually'; end if;
  return epas_refresh_vessel_survey_status_v28(p_vessel_id);
end;$$;
grant execute on function epas_refresh_vessel_status_as_manager_v28(uuid) to authenticated;

-- ================================================================
-- 18. Recurring schedule synchronization v2.8 with explicit cycle instance.
-- ================================================================
create or replace function epas_sync_survey_schedule_v28(p_vessel_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare s survey_schedules; cycle_id uuid;
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  s:=epas_sync_survey_schedule_v27(p_vessel_id);
  if s.id is null then return null; end if;
  if s.phase='in_service' and s.active then
    if s.cycle_instance_id is null then
      insert into survey_cycle_instances(schedule_id,project_id,vessel_id,phase,cycle_number,status,due_date,window_start,window_end,rfi_id,source_certificate_id,schedule_basis,schedule_basis_reference)
      values(s.id,s.project_id,s.vessel_id,'in_service',s.cycle_number,case when s.current_rfi_id is not null then 'RFI_OPEN' when s.status in ('DUE','DUE_SOON','OVERDUE','SCHEDULED') then 'DUE' else 'PLANNED' end,s.next_due_date,s.window_start,s.window_end,s.current_rfi_id,s.source_certificate_id,s.due_basis,s.due_basis_reference)
      on conflict(schedule_id,cycle_number) do update set status=excluded.status,rfi_id=coalesce(excluded.rfi_id,survey_cycle_instances.rfi_id),due_date=excluded.due_date,window_start=excluded.window_start,window_end=excluded.window_end,updated_at=now() returning id into cycle_id;
      update survey_schedules set cycle_instance_id=cycle_id where id=s.id returning * into s;
    else
      update survey_cycle_instances set rfi_id=s.current_rfi_id,status=case when s.current_rfi_id is not null then 'RFI_OPEN' when s.status in ('DUE','DUE_SOON','OVERDUE','SCHEDULED') then 'DUE' else status end,due_date=s.next_due_date,window_start=s.window_start,window_end=s.window_end,schedule_basis=s.due_basis,schedule_basis_reference=s.due_basis_reference,updated_at=now() where id=s.cycle_instance_id;
    end if;
  end if;
  return s;
end;$$;
grant execute on function epas_sync_survey_schedule_v28(uuid) to service_role;

-- ================================================================
-- 18. Recurring scheduler tick v2.8: service-only and notification-policy aware.
-- ================================================================
create or replace function epas_generate_survey_due_notifications_v28()
returns integer language plpgsql security definer set search_path=public as $$
declare s record; m record; allowed boolean; n integer:=0;
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  update survey_schedules set status=case when current_rfi_id is not null then 'RFI_OPEN' when schedule_config_status='CONFIGURATION_REQUIRED' then 'SUSPENDED' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,updated_at=now() where active and phase='in_service';
  for s in select * from survey_schedules where active and phase='in_service' and status in ('DUE_SOON','DUE','OVERDUE') loop
    for m in select pm.user_id,pm.role from project_members pm where pm.project_id=s.project_id and pm.active loop
      select coalesce((select allowed from survey_notification_policy_v27 x where x.phase=s.phase and x.role_name=m.role),false) into allowed;
      if allowed and not exists(select 1 from notifications x where x.user_id=m.user_id and x.project_id=s.project_id and x.link_page='survey_schedule:'||s.id::text and x.created_at::date=current_date) then
        insert into notifications(user_id,title,body,project_id,link_page) values(m.user_id,case s.status when 'OVERDUE' then 'In-Service survey overdue' when 'DUE' then 'In-Service survey due' else 'In-Service survey window approaching' end,format('%s cycle %s for %s due %s (%s days).',s.survey_type,s.cycle_number,(select name from vessels where id=s.vessel_id),s.next_due_date,(s.next_due_date-current_date)),s.project_id,'survey_schedule:'||s.id::text);
        n:=n+1;
      end if;
    end loop;
  end loop;
  return n;
end;$$;
grant execute on function epas_generate_survey_due_notifications_v28() to service_role;

create or replace function epas_scheduler_tick_v28()
returns jsonb language plpgsql security definer set search_path=public as $$
declare run_id uuid; v record; sc integer:=0; vc integer:=0; nc integer:=0; err integer:=0; started timestamptz:=now();
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  insert into scheduler_runs(run_type,status,started_at,metadata) values('EPAS_SURVEY_LIFECYCLE_V28','RUNNING',started,jsonb_build_object('version','2.8')) returning id into run_id;
  for v in select id from vessels loop
    begin perform epas_sync_survey_schedule_v28(v.id); sc:=sc+1; exception when others then err:=err+1; end;
    begin perform epas_refresh_vessel_survey_status_v28(v.id); vc:=vc+1; exception when others then err:=err+1; end;
  end loop;
  begin nc:=epas_generate_survey_due_notifications_v28(); exception when others then err:=err+1; end;
  update scheduler_runs set status=case when err=0 then 'SUCCEEDED' else 'SUCCEEDED_WITH_ERRORS' end,completed_at=now(),processed_count=sc,metadata=jsonb_build_object('version','2.8','schedules_processed',sc,'vessel_statuses_processed',vc,'notifications',nc,'errors',err) where id=run_id;
  return jsonb_build_object('run_id',run_id,'schedules_processed',sc,'vessel_statuses_processed',vc,'notifications',nc,'errors',err);
end;$$;
grant execute on function epas_scheduler_tick_v28() to service_role;

-- ================================================================
-- 19. Human schedule read/control wrapper stays project-scoped.
-- ================================================================
create or replace function epas_survey_schedule_queue_v28(p_project_id uuid default null)
returns table(schedule_id uuid,project_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,cycle_number integer,lifecycle_state text,due_basis_date date,next_due_date date,window_start date,window_end date,status text,schedule_config_status text,due_basis text,due_basis_reference text,survey_interval_months integer,current_rfi_id uuid,rfi_code text,rfi_status text,assigned_surveyor_id uuid,surveyor_name text)
language plpgsql security definer set search_path=public stable as $$
begin
  if p_project_id is not null and not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project schedule'; end if;
  if p_project_id is null and not(epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Global schedule requires GM/DM'; end if;
  return query
  select s.id,s.project_id,s.vessel_id,v.name,s.phase,s.survey_type,s.cycle_number,s.lifecycle_state,s.due_basis_date,s.next_due_date,s.window_start,s.window_end,s.status,s.schedule_config_status,s.due_basis,s.due_basis_reference,s.survey_interval_months,s.current_rfi_id,r.rfi_code,r.status,r.assigned_surveyor_id,p.full_name
  from survey_schedules s join vessels v on v.id=s.vessel_id
  left join rfis r on r.id=s.current_rfi_id
  left join profiles p on p.id=r.assigned_surveyor_id
  where s.active and (p_project_id is null or s.project_id=p_project_id)
  order by s.next_due_date;
end;$$;
grant execute on function epas_survey_schedule_queue_v28(uuid) to authenticated;

-- ================================================================
-- 20. Streamlit/acceptance metadata.
-- ================================================================
create table if not exists workflow_acceptance_cases_v28(
  case_code text primary key,
  role_name text not null,
  phase text,
  expected_result text not null,
  negative boolean not null default false,
  priority text not null default 'P1',
  created_at timestamptz not null default now()
);
insert into workflow_acceptance_cases_v28(case_code,role_name,phase,expected_result,negative,priority) values
('V28_IN_SERVICE_CYCLE_2','system','in_service','Cycle 1 completion creates/activates Cycle 2 while project In-Service remains ACTIVE',false,'P0'),
('V28_CYCLE_COMPLETE_AUTH','owner','in_service','Owner/Shipyard cannot mark a cycle complete',true,'P0'),
('V28_STATUS_MUTATION_AUTH','owner','in_service','Stakeholder cannot invoke service-only vessel status mutation',true,'P0'),
('V28_SCHEDULE_SYNC_AUTH','owner','in_service','Stakeholder cannot invoke service-only schedule synchronization',true,'P0'),
('V28_SCOPE_FINGERPRINT','surveyor','in_service','Scope acknowledgement is bound to exact scope version/hash',false,'P0'),
('V28_PACKAGE_FINGERPRINT','surveyor','in_service','Drawing package acknowledgement is bound to exact package version/fingerprint',false,'P0'),
('V28_CHECKLIST_FINGERPRINT','surveyor','in_service','Checklist readiness is bound to definition version/fingerprint',false,'P1'),
('V28_REVISION_IMPACT','dm','in_service','Revision impact stores shared/current revision/hash comparison evidence',false,'P0'),
('V28_CERTIFICATE_PACKAGE','gm','in_service','Certificate package freezes report/declaration/execution basis and exact DM acknowledgement',false,'P0'),
('V28_NOTIFICATION_BOUNDARY','shipyard','in_service','Shipyard receives no In-Service survey notifications',true,'P0'),
('V28_STREAMLIT_NO_ACTOR_SELECTOR','all',null,'Production Streamlit surface uses authenticated role only; no demo actor selector',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,negative=excluded.negative,priority=excluded.priority,role_name=excluded.role_name,phase=excluded.phase;

-- Strong direct-execution restrictions.
revoke all on function epas_sync_survey_schedule_v27(uuid) from authenticated,public;
revoke all on function epas_refresh_vessel_survey_status_v27(uuid) from authenticated,public;
revoke all on function epas_scheduler_tick_v27() from authenticated;
revoke all on function epas_mark_in_service_cycle_complete_v27(uuid) from authenticated;
revoke all on function epas_generate_survey_due_notifications_v26() from authenticated;
revoke all on function epas_refresh_vessel_survey_status_v26(uuid) from authenticated;
revoke all on function epas_sync_survey_schedule_v26(uuid) from authenticated;

grant execute on function epas_sync_survey_schedule_v27(uuid) to service_role;
grant execute on function epas_refresh_vessel_survey_status_v28(uuid) to service_role;
grant execute on function epas_scheduler_tick_v28() to service_role;
grant execute on function epas_mark_in_service_cycle_complete_v28(uuid) to authenticated;
grant execute on function epas_generate_survey_due_notifications_v28() to service_role;


-- ================================================================
-- 21. Authoritative v2.8 execution basis/start/submission gates.
-- ================================================================
create or replace function epas_freeze_survey_execution_basis_v28(p_rfi_id uuid)
returns survey_execution_basis_versions language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; s survey_scopes; a survey_assignments; gate jsonb; ver integer; snapshot jsonb; fp text; b survey_execution_basis_versions; pkgv integer; chkver integer; assign_fp text; scope_fp text; chk_fp text;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  select * into a from survey_assignments where rfi_id=p_rfi_id;
  if r.id is null or e.id is null or s.id is null or a.id is null then raise exception 'Survey execution context is incomplete'; end if;
  if not(epas_has_role('surveyor') and e.surveyor_id=auth.uid()) then raise exception 'Only assigned Surveyor may freeze execution basis'; end if;
  gate:=epas_survey_start_gate_v28(p_rfi_id);
  if not coalesce((gate->>'ready')::boolean,false) then raise exception 'Survey start gate is not satisfied: %',gate::text; end if;
  ver:=coalesce((select max(basis_version) from survey_execution_basis_versions where execution_id=e.id),0)+1;
  pkgv:=(gate->>'drawing_package_version')::integer;
  chkver:=(gate->>'checklist_version')::integer;
  assign_fp:=epas_assignment_fingerprint(a.id);
  scope_fp:=gate->>'scope_sha256';
  chk_fp:=gate->>'checklist_definition_fingerprint';
  snapshot:=jsonb_build_object(
    'rfi_id',r.id,'assignment_id',a.id,'assignment_version',a.assignment_version,'assignment_fingerprint',assign_fp,
    'scope_version',s.current_version,'scope_sha256',scope_fp,
    'scope_snapshot',(select to_jsonb(sv) from survey_scope_versions sv where sv.rfi_id=r.id and sv.version_no=s.current_version),
    'drawing_package_version',pkgv,'drawing_package_fingerprint',gate->>'drawing_package_fingerprint',
    'checklist_version',chkver,'checklist_definition_fingerprint',chk_fp,'frozen_at',now());
  fp:=encode(digest(snapshot::text,'sha256'),'hex');
  insert into survey_execution_basis_versions(execution_id,rfi_id,basis_version,scope_version,drawing_package_version,checklist_version,assignment_id,assignment_version,package_ack_version,scope_ack_version,basis_snapshot,basis_sha256,frozen_by)
  values(e.id,r.id,ver,s.current_version,pkgv,chkver,a.id,a.assignment_version,pkgv,s.current_version,snapshot,fp,auth.uid()) returning * into b;
  update survey_executions set execution_basis_version=ver,basis_sha256=fp,basis_frozen_at=now(),scope_version=s.current_version,drawing_package_version=pkgv,checklist_version=chkver,scope_version_sha256=scope_fp,drawing_package_fingerprint=gate->>'drawing_package_fingerprint',checklist_definition_sha256=chk_fp,assignment_version=a.assignment_version,updated_at=now() where id=e.id;
  return b;
end;$$;
grant execute on function epas_freeze_survey_execution_basis_v28(uuid) to authenticated;

create or replace function epas_start_survey_execution_v28(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
declare r rfis; a survey_assignments; e survey_executions; g jsonb;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may start survey execution'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  select * into a from survey_assignments where rfi_id=p_rfi_id for update;
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  if r.id is null or a.id is null or e.id is null then raise exception 'Controlled survey execution context is incomplete'; end if;
  if r.assigned_surveyor_id<>auth.uid() or a.surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  g:=epas_survey_start_gate_v28(p_rfi_id);
  if not coalesce((g->>'ready')::boolean,false) then raise exception 'Survey start gate failed: %',g::text; end if;
  perform epas_freeze_survey_execution_basis_v28(p_rfi_id);
  update survey_executions set status='IN_PROGRESS',started_at=coalesce(started_at,now()),started_by=auth.uid(),updated_at=now() where id=e.id returning * into e;
  update survey_assignments set status='IN_PROGRESS' where id=a.id;
  return e;
end;$$;
grant execute on function epas_start_survey_execution_v28(uuid) to authenticated;

create or replace function epas_survey_submission_gate_v28(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; d survey_execution_declarations; g jsonb;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into d from survey_execution_declarations where execution_id=e.id;
  if r.id is null or e.id is null then raise exception 'Survey execution not found'; end if;
  g:=epas_survey_start_gate_v28(p_rfi_id);
  return g || jsonb_build_object(
    'basis_frozen',e.basis_frozen_at is not null,
    'execution_basis_version',e.execution_basis_version,
    'basis_sha256',e.basis_sha256,
    'declaration_complete',d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete,
    'ready_to_submit',coalesce((g->>'ready')::boolean,false) and e.basis_frozen_at is not null and d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete
  );
end;$$;
grant execute on function epas_survey_submission_gate_v28(uuid) to authenticated;

create or replace function epas_guard_survey_report_submit_v28()
returns trigger language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; g jsonb;
begin
  select * into r from rfis where id=new.rfi_id;
  select * into e from survey_executions where rfi_id=new.rfi_id;
  if r.id is null or e.id is null then raise exception 'Controlled survey execution is required'; end if;
  if new.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey report must be submitted by assigned Surveyor'; end if;
  g:=epas_survey_submission_gate_v28(new.rfi_id);
  if not coalesce((g->>'ready_to_submit')::boolean,false) then raise exception 'Survey report submission gate failed: %',g::text; end if;
  return new;
end;$$;
drop trigger if exists trg_epas_guard_survey_report_submit_v28 on survey_reports;
create trigger trg_epas_guard_survey_report_submit_v28 before insert or update on survey_reports for each row execute function epas_guard_survey_report_submit_v28();

-- ================================================================
-- 21. Final controlled survey report submission with report hash/basis anchors.
-- ================================================================
create or replace function epas_submit_survey_report(
  p_rfi_id uuid,p_report_note text,p_observations jsonb default '[]'::jsonb,
  p_evidence_path text default null,p_evidence_sha256 text default null,
  p_mime_type text default null,p_size_bytes bigint default null,
  p_location text default null,p_survey_date date default current_date,
  p_attendance text default null,p_declaration text default null
) returns survey_reports
language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_report survey_reports; v_item jsonb; v_dm uuid; v_code text; e survey_executions; report_fp text;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may submit survey report'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  if v_rfi.id is null or e.id is null then raise exception 'Controlled survey execution is required'; end if;
  if v_rfi.assigned_surveyor_id<>auth.uid() then raise exception 'RFI is assigned to another Surveyor'; end if;
  if coalesce(trim(p_report_note),'')='' then raise exception 'Survey report is required'; end if;
  if coalesce(trim(p_declaration),'')='' then raise exception 'Surveyor declaration is required'; end if;
  if p_evidence_path is not null and position(('projects/'||v_rfi.project_id::text||'/survey-reports/'||v_rfi.id::text||'/') in p_evidence_path)<>1 then raise exception 'Survey evidence must use the controlled survey-report path'; end if;
  report_fp:=coalesce(p_evidence_sha256,encode(digest(coalesce(p_report_note,'')||'|'||coalesce(p_declaration,''),'sha256'),'hex'));
  insert into survey_reports(rfi_id,surveyor_id,report_note,survey_date,location,attendance,evidence_path,declaration,evidence_sha256,evidence_size_bytes,mime_type,report_sha256,report_completed_at,execution_basis_version)
  values(p_rfi_id,auth.uid(),p_report_note,p_survey_date,p_location,p_attendance,p_evidence_path,p_declaration,p_evidence_sha256,p_size_bytes,p_mime_type,report_fp,now(),e.execution_basis_version)
  returning * into v_report;
  for v_item in select * from jsonb_array_elements(coalesce(p_observations,'[]'::jsonb)) loop
    v_code:=coalesce(nullif(v_item->>'obs_code',''),'OBS-'||to_char(current_date,'YYYYMMDD')||'-'||substr(gen_random_uuid()::text,1,8));
    insert into observations(rfi_id,obs_code,description,severity,status,raised_by,location,rule_reference,deficiency_category,responsible_party,target_date,corrective_action)
    values(p_rfi_id,v_code,coalesce(v_item->>'description',''),coalesce(v_item->>'severity','Minor'),'open',auth.uid(),nullif(v_item->>'location',''),nullif(v_item->>'rule_reference',''),nullif(v_item->>'deficiency_category',''),nullif(v_item->>'responsible_party',''),nullif(v_item->>'target_date','')::date,nullif(v_item->>'corrective_action',''));
  end loop;
  update survey_executions set status='REPORT_SUBMITTED',report_id=v_report.id,report_sha256=report_fp,report_completed_at=now(),completed_at=now(),updated_at=now() where id=e.id;
  update rfis set status='observations_logged',updated_at=now() where id=p_rfi_id returning * into v_rfi;
  v_dm:=v_rfi.assigned_dm_id;
  perform epas_create_task(v_rfi.project_id,'SURVEY_DM_REVIEW',v_dm,'Survey report submitted. Review the report, evidence and complete observation register before forwarding to GM.','rfi',p_rfi_id,null,'high');
  perform epas_audit(v_rfi.project_id,'SURVEY_REPORT_SUBMITTED','rfi',p_rfi_id,'survey_in_progress','observations_logged','Controlled survey report submitted',jsonb_build_object('observation_count',jsonb_array_length(coalesce(p_observations,'[]'::jsonb)),'report_sha256',report_fp,'execution_basis_version',e.execution_basis_version));
  return v_report;
end;$$;
grant execute on function epas_submit_survey_report(uuid,text,jsonb,text,text,text,bigint,text,date,text,text) to authenticated;

-- ================================================================
-- 22. Live acceptance matrix and deployment readiness metadata.
-- ================================================================
create table if not exists deployment_readiness_checks_v28(
  check_code text primary key,
  description text not null,
  required boolean not null default true,
  passed boolean not null default false,
  evidence text,
  checked_at timestamptz,
  checked_by uuid references profiles(id)
);
insert into deployment_readiness_checks_v28(check_code,description,required) values
('RLS_LIVE','Live Supabase RLS and Storage isolation tested with all eight roles',true),
('CRON_LIVE','Supabase Cron scheduler tick is installed and executes successfully',true),
('BROWSER_LIVE','Streamlit browser smoke test executed against configured Supabase',true),
('IN_SERVICE_CYCLE_2','In-Service cycle 1 completion followed by cycle 2 creation verified',true),
('STAKEHOLDER_BOUNDARY','Shipyard NSC-only / Owner and Ship Management In-Service-only verified',true)
on conflict(check_code) do update set description=excluded.description,required=excluded.required;

alter table deployment_readiness_checks_v28 enable row level security;
drop policy if exists deployment_readiness_select_v28 on deployment_readiness_checks_v28;
create policy deployment_readiness_select_v28 on deployment_readiness_checks_v28 for select to authenticated using (epas_has_role('gm') or epas_has_role('dm'));
drop policy if exists deployment_readiness_write_v28 on deployment_readiness_checks_v28;
create policy deployment_readiness_write_v28 on deployment_readiness_checks_v28 for all to authenticated using(false) with check(false);

commit;
