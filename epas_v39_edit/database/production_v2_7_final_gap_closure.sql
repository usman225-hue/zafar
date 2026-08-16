-- EPAS v2.7 — Final Gap Closure, Recurring In-Service Hardening & Streamlit Production Surface
-- Cumulative after v2.6.
-- This migration closes the remaining workflow/security/runtime gaps identified
-- in the v2.6 audit.
--
-- Authoritative stakeholder RFI policy:
--   Shipyard        -> NSC Survey only
--   Owner           -> In-Service Survey only
--   Ship Management -> In-Service Survey only
--
-- Critical lifecycle rule:
--   In-Service is a persistent project phase. A survey cycle completes;
--   the In-Service phase remains ACTIVE for the next cycle.
--
-- Production principle:
--   service-role scheduler performs autonomous state synchronization;
--   human users receive project-scoped guided actions only.

begin;

create extension if not exists pgcrypto;

-- ================================================================
-- 1. Persistent In-Service phase semantics
-- ================================================================
alter table project_phase_control
  add column if not exists lifecycle_status text not null default 'ACTIVE';

alter table projects
  add column if not exists scope_status text;

create or replace function epas_phase_gate_status(p_project_id uuid, p_phase text)
returns table(status text, gate_passed boolean, note text)
language plpgsql security definer set search_path=public stable as $$
declare
  v_phases text[];
  v_plan_drawings integer := 0;
  v_plan_approved integer := 0;
  v_plan_open_obs integer := 0;
  v_nsc_total integer := 0;
  v_nsc_done integer := 0;
  v_nsc_open_obs integer := 0;
  v_in_total integer := 0;
  v_in_done integer := 0;
  v_in_open_obs integer := 0;
  v_plan_ready boolean := true;
  v_nsc_ready boolean := true;
  v_in_cycle_complete boolean := false;
  v_has_in_cycle boolean := false;
begin
  select phases into v_phases from projects where id=p_project_id;
  if v_phases is null then raise exception 'Project not found'; end if;

  select count(*),count(*) filter(where d.status='approved')
    into v_plan_drawings,v_plan_approved
  from plan_drawings d where d.project_id=p_project_id;
  select count(*) into v_plan_open_obs
  from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id
  where d.project_id=p_project_id and o.status='open';
  v_plan_ready := (v_plan_drawings > 0 and v_plan_drawings=v_plan_approved and v_plan_open_obs=0);

  select count(*),count(*) filter(where r.status in ('certificate_issued','closed'))
    into v_nsc_total,v_nsc_done
  from rfis r
  where r.project_id=p_project_id and r.phase='nsc_survey'
    and coalesce(r.follow_up_type,'') not in ('IN_SERVICE_OBSERVATION_CLEARANCE','CHANGE_OF_CLASS_FOLLOW_UP');
  select count(*) into v_nsc_open_obs
  from observations o join rfis r on r.id=o.rfi_id
  where r.project_id=p_project_id and r.phase='nsc_survey' and o.status='open';
  v_nsc_ready := (v_nsc_total > 0 and v_nsc_total=v_nsc_done and v_nsc_open_obs=0);

  select count(*),count(*) filter(where r.status in ('certificate_issued','closed'))
    into v_in_total,v_in_done
  from rfis r where r.project_id=p_project_id and r.phase='in_service';
  v_has_in_cycle := v_in_total > 0;
  select count(*) into v_in_open_obs
  from observations o join rfis r on r.id=o.rfi_id
  where r.project_id=p_project_id and r.phase='in_service' and o.status='open';
  v_in_cycle_complete := v_has_in_cycle and v_in_done=v_in_total and v_in_open_obs=0;

  if p_phase='plan_appraisal' then
    if not ('plan_appraisal'=any(v_phases)) then
      return query select 'NOT_APPLICABLE',false,'Plan Appraisal is not part of this project'; return;
    end if;
    if v_plan_ready then
      return query select 'COMPLETED',true,'All Plan Appraisal drawings are approved and no open plan observations remain';
    else
      return query select 'IN_PROGRESS',false,format('Approved drawings %s/%s; open observations: %s',v_plan_approved,v_plan_drawings,v_plan_open_obs);
    end if;

  elsif p_phase='nsc_survey' then
    if not ('nsc_survey'=any(v_phases)) then
      return query select 'NOT_APPLICABLE',false,'NSC Survey is not part of this project'; return;
    end if;
    if 'plan_appraisal'=any(v_phases) and not v_plan_ready then
      return query select 'LOCKED',false,'NSC is locked until Plan Appraisal is complete'; return;
    end if;
    if v_nsc_ready then
      return query select 'COMPLETED',true,'NSC survey scope is complete with no open observations';
    elsif v_nsc_total=0 then
      return query select 'READY',true,'NSC phase is eligible; waiting for Shipyard NSC RFI';
    else
      return query select 'IN_PROGRESS',false,format('NSC RFIs completed %s/%s; open observations: %s',v_nsc_done,v_nsc_total,v_nsc_open_obs);
    end if;

  elsif p_phase='in_service' then
    if not ('in_service'=any(v_phases)) then
      return query select 'NOT_APPLICABLE',false,'In-Service is not part of this project'; return;
    end if;
    if 'nsc_survey'=any(v_phases) and not v_nsc_ready then
      return query select 'LOCKED',false,'In-Service is locked until NSC survey scope is complete'; return;
    end if;
    if not ('nsc_survey'=any(v_phases)) and 'plan_appraisal'=any(v_phases) and not v_plan_ready then
      return query select 'LOCKED',false,'In-Service is locked until Plan Appraisal is complete'; return;
    end if;
    if v_in_cycle_complete then
      return query select 'IN_PROGRESS',true,'In-Service phase remains active; the completed survey cycle has opened the next recurring cycle'; return;
    elsif v_has_in_cycle then
      return query select 'IN_PROGRESS',false,format('Current In-Service cycle is active; %s/%s cycles closed; open observations: %s',v_in_done,v_in_total,v_in_open_obs);
    else
      return query select 'READY',true,'In-Service phase is eligible; waiting for Owner / Ship Management RFI'; return;
    end if;
  else
    raise exception 'Invalid phase';
  end if;
end;$$;

create or replace function epas_refresh_project_phase_state(p_project_id uuid)
returns setof project_phase_control
language plpgsql security definer set search_path=public as $$
declare
  p text; s text; g boolean; n text; phases text[]; seq integer; prev_phase text; prev_status text;
  old_started timestamptz; old_completed timestamptz;
begin
  select projects.phases into phases from projects where id=p_project_id;
  if phases is null then raise exception 'Project not found'; end if;
  foreach p in array array['plan_appraisal','nsc_survey','in_service'] loop
    seq:=case p when 'plan_appraisal' then 1 when 'nsc_survey' then 2 else 3 end;
    if not (p=any(phases)) then
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note,started_at,completed_at,lifecycle_status)
      values(p_project_id,p,seq,'NOT_APPLICABLE',false,p||' not selected',null,null,'COMPLETED')
      on conflict(project_id,phase) do update set sequence_no=excluded.sequence_no,status='NOT_APPLICABLE',gate_passed=false,gate_note=excluded.gate_note,lifecycle_status='COMPLETED',updated_at=now();
    else
      select status,gate_passed,note into s,g,n from epas_phase_gate_status(p_project_id,p) limit 1;
      if p='nsc_survey' and 'plan_appraisal'=any(phases) then
        select pc.status into prev_status from project_phase_control pc where pc.project_id=p_project_id and pc.phase='plan_appraisal';
        if coalesce(prev_status,'')<>'COMPLETED' then s:='LOCKED'; g:=false; n:='Waiting for Plan Appraisal completion'; end if;
      elsif p='in_service' then
        prev_phase:=case when 'nsc_survey'=any(phases) then 'nsc_survey' when 'plan_appraisal'=any(phases) then 'plan_appraisal' else null end;
        if prev_phase is not null then
          select pc.status into prev_status from project_phase_control pc where pc.project_id=p_project_id and pc.phase=prev_phase;
          if coalesce(prev_status,'')<>'COMPLETED' then s:='LOCKED'; g:=false; n:='Waiting for '||replace(prev_phase,'_',' ')||' completion'; end if;
        end if;
        -- A persistent operational phase never transitions to COMPLETED.
        if s='COMPLETED' then s:='IN_PROGRESS'; g:=true; n:='In-Service phase remains ACTIVE after each completed survey cycle'; end if;
      end if;
      select started_at,completed_at into old_started,old_completed from project_phase_control where project_id=p_project_id and phase=p;
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note,started_at,completed_at,lifecycle_status)
      values(p_project_id,p,seq,s,g,n,
             case when s in ('IN_PROGRESS','COMPLETED') then coalesce(old_started,now()) end,
             case when p<>'in_service' and s='COMPLETED' then coalesce(old_completed,now()) else null end,
             case when p='in_service' and s in ('READY','IN_PROGRESS') then 'ACTIVE' else case when s='COMPLETED' then 'COMPLETED' else 'ACTIVE' end end)
      on conflict(project_id,phase) do update set
        sequence_no=excluded.sequence_no,status=excluded.status,gate_passed=excluded.gate_passed,gate_note=excluded.gate_note,
        started_at=coalesce(project_phase_control.started_at,excluded.started_at),
        completed_at=case when project_phase_control.phase='in_service' then null else excluded.completed_at end,
        lifecycle_status=excluded.lifecycle_status,updated_at=now();
    end if;
  end loop;
  update projects set
    current_phase=case when 'in_service'=any(phases) then 'in_service' when 'nsc_survey'=any(phases) then 'nsc_survey' else 'plan_appraisal' end,
    current_phase_status=(select pc.status from project_phase_control pc where pc.project_id=p_project_id and pc.phase=case when 'in_service'=any(phases) then 'in_service' when 'nsc_survey'=any(phases) then 'nsc_survey' else 'plan_appraisal' end),
    scope_status=case
      when 'in_service'=any(phases) then 'IN_SERVICE_ACTIVE'
      when 'nsc_survey'=any(phases) then case when exists(select 1 from project_phase_control pc where pc.project_id=p_project_id and pc.phase='nsc_survey' and pc.status='COMPLETED') then 'NSC_COMPLETE' else 'NSC_ACTIVE' end
      when 'plan_appraisal'=any(phases) then 'PLAN_ONLY'
      else 'NOT_STARTED' end,
    updated_at=now()
  where id=p_project_id;
  return query select * from project_phase_control where project_id=p_project_id order by sequence_no;
end;$$;

-- ================================================================
-- 2. Explicit recurring cycle control state
-- ================================================================
alter table survey_schedules add column if not exists lifecycle_state text not null default 'ACTIVE';
alter table survey_schedules add column if not exists schedule_basis_document_id uuid references documents(id);
alter table survey_schedules add column if not exists schedule_basis_approved_by uuid references profiles(id);
alter table survey_schedules add column if not exists schedule_basis_approved_at timestamptz;
alter table survey_schedules add column if not exists schedule_basis_sha256 text;
alter table survey_schedules add column if not exists configured_by uuid references profiles(id);
alter table survey_schedules add column if not exists configured_at timestamptz;
alter table survey_schedules add column if not exists last_survey_completed_at timestamptz;
alter table survey_schedules add column if not exists last_certificate_issued_at timestamptz;

update survey_schedules set lifecycle_state='ACTIVE' where lifecycle_state is null;

-- ================================================================
-- 3. Immutable survey package-set acknowledgement
-- ================================================================
create table if not exists survey_drawing_package_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  package_version integer not null,
  package_fingerprint text not null,
  drawing_count integer not null default 0,
  acknowledged_by uuid not null references profiles(id),
  acknowledged_at timestamptz not null default now(),
  note text,
  unique(rfi_id,package_version,acknowledged_by)
);
create index if not exists idx_survey_pkg_ack_rfi on survey_drawing_package_acknowledgements(rfi_id,package_version desc);

create or replace function epas_survey_drawing_package_fingerprint(p_rfi_id uuid,p_package_version integer default null)
returns text
language sql security definer set search_path=public stable as $$
  select encode(digest(
    coalesce(string_agg(
      coalesce(s.shared_drawing_no,'')||'|'||coalesce(s.shared_title,'')||'|'||coalesce(s.shared_discipline,'')||'|'||
      coalesce(s.shared_revision::text,'')||'|'||coalesce(s.shared_document_id::text,'')||'|'||coalesce(s.shared_file_name,'')||'|'||
      coalesce(s.shared_storage_path,'')||'|'||coalesce(s.shared_sha256,'')||'|'||coalesce(s.shared_mime_type,'')||'|'||coalesce(s.shared_size_bytes::text,'')
      ,'||' order by s.id),'')::bytea), 'sha256');
$$;

create or replace function epas_acknowledge_survey_drawing_package_v27(p_rfi_id uuid,p_note text default '')
returns survey_drawing_package_acknowledgements
language plpgsql security definer set search_path=public as $$
declare r rfis; pkg record; fp text; a survey_drawing_package_acknowledgements; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  role_name:=(select role from profiles where id=auth.uid());
  if role_name<>'surveyor' or r.assigned_surveyor_id<>auth.uid() then raise exception 'Only the assigned Surveyor may acknowledge the drawing package'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Surveyor is not an active project member'; end if;
  select max(package_version) as package_version,count(*) filter(where revoked_at is null) as drawing_count
    into pkg from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null;
  if coalesce(pkg.drawing_count,0)=0 and exists(select 1 from plan_drawings d where d.project_id=r.project_id and d.status='approved') then
    raise exception 'No active approved drawing package exists for this survey';
  end if;
  fp:=epas_survey_drawing_package_fingerprint(p_rfi_id,pkg.package_version);
  insert into survey_drawing_package_acknowledgements(rfi_id,package_version,package_fingerprint,drawing_count,acknowledged_by,note)
  values(r.id,coalesce(pkg.package_version,1),fp,coalesce(pkg.drawing_count,0),auth.uid(),nullif(trim(p_note),''))
  on conflict(rfi_id,package_version,acknowledged_by) do update set package_fingerprint=excluded.package_fingerprint,drawing_count=excluded.drawing_count,acknowledged_at=now(),note=excluded.note
  returning * into a;
  update survey_executions set drawing_package_ack_version=a.package_version,updated_at=now() where rfi_id=r.id and surveyor_id=auth.uid();
  perform epas_audit(r.project_id,'SURVEY_DRAWING_PACKAGE_ACKNOWLEDGED','rfi',r.id,'surveyor','ACKNOWLEDGED','Immutable drawing package acknowledged',jsonb_build_object('package_version',a.package_version,'fingerprint',fp,'drawing_count',a.drawing_count));
  return a;
end;$$;
grant execute on function epas_acknowledge_survey_drawing_package_v27(uuid,text) to authenticated;

-- ================================================================
-- 4. Scope amendment invalidation and exact version anchors
-- ================================================================
alter table survey_executions add column if not exists scope_version integer;
alter table survey_executions add column if not exists drawing_package_version integer;
alter table survey_executions add column if not exists checklist_version integer;
alter table survey_executions add column if not exists scope_version_sha256 text;
alter table survey_executions add column if not exists drawing_package_fingerprint text;
alter table survey_executions add column if not exists checklist_definition_sha256 text;

create table if not exists survey_scope_change_events (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  old_version integer,
  new_version integer,
  old_scope_sha256 text,
  new_scope_sha256 text,
  invalidated_scope_ack boolean not null default false,
  invalidated_drawing_package boolean not null default false,
  invalidated_checklist boolean not null default false,
  invalidated_execution_basis boolean not null default false,
  changed_by uuid references profiles(id),
  changed_at timestamptz not null default now(),
  reason text
);

create or replace function epas_invalidate_scope_dependencies(p_rfi_id uuid,p_new_version integer,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare r rfis; old_ver integer; scope_sha text;
begin
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null then return; end if;
  select max(version_no) into old_ver from survey_scope_versions where rfi_id=p_rfi_id and version_no<p_new_version;
  select encode(digest(coalesce((select scope_text from survey_scope_versions where rfi_id=p_rfi_id and version_no=p_new_version),''),'sha256'),'hex') into scope_sha;

  update survey_scope_acknowledgements set note=coalesce(note,'')||' | INVALIDATED by scope version '||p_new_version where rfi_id=p_rfi_id and scope_version<>p_new_version;
  update survey_rfi_drawings set package_state='SUPERSEDED',revoked_at=coalesce(revoked_at,now()) where rfi_id=p_rfi_id and revoked_at is null;
  update survey_checklist_items set status='pending' where rfi_id=p_rfi_id;
  update survey_executions set basis_frozen_at=null,basis_sha256=null,execution_basis_version=null,scope_acknowledged_at=null,scope_acknowledged_version=null,drawing_package_ack_version=null,updated_at=now() where rfi_id=p_rfi_id and status in ('NOT_STARTED','IN_PROGRESS');
  insert into survey_scope_change_events(rfi_id,old_version,new_version,old_scope_sha256,new_scope_sha256,invalidated_scope_ack,invalidated_drawing_package,invalidated_checklist,invalidated_execution_basis,changed_by,reason)
  values(p_rfi_id,old_ver,p_new_version,null,scope_sha,true,true,true,true,auth.uid(),p_reason);
end;$$;

-- Re-issue scope-version ack by explicitly freezing the current version.
create or replace function epas_acknowledge_survey_scope(p_rfi_id uuid,p_note text default '')
returns survey_scope_acknowledgements
language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_scopes; a survey_scope_acknowledgements; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  role_name:=(select role from profiles where id=auth.uid());
  if r.id is null or s.id is null then raise exception 'Survey scope not found'; end if;
  if role_name<>'surveyor' or r.assigned_surveyor_id<>auth.uid() then raise exception 'Only assigned Surveyor may acknowledge survey scope'; end if;
  insert into survey_scope_acknowledgements(rfi_id,scope_version,acknowledged_by,acknowledged_role,note)
  values(r.id,s.current_version,auth.uid(),role_name,nullif(trim(p_note),''))
  on conflict(rfi_id,scope_version,acknowledged_by) do update set acknowledged_at=now(),note=excluded.note
  returning * into a;
  update survey_executions set scope_acknowledged_at=a.acknowledged_at,scope_acknowledged_version=a.scope_version,updated_at=now() where rfi_id=r.id and surveyor_id=auth.uid();
  return a;
end;$$;
grant execute on function epas_acknowledge_survey_scope(uuid,text) to authenticated;

-- ================================================================
-- 5. Versioned checklist definition fingerprint
-- ================================================================
create or replace function epas_survey_checklist_definition_fingerprint(p_phase text,p_version integer)
returns text language sql security definer set search_path=public stable as $$
  select encode(digest(coalesce(string_agg(
    coalesce(i.item_code,'')||'|'||coalesce(i.category,'')||'|'||coalesce(i.requirement,'')||'|'||i.mandatory::text||'|'||i.sort_order::text,
    '||' order by i.sort_order,i.id),''),'sha256'),'hex')
  from survey_checklist_definition_items i
  join survey_checklist_definitions d on d.id=i.definition_id
  where d.phase=p_phase and d.checklist_version=p_version;
$$;

-- ================================================================
-- 6. Strong survey start/report gate with exact package/scope/checklist versions
-- ================================================================
create or replace function epas_survey_start_gate_v27(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r rfis; a survey_assignments; e survey_executions; s survey_scopes; pkgver integer; pkgfp text; checklistver integer; checklistfp text; scope_ack boolean; package_ack boolean; revision_clear boolean; checklist_ok boolean;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into a from survey_assignments where rfi_id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  if r.id is null or e.id is null then raise exception 'Controlled survey execution is required'; end if;
  pkgver:=coalesce((select max(package_version) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),1);
  pkgfp:=epas_survey_drawing_package_fingerprint(p_rfi_id,pkgver);
  checklistver:=coalesce((select max(checklist_version) from survey_checklist_items where rfi_id=p_rfi_id),1);
  checklistfp:=epas_survey_checklist_definition_fingerprint(r.phase,checklistver);
  scope_ack:=exists(select 1 from survey_scope_acknowledgements x where x.rfi_id=r.id and x.scope_version=s.current_version and x.acknowledged_by=r.assigned_surveyor_id);
  package_ack:=exists(select 1 from survey_drawing_package_acknowledgements x where x.rfi_id=r.id and x.package_version=pkgver and x.package_fingerprint=pkgfp and x.acknowledged_by=r.assigned_surveyor_id);
  checklist_ok:=epas_survey_checklist_ready(r.id) and coalesce(checklistfp,'')<>'';
  revision_clear:=not exists(select 1 from survey_rfi_drawings x join plan_drawings d on d.id=x.drawing_id join documents doc on doc.id=d.document_id left join survey_drawing_impact_decisions q on q.package_id=x.id where x.rfi_id=r.id and x.revoked_at is null and (q.id is null and (x.shared_revision is distinct from d.revision or coalesce(x.shared_sha256,'') is distinct from coalesce(doc.sha256,'')) or q.impact='REISSUE_REQUIRED'));
  return jsonb_build_object(
    'assignment_accepted',a.status in ('ACCEPTED','IN_PROGRESS','COMPLETED'),
    'scope_acknowledged',scope_ack,
    'package_acknowledged',package_ack,
    'checklist_ready',checklist_ok,
    'revision_impact_clear',revision_clear,
    'scope_version',s.current_version,
    'drawing_package_version',pkgver,
    'drawing_package_fingerprint',pkgfp,
    'checklist_version',checklistver,
    'checklist_definition_fingerprint',checklistfp,
    'ready',a.status in ('ACCEPTED','IN_PROGRESS','COMPLETED') and scope_ack and package_ack and checklist_ok and revision_clear
  );
end;$$;
grant execute on function epas_survey_start_gate_v27(uuid) to authenticated;

-- ================================================================
-- 7. Exact Survey execution basis freeze
-- ================================================================
create or replace function epas_freeze_survey_execution_basis_v27(p_rfi_id uuid)
returns survey_execution_basis_versions
language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; s survey_scopes; a survey_assignments; gate jsonb; ver integer; snapshot jsonb; fp text; b survey_execution_basis_versions; pkgv integer; chkver integer;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  select * into a from survey_assignments where rfi_id=p_rfi_id;
  if r.id is null or e.id is null or s.id is null or a.id is null then raise exception 'Survey execution context is incomplete'; end if;
  if not (epas_has_role('surveyor') and e.surveyor_id=auth.uid()) then raise exception 'Only assigned Surveyor may freeze execution basis'; end if;
  gate:=epas_survey_start_gate_v27(p_rfi_id);
  if not coalesce((gate->>'ready')::boolean,false) then raise exception 'Survey start gate is not satisfied: %',gate::text; end if;
  ver:=coalesce((select max(basis_version) from survey_execution_basis_versions where execution_id=e.id),0)+1;
  pkgv:=(gate->>'drawing_package_version')::integer;
  chkver:=(gate->>'checklist_version')::integer;
  snapshot:=jsonb_build_object('rfi_id',r.id,'assignment_id',a.id,'assignment_status',a.status,'scope_version',s.current_version,
    'scope_snapshot',(select to_jsonb(sv) from survey_scope_versions sv where sv.rfi_id=r.id and sv.version_no=s.current_version),
    'drawing_package_version',pkgv,'drawing_package_fingerprint',gate->>'drawing_package_fingerprint',
    'checklist_version',chkver,'checklist_definition_fingerprint',gate->>'checklist_definition_fingerprint',
    'scope_ack_version',s.current_version,'package_ack_version',pkgv,'frozen_at',now());
  fp:=encode(digest(snapshot::text,'sha256'),'hex');
  insert into survey_execution_basis_versions(execution_id,rfi_id,basis_version,scope_version,drawing_package_version,checklist_version,assignment_id,assignment_version,package_ack_version,scope_ack_version,basis_snapshot,basis_sha256,frozen_by)
  values(e.id,r.id,ver,s.current_version,pkgv,chkver,a.id,coalesce(e.assignment_version,1),pkgv,s.current_version,snapshot,fp,auth.uid()) returning * into b;
  update survey_executions set execution_basis_version=ver,basis_sha256=fp,basis_frozen_at=now(),scope_version=s.current_version,drawing_package_version=pkgv,checklist_version=chkver,scope_version_sha256=encode(digest(coalesce(s.scope_text,''),'sha256'),'hex'),drawing_package_fingerprint=gate->>'drawing_package_fingerprint',checklist_definition_sha256=gate->>'checklist_definition_fingerprint',updated_at=now() where id=e.id;
  return b;
end;$$;
grant execute on function epas_freeze_survey_execution_basis_v27(uuid) to authenticated;

-- ================================================================
-- 8. Recurring schedule engine — service role only, explicit basis
-- ================================================================
revoke all on function epas_sync_survey_schedule_v26(uuid) from authenticated;
revoke all on function epas_refresh_vessel_survey_status_v26(uuid) from authenticated;
grant execute on function epas_sync_survey_schedule_v26(uuid) to service_role;
grant execute on function epas_refresh_vessel_survey_status_v26(uuid) to service_role;

create or replace function epas_sync_survey_schedule_v27(p_vessel_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; s survey_schedules; c certificates; due date; base_date date; interval_m integer; current_rfi uuid; completed_date date; cert_id uuid; basis text; basis_ref text;
begin
  if current_user<>'service_role' then raise exception 'Only service role may synchronize survey schedules'; end if;
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v.project_id;
  if not ('in_service'=any(coalesce(p.phases,'{}'::text[]))) then return null; end if;
  select * into s from survey_schedules where vessel_id=v.id and phase='in_service' and active for update;
  if s.id is null then
    select * into c from certificates where vessel_id=v.id and status in ('active','expiring') order by expiry_date desc limit 1;
    if c.id is null then return null; end if;
    insert into survey_schedules(vessel_id,project_id,survey_type,phase,interval_months,survey_interval_months,last_completed_date,next_due_date,window_start,window_end,status,source_certificate_id,source_rfi_id,due_basis,due_basis_reference,due_window_days_before,window_days_after,cycle_number,active,schedule_config_status,schedule_basis_date,intent_action,lifecycle_state)
    values(v.id,v.project_id,'Scheduled In-Service Survey','in_service',null,null,null,c.expiry_date,(c.expiry_date-interval '90 days')::date,(c.expiry_date+interval '30 days')::date,'SCHEDULED',c.id,null,'CERTIFICATE_EXPIRY',c.cert_number,90,30,1,true,'CONFIGURATION_REQUIRED',c.expiry_date,'CONFIGURE_SCHEDULE','ACTIVE')
    returning * into s;
    insert into survey_schedule_events(schedule_id,event_type,new_status,note,metadata) values(s.id,'SCHEDULE_CREATED','SCHEDULED','Initial schedule created; explicit basis configuration is required before an In-Service RFI can be initiated',jsonb_build_object('basis','CERTIFICATE_EXPIRY','basis_reference',c.cert_number));
    return s;
  end if;

  if s.current_rfi_id is not null and exists(select 1 from rfis r where r.id=s.current_rfi_id and r.status in ('certificate_issued','closed')) then
    select max(coalesce(e.completed_at,sr.submitted_at)::date) into completed_date from survey_executions e left join survey_reports sr on sr.rfi_id=e.rfi_id where e.rfi_id=s.current_rfi_id;
    if completed_date is null then completed_date:=s.last_completed_date; end if;
    if s.survey_interval_months is null or s.survey_interval_months<=0 then
      update survey_schedules set schedule_config_status='CONFIGURATION_REQUIRED',status='COMPLETED',lifecycle_state='ACTIVE',last_completed_date=completed_date,last_survey_completed_at=coalesce(last_survey_completed_at,now()),current_rfi_id=null,cycle_completed_at=now(),intent_action='CONFIGURE_SCHEDULE',updated_at=now() where id=s.id returning * into s;
      return s;
    end if;
    due:=(completed_date + make_interval(months=>s.survey_interval_months))::date;
    update survey_schedules set last_completed_date=completed_date,last_survey_completed_at=now(),next_due_date=due,window_start=(due-due_window_days_before)::date,window_end=(due+window_days_after)::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=s.current_rfi_id,cycle_completed_at=now(),cycle_number=cycle_number+1,lifecycle_state='ACTIVE',intent_action='CREATE_IN_SERVICE_RFI',updated_at=now() where id=s.id returning * into s;
    insert into survey_schedule_events(schedule_id,event_type,old_status,new_status,note,metadata) values(s.id,'CYCLE_COMPLETED','RFI_OPEN','SCHEDULED','Completed In-Service cycle; next cycle created without closing In-Service phase',jsonb_build_object('cycle_number',s.cycle_number,'next_due_date',s.next_due_date,'completed_date',completed_date));
  end if;

  if s.current_rfi_id is null then
    select r.id into current_rfi from rfis r where r.project_id=s.project_id and r.vessel_id=s.vessel_id and r.phase='in_service' and r.status not in ('certificate_issued','closed') order by r.created_at desc limit 1;
    if current_rfi is not null then
      update survey_schedules set current_rfi_id=current_rfi,status='RFI_OPEN',intent_action='RFI_OPEN',current_cycle_started_at=coalesce(current_cycle_started_at,now()),updated_at=now() where id=s.id returning * into s;
    end if;
  end if;

  if s.schedule_config_status<>'CONFIGURED' or s.survey_interval_months is null or s.due_basis is null or s.due_basis_reference is null then
    update survey_schedules set schedule_config_status='CONFIGURATION_REQUIRED',status=case when current_rfi_id is not null then 'RFI_OPEN' else 'SUSPENDED' end,intent_action=case when current_rfi_id is not null then 'RFI_OPEN' else 'CONFIGURE_SCHEDULE' end,lifecycle_state='ACTIVE',updated_at=now() where id=s.id returning * into s;
    return s;
  end if;

  update survey_schedules set status=case when current_rfi_id is not null then 'RFI_OPEN' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,
    window_start=(next_due_date-due_window_days_before)::date,window_end=(next_due_date+window_days_after)::date,intent_action=case when current_rfi_id is not null then 'RFI_OPEN' when next_due_date<=current_date+90 then 'CREATE_IN_SERVICE_RFI' else 'MONITOR' end,updated_at=now(),lifecycle_state='ACTIVE'
    where id=s.id returning * into s;
  return s;
end;$$;
grant execute on function epas_sync_survey_schedule_v27(uuid) to service_role;

-- Controlled human refresh is project-scoped; autonomous refresh remains service-only.
create or replace function epas_refresh_vessel_survey_status_v27(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; new_status text; old_status text; last_date date; last_phase text; next_due date; source_id uuid;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v.project_id;
  if current_user<>'service_role' and not exists(select 1 from project_members pm where pm.project_id=p.id and pm.user_id=auth.uid() and pm.active) then raise exception 'Not authorized for vessel status'; end if;
  old_status:=v.survey_status;
  select max(coalesce(sr.completed_at,sr.submitted_at)::date), (array_agg(r.phase order by coalesce(sr.completed_at,sr.submitted_at) desc nulls last))[1]
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
    insert into vessel_survey_status_history(vessel_id,project_id,status,phase,source_type,source_id,note) values(v.id,v.project_id,new_status,last_phase,'SYSTEM',source_id,'v2.7 centralized survey status engine');
  end if;
  return v;
end;$$;
grant execute on function epas_refresh_vessel_survey_status_v27(uuid) to authenticated,service_role;

-- ================================================================
-- 9. Controlled schedule basis with full traceability
-- ================================================================
create or replace function epas_set_in_service_schedule_basis_v27(
  p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,
  p_window_days_before integer,p_window_days_after integer default 30,p_basis_document_id uuid default null
) returns survey_schedules language plpgsql security definer set search_path=public as $$
declare s survey_schedules; old survey_schedules; v_project_id uuid; basis_fp text;
begin
  select project_id into v_project_id from vessels where id=p_vessel_id;
  if v_project_id is null then raise exception 'Vessel not found'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Only project GM or DM may configure the In-Service schedule'; end if;
  if p_interval_months is null or p_interval_months<=0 then raise exception 'Schedule interval must be explicitly configured and positive'; end if;
  if p_due_basis not in ('CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED') then raise exception 'Invalid schedule basis'; end if;
  if coalesce(trim(p_basis_reference),'')='' then raise exception 'Schedule basis reference is mandatory'; end if;
  select * into old from survey_schedules where vessel_id=p_vessel_id and phase='in_service' and active for update;
  if old.id is null then raise exception 'Active In-Service schedule not found'; end if;
  basis_fp:=encode(digest(p_due_basis||'|'||p_basis_reference||'|'||p_interval_months::text,'sha256'),'hex');
  insert into survey_schedule_basis_history(schedule_id,old_interval_months,new_interval_months,old_due_basis,new_due_basis,old_basis_reference,new_basis_reference,changed_by,reason)
  values(old.id,old.survey_interval_months,p_interval_months,old.due_basis,p_due_basis,old.due_basis_reference,p_basis_reference,auth.uid(),'Explicit v2.7 schedule configuration');
  update survey_schedules set survey_interval_months=p_interval_months,interval_months=p_interval_months,due_basis=p_due_basis,due_basis_reference=p_basis_reference,due_window_days_before=greatest(1,p_window_days_before),window_days_after=greatest(1,p_window_days_after),schedule_config_status='CONFIGURED',schedule_basis_document_id=p_basis_document_id,schedule_basis_approved_by=auth.uid(),schedule_basis_approved_at=now(),schedule_basis_sha256=basis_fp,configured_by=auth.uid(),configured_at=now(),window_start=(next_due_date-greatest(1,p_window_days_before))::date,window_end=(next_due_date+greatest(1,p_window_days_after))::date,intent_action=case when next_due_date<=current_date+90 then 'CREATE_IN_SERVICE_RFI' else 'MONITOR' end,updated_at=now() where id=old.id returning * into s;
  perform epas_audit(v_project_id,'IN_SERVICE_SCHEDULE_CONFIGURED','vessel',p_vessel_id,'schedule','CONFIGURED','Explicit schedule basis configured',jsonb_build_object('interval_months',p_interval_months,'due_basis',p_due_basis,'basis_reference',p_basis_reference,'basis_sha256',basis_fp));
  return s;
end;$$;
grant execute on function epas_set_in_service_schedule_basis_v27(uuid,integer,text,text,integer,integer,uuid) to authenticated;

-- ================================================================
-- 10. Cycle completion is role-scoped; next cycle is always ACTIVE
-- ================================================================
revoke all on function epas_mark_in_service_cycle_complete(uuid) from authenticated;
create or replace function epas_mark_in_service_cycle_complete_v27(p_rfi_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_schedules; e survey_executions; due date; base_date date;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null or r.phase<>'in_service' then raise exception 'RFI is not an In-Service survey'; end if;
  if current_user<>'service_role' and not exists(select 1 from project_members pm where pm.project_id=r.project_id and pm.user_id=auth.uid() and pm.active and pm.role in ('gm','dm')) then raise exception 'Only project GM/DM or service role may complete an In-Service cycle'; end if;
  select * into s from survey_schedules where vessel_id=r.vessel_id and phase='in_service' and active for update;
  select * into e from survey_executions where rfi_id=r.id;
  if s.id is null then raise exception 'Active In-Service schedule not found'; end if;
  if s.survey_interval_months is null or s.survey_interval_months<=0 then raise exception 'Configure an explicit survey interval before cycle completion'; end if;
  base_date:=coalesce((e.completed_at at time zone 'UTC')::date,(select max(coalesce(completed_at,submitted_at))::date from survey_reports where rfi_id=r.id),current_date);
  due:=(base_date+make_interval(months=>s.survey_interval_months))::date;
  update survey_schedules set last_completed_date=base_date,last_survey_completed_at=coalesce(last_survey_completed_at,now()),next_due_date=due,window_start=(due-due_window_days_before)::date,window_end=(due+window_days_after)::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=r.id,cycle_completed_at=now(),cycle_number=cycle_number+1,lifecycle_state='ACTIVE',intent_action='CREATE_IN_SERVICE_RFI',updated_at=now() where id=s.id returning * into s;
  perform epas_refresh_project_phase_state(r.project_id);
  perform epas_refresh_vessel_survey_status_v27(r.vessel_id);
  perform epas_audit(r.project_id,'IN_SERVICE_CYCLE_COMPLETED','rfi',r.id,'system','SCHEDULED','In-Service cycle completed; persistent In-Service phase remains active',jsonb_build_object('schedule_id',s.id,'cycle_number',s.cycle_number,'next_due_date',s.next_due_date,'base_date',base_date,'phase_lifecycle','ACTIVE'));
  return s;
end;$$;
grant execute on function epas_mark_in_service_cycle_complete_v27(uuid) to authenticated,service_role;

-- ================================================================
-- 11. Service-role scheduler tick + scheduler history
-- ================================================================
create or replace function epas_scheduler_tick_v27()
returns jsonb language plpgsql security definer set search_path=public as $$
declare run_id uuid; v record; s_count integer:=0; status_count integer:=0; notify_count integer:=0; started_at timestamptz:=now(); err_count integer:=0;
begin
  if current_user<>'service_role' then raise exception 'Service role required'; end if;
  insert into scheduler_runs(run_type,status,started_at,metadata) values('EPAS_SURVEY_LIFECYCLE_V27','RUNNING',started_at,jsonb_build_object('version','2.7')) returning id into run_id;
  for v in select id,project_id from vessels loop
    begin perform epas_sync_survey_schedule_v27(v.id); s_count:=s_count+1; exception when others then err_count:=err_count+1; end;
    begin perform epas_refresh_vessel_survey_status_v27(v.id); status_count:=status_count+1; exception when others then err_count:=err_count+1; end;
  end loop;
  begin
    notify_count:=epas_generate_survey_due_notifications_v26();
  exception when others then
    notify_count:=0; err_count:=err_count+1;
  end;
  update scheduler_runs set status=case when err_count=0 then 'SUCCEEDED' else 'SUCCEEDED_WITH_ERRORS' end,finished_at=now(),items_processed=s_count,metadata=jsonb_build_object('version','2.7','schedules_processed',s_count,'vessel_statuses_processed',status_count,'notifications',notify_count,'errors',err_count) where id=run_id;
  return jsonb_build_object('run_id',run_id,'schedules_processed',s_count,'vessel_statuses_processed',status_count,'notifications',notify_count,'errors',err_count);
exception when others then
  update scheduler_runs set status='FAILED',finished_at=now(),metadata=jsonb_build_object('version','2.7','error',sqlerrm) where id=run_id;
  raise;
end;$$;
grant execute on function epas_scheduler_tick_v27() to service_role;

-- ================================================================
-- 12. Harden existing v2.6 SECURITY DEFINER lifecycle functions
-- ================================================================
revoke all on function epas_sync_survey_schedule_v26(uuid) from authenticated;
revoke all on function epas_refresh_vessel_survey_status_v26(uuid) from authenticated;
revoke all on function epas_refresh_vessel_survey_status_v26(uuid) from public;
grant execute on function epas_sync_survey_schedule_v26(uuid) to service_role;
grant execute on function epas_refresh_vessel_survey_status_v26(uuid) to service_role;

-- The legacy v2.6 function remains callable only as a system helper.
-- Human users use the project-scoped v2.7 controls instead.

-- ================================================================
-- 13. Report date semantics on the Ship Register
-- ================================================================
alter table vessels add column if not exists last_survey_completed_at timestamptz;
alter table vessels add column if not exists last_survey_report_submitted_at timestamptz;
alter table vessels add column if not exists last_certificate_issued_at timestamptz;

create or replace function epas_refresh_vessel_register_dates_v27(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels; lc timestamptz; lr timestamptz; lcert timestamptz;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  if current_user<>'service_role' and not epas_is_project_member(v.project_id) then raise exception 'Not authorized for vessel register'; end if;
  select max(e.completed_at) into lc from survey_executions e join rfis r on r.id=e.rfi_id where r.vessel_id=p_vessel_id;
  select max(sr.submitted_at) into lr from survey_reports sr join rfis r on r.id=sr.rfi_id where r.vessel_id=p_vessel_id;
  select max(c.issue_date::timestamptz) into lcert from certificates c where c.vessel_id=p_vessel_id and c.status in ('active','expiring');
  update vessels set last_survey_completed_at=lc,last_survey_report_submitted_at=lr,last_certificate_issued_at=lcert where id=p_vessel_id returning * into v;
  return v;
end;$$;
grant execute on function epas_refresh_vessel_register_dates_v27(uuid) to authenticated,service_role;

-- ================================================================
-- 14. Stronger phase-aware stakeholder schedule creation
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
  if s.schedule_config_status<>'CONFIGURED' then raise exception 'Schedule is not configured. GM/DM must approve survey interval and schedule basis first'; end if;
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
  values(r.id,p_scope_note,p_survey_type,'in_service','SUBMITTED',1)
  on conflict(rfi_id) do update set scope_text=excluded.scope_text,survey_type=excluded.survey_type,updated_at=now();
  update survey_schedules set current_rfi_id=r.id,source_rfi_id=r.id,status='RFI_OPEN',current_cycle_started_at=now(),intent_action='RFI_OPEN',updated_at=now() where id=s.id;
  perform epas_audit(r.project_id,'IN_SERVICE_RFI_INITIATED_FROM_SCHEDULE','rfi',r.id,v_role,'pending_allocation','Guided In-Service RFI created for scheduled cycle',jsonb_build_object('schedule_id',s.id,'cycle_number',s.cycle_number,'next_due_date',s.next_due_date));
  return r;
end;$$;
grant execute on function epas_stakeholder_create_scheduled_in_service_rfi(uuid,text,date,text,text) to authenticated;

-- ================================================================
-- 15. Security-definer read/write helper guards
-- ================================================================
create or replace function epas_sync_survey_schedule_v27_safe(p_vessel_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare v_project_id uuid; s survey_schedules;
begin
  select project_id into v_project_id from vessels where id=p_vessel_id;
  if v_project_id is null then raise exception 'Vessel not found'; end if;
  if not epas_is_project_member(v_project_id) then raise exception 'Not authorized for vessel schedule'; end if;
  -- Human users receive a read-safe refresh by project membership, while the actual autonomous scheduler remains service-role only.
  s:=null;
  select * into s from survey_schedules where vessel_id=p_vessel_id and active and phase='in_service';
  return s;
end;$$;
grant execute on function epas_sync_survey_schedule_v27_safe(uuid) to authenticated;

-- ================================================================
-- 16. Package/scope dependency checks for amendment and reissue
-- ================================================================
create or replace function epas_survey_dependency_status_v27(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r rfis; s survey_scopes; e survey_executions; pkgver integer; chkver integer;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  pkgver:=coalesce((select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),0);
  chkver:=coalesce((select max(checklist_version) from survey_checklist_items where rfi_id=r.id),0);
  return jsonb_build_object(
    'rfi_id',r.id,
    'scope_version',coalesce(s.current_version,1),
    'scope_acknowledged',exists(select 1 from survey_scope_acknowledgements a where a.rfi_id=r.id and a.scope_version=coalesce(s.current_version,1) and a.acknowledged_by=r.assigned_surveyor_id),
    'drawing_package_version',pkgver,
    'drawing_package_acknowledged',exists(select 1 from survey_drawing_package_acknowledgements a where a.rfi_id=r.id and a.package_version=pkgver and a.acknowledged_by=r.assigned_surveyor_id),
    'checklist_version',chkver,
    'execution_basis_frozen',e.basis_frozen_at is not null,
    'execution_basis_version',e.execution_basis_version,
    'ready_to_start',e.id is not null and exists(select 1 from survey_scope_acknowledgements a where a.rfi_id=r.id and a.scope_version=coalesce(s.current_version,1) and a.acknowledged_by=r.assigned_surveyor_id) and e.basis_frozen_at is not null
  );
end;$$;
grant execute on function epas_survey_dependency_status_v27(uuid) to authenticated;

-- ================================================================
-- 17. Final notification policy: no stakeholder phase leakage
-- ================================================================
create table if not exists survey_notification_policy_v27(
  phase text not null,
  role_name text not null,
  allowed boolean not null default false,
  primary key(phase,role_name)
);
insert into survey_notification_policy_v27(phase,role_name,allowed) values
('nsc_survey','gm',true),('nsc_survey','dm',true),('nsc_survey','shipyard',true),('nsc_survey','surveyor',true),
('in_service','gm',true),('in_service','dm',true),('in_service','owner',true),('in_service','ship_management',true),('in_service','surveyor',true)
on conflict(phase,role_name) do update set allowed=excluded.allowed;

-- ================================================================
-- 18. Operational acceptance matrix v2.7
-- ================================================================
create table if not exists workflow_acceptance_cases_v27(
  case_code text primary key,
  role_name text not null,
  phase text,
  expected_result text not null,
  negative boolean not null default false,
  priority text not null default 'P1',
  created_at timestamptz not null default now()
);
insert into workflow_acceptance_cases_v27(case_code,role_name,phase,expected_result,negative,priority) values
('V27_IN_SERVICE_CYCLE_2','system','in_service','Completing cycle 1 leaves project In-Service phase ACTIVE and allows cycle 2',false,'P0'),
('V27_SERVICE_SYNC_LOCK','owner','in_service','Owner cannot directly invoke service-role schedule synchronization',true,'P0'),
('V27_STATUS_SCOPE_GUARD','owner','in_service','Owner cannot modify another project vessel status',true,'P0'),
('V27_CYCLE_COMPLETE_AUTH','owner','in_service','Owner cannot mark an In-Service cycle complete',true,'P0'),
('V27_PACKAGE_FINGERPRINT','surveyor','in_service','Surveyor acknowledges exact package version and fingerprint',false,'P1'),
('V27_SCOPE_CASCADE','surveyor','in_service','Scope amendment invalidates previous scope/package/checklist/execution basis',false,'P0'),
('V27_SCHEDULE_BASIS','dm','in_service','Explicit interval and basis reference are mandatory',false,'P0'),
('V27_SCHEDULER','system','in_service','Only service role executes autonomous scheduler',false,'P0'),
('V27_NOTIFICATION_BOUNDARY','shipyard','in_service','Shipyard receives no In-Service schedule notification',true,'P0'),
('V27_STREAMLIT_ROLE_SURFACE','all',null,'All eight roles can be rendered by the Streamlit application without an actor selector',false,'P1')
on conflict(case_code) do update set expected_result=excluded.expected_result,negative=excluded.negative,priority=excluded.priority,role_name=excluded.role_name,phase=excluded.phase;


-- ================================================================
-- 19. v2.7 authoritative survey start + submission gates
-- ================================================================
create or replace function epas_start_survey_execution_v27(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
declare r rfis; a survey_assignments; e survey_executions; g jsonb;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may start survey execution'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  select * into a from survey_assignments where rfi_id=p_rfi_id for update;
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  if r.id is null or a.id is null or e.id is null then raise exception 'Controlled survey execution context is incomplete'; end if;
  if r.assigned_surveyor_id<>auth.uid() or a.surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  g:=epas_survey_start_gate_v27(p_rfi_id);
  if not coalesce((g->>'ready')::boolean,false) then raise exception 'Survey start gate failed: %',g::text; end if;
  perform epas_freeze_survey_execution_basis_v27(p_rfi_id);
  update survey_executions set status='IN_PROGRESS',started_at=coalesce(started_at,now()),started_by=auth.uid(),updated_at=now() where id=e.id returning * into e;
  update survey_assignments set status='IN_PROGRESS' where id=a.id;
  return e;
end;$$;
grant execute on function epas_start_survey_execution_v27(uuid) to authenticated;

create or replace function epas_survey_submission_gate_v27(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r rfis; e survey_executions; d survey_execution_declarations; g jsonb;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into d from survey_execution_declarations where execution_id=e.id;
  if r.id is null or e.id is null then raise exception 'Survey execution not found'; end if;
  g:=epas_survey_start_gate_v27(p_rfi_id);
  return g || jsonb_build_object(
    'basis_frozen',e.basis_frozen_at is not null,
    'execution_basis_version',e.execution_basis_version,
    'basis_sha256',e.basis_sha256,
    'declaration_complete',d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete,
    'ready_to_submit',coalesce((g->>'ready')::boolean,false) and e.basis_frozen_at is not null and d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete
  );
end;$$;
grant execute on function epas_survey_submission_gate_v27(uuid) to authenticated;

create or replace function epas_guard_survey_report_submit()
returns trigger language plpgsql security definer set search_path=public as $$
declare g jsonb; r rfis; e survey_executions;
begin
  select * into r from rfis where id=new.rfi_id;
  select * into e from survey_executions where rfi_id=new.rfi_id;
  if r.id is null or e.id is null then raise exception 'Controlled survey execution is required'; end if;
  if new.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey report must be submitted by assigned Surveyor'; end if;
  g:=epas_survey_submission_gate_v27(new.rfi_id);
  if not coalesce((g->>'ready_to_submit')::boolean,false) then raise exception 'Survey report submission gate failed: %',g::text; end if;
  return new;
end;$$;
drop trigger if exists trg_epas_guard_survey_report_submit on survey_reports;
create trigger trg_epas_guard_survey_report_submit before insert or update on survey_reports for each row execute function epas_guard_survey_report_submit();

-- ================================================================
-- 20. Final lifecycle status view for the Streamlit control tower
-- ================================================================
drop view if exists survey_control_tower_v27;
create view survey_control_tower_v27 as
select
  s.id as schedule_id,
  s.project_id,
  s.vessel_id,
  v.name as vessel_name,
  s.phase,
  s.survey_type,
  s.cycle_number,
  s.lifecycle_state,
  s.next_due_date,
  s.window_start,
  s.window_end,
  s.status,
  s.schedule_config_status,
  s.due_basis,
  s.due_basis_reference,
  s.survey_interval_months,
  s.current_rfi_id,
  r.rfi_code,
  r.status as rfi_status,
  r.assigned_surveyor_id,
  p.full_name as surveyor_name
from survey_schedules s
join vessels v on v.id=s.vessel_id
left join rfis r on r.id=s.current_rfi_id
left join profiles p on p.id=r.assigned_surveyor_id
where s.active;

-- RLS on the operational view itself is not available for ordinary views;
-- access is therefore through the project-scoped RPC below.
create or replace function epas_survey_control_tower_v27(p_project_id uuid default null)
returns table(schedule_id uuid,project_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,cycle_number integer,lifecycle_state text,next_due_date date,window_start date,window_end date,status text,schedule_config_status text,due_basis text,due_basis_reference text,survey_interval_months integer,current_rfi_id uuid,rfi_code text,rfi_status text,assigned_surveyor_id uuid,surveyor_name text)
language plpgsql security definer set search_path=public stable as $$
begin
  if p_project_id is not null and not epas_is_project_member(p_project_id) then raise exception 'Not authorized for survey control tower'; end if;
  if p_project_id is null and not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Global survey control tower requires GM or DM'; end if;
  return query
  select v.schedule_id,v.project_id,v.vessel_id,v.vessel_name,v.phase,v.survey_type,v.cycle_number,v.lifecycle_state,v.next_due_date,v.window_start,v.window_end,v.status,v.schedule_config_status,v.due_basis,v.due_basis_reference,v.survey_interval_months,v.current_rfi_id,v.rfi_code,v.rfi_status,v.assigned_surveyor_id,v.surveyor_name
  from survey_control_tower_v27 v
  where p_project_id is null or v.project_id=p_project_id
  order by v.next_due_date;
end;$$;
grant execute on function epas_survey_control_tower_v27(uuid) to authenticated;

commit;
