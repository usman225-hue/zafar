-- EPAS v2.6 — Final Workflow Acceptance & Production Hardening
-- Cumulative after v2.5.
-- Purpose: close the remaining 23 workflow/security/operational gaps identified
-- during the v2.5 audit.
--
-- Authoritative stakeholder RFI policy remains:
--   Shipyard -> NSC only
--   Owner -> In-Service only
--   Ship Management -> In-Service only
--
-- Final workflow target:
-- Shipyard may initiate NSC Survey RFI; Shipyard may not initiate In-Service RFI.
-- Owner may initiate In-Service RFI; Owner may not initiate NSC RFI.
-- Ship Management may initiate In-Service RFI; Ship Management may not initiate NSC RFI.
--   Project scope -> Plan Appraisal -> Approved drawings -> Survey phase -> RFI ->
--   versioned scope -> DM allocation -> Surveyor acceptance -> immutable drawing
--   package -> package acknowledgement -> pre-survey checklist -> scope ack ->
--   revision impact -> survey execution -> structured declaration/report ->
--   observations -> exact corrective actions -> evidence -> verification ->
--   frozen certificate decision package -> DM acknowledgement -> certificate ->
--   Ship Register -> recurring In-Service schedule -> guided next RFI.

begin;

create extension if not exists pgcrypto;

-- ================================================================
-- 1. Drawing revision-impact decision history + exact comparison snapshot
-- ================================================================
create table if not exists survey_drawing_impact_decision_history (
  id uuid primary key default gen_random_uuid(),
  decision_id uuid references survey_drawing_impact_decisions(id) on delete set null,
  rfi_id uuid not null references rfis(id) on delete cascade,
  package_id uuid not null references survey_rfi_drawings(id) on delete cascade,
  package_version integer not null,
  shared_revision integer,
  shared_sha256 text,
  current_revision integer,
  current_sha256 text,
  impact text not null,
  note text not null,
  decided_by uuid references profiles(id),
  decided_at timestamptz not null default now(),
  comparison_snapshot jsonb not null default '{}'::jsonb
);
create index if not exists idx_survey_drawing_impact_history_package
  on survey_drawing_impact_decision_history(package_id, decided_at desc);

alter table survey_drawing_impact_decisions add column if not exists package_version integer;
alter table survey_drawing_impact_decisions add column if not exists shared_revision integer;
alter table survey_drawing_impact_decisions add column if not exists shared_sha256 text;
alter table survey_drawing_impact_decisions add column if not exists current_revision integer;
alter table survey_drawing_impact_decisions add column if not exists current_sha256 text;
alter table survey_drawing_impact_decisions add column if not exists comparison_snapshot jsonb not null default '{}'::jsonb;

create or replace function epas_dm_decide_drawing_revision_impact(
  p_package_id uuid,p_impact text,p_note text
) returns survey_drawing_impact_decisions
language plpgsql security definer set search_path=public as $$
declare
  s survey_rfi_drawings;
  r rfis;
  d survey_drawing_impact_decisions;
  current_revision integer;
  current_sha text;
  same_file boolean;
  snapshot jsonb;
  v_pkg integer;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide drawing revision impact'; end if;
  if p_impact not in ('NO_IMPACT','REISSUE_REQUIRED','NOT_APPLICABLE') then raise exception 'Invalid impact decision'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Decision note is required'; end if;

  select * into s from survey_rfi_drawings where id=p_package_id for update;
  if s.id is null then raise exception 'Drawing package not found'; end if;
  select * into r from rfis where id=s.rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only the assigned DM may decide this package impact'; end if;

  select d.revision,doc.sha256 into current_revision,current_sha
  from plan_drawings d join documents doc on doc.id=d.document_id
  where d.id=s.drawing_id;

  same_file := s.shared_revision=current_revision and coalesce(s.shared_sha256,'')=coalesce(current_sha,'');
  if same_file and p_impact='REISSUE_REQUIRED' then
    raise exception 'REISSUE_REQUIRED is invalid because revision and SHA-256 are unchanged';
  end if;
  if not same_file and p_impact='NOT_APPLICABLE' then
    raise exception 'NOT_APPLICABLE is invalid because the approved drawing revision/hash changed';
  end if;

  v_pkg := coalesce(s.package_version,1);
  snapshot := jsonb_build_object(
    'package_id',s.id,
    'package_version',v_pkg,
    'shared_drawing_no',s.shared_drawing_no,
    'shared_title',s.shared_title,
    'shared_discipline',s.shared_discipline,
    'shared_revision',s.shared_revision,
    'shared_document_id',s.shared_document_id,
    'shared_file_name',s.shared_file_name,
    'shared_storage_path',s.shared_storage_path,
    'shared_sha256',s.shared_sha256,
    'shared_mime_type',s.shared_mime_type,
    'shared_size_bytes',s.shared_size_bytes,
    'current_revision',current_revision,
    'current_sha256',current_sha,
    'comparison_equal',same_file,
    'decision',p_impact
  );

  insert into survey_drawing_impact_decisions(
    rfi_id,package_id,impact,note,decided_by,decided_at,package_version,
    shared_revision,shared_sha256,current_revision,current_sha256,comparison_snapshot
  ) values(
    r.id,s.id,p_impact,p_note,auth.uid(),now(),v_pkg,
    s.shared_revision,s.shared_sha256,current_revision,current_sha,snapshot
  )
  on conflict(package_id) do update set
    impact=excluded.impact,
    note=excluded.note,
    decided_by=excluded.decided_by,
    decided_at=excluded.decided_at,
    package_version=excluded.package_version,
    shared_revision=excluded.shared_revision,
    shared_sha256=excluded.shared_sha256,
    current_revision=excluded.current_revision,
    current_sha256=excluded.current_sha256,
    comparison_snapshot=excluded.comparison_snapshot
  returning * into d;

  insert into survey_drawing_impact_decision_history(
    decision_id,rfi_id,package_id,package_version,shared_revision,shared_sha256,
    current_revision,current_sha256,impact,note,decided_by,decided_at,comparison_snapshot
  ) values(
    d.id,r.id,s.id,v_pkg,s.shared_revision,s.shared_sha256,current_revision,current_sha,
    p_impact,p_note,auth.uid(),now(),snapshot
  );

  perform epas_audit(r.project_id,'SURVEY_DRAWING_IMPACT_DECIDED','rfi',r.id,'dm',p_impact,
    p_note,jsonb_build_object('package_id',s.id,'package_version',v_pkg,'comparison_snapshot',snapshot));
  return d;
end;$$;
grant execute on function epas_dm_decide_drawing_revision_impact(uuid,text,text) to authenticated;

-- Prevent mutation of the frozen file identity / metadata by direct SQL/RLS paths.
create or replace function epas_guard_survey_drawing_snapshot_update()
returns trigger language plpgsql as $$
begin
  if old.shared_revision is distinct from new.shared_revision
     or old.shared_document_id is distinct from new.shared_document_id
     or old.shared_file_name is distinct from new.shared_file_name
     or old.shared_storage_path is distinct from new.shared_storage_path
     or old.shared_sha256 is distinct from new.shared_sha256
     or old.shared_mime_type is distinct from new.shared_mime_type
     or old.shared_size_bytes is distinct from new.shared_size_bytes
     or old.shared_drawing_no is distinct from new.shared_drawing_no
     or old.shared_title is distinct from new.shared_title
     or old.shared_discipline is distinct from new.shared_discipline
  then
    raise exception 'Immutable survey drawing handover snapshot cannot be modified; create a new package version';
  end if;
  return new;
end;$$;
drop trigger if exists trg_guard_survey_drawing_snapshot on survey_rfi_drawings;
create trigger trg_guard_survey_drawing_snapshot
before update on survey_rfi_drawings
for each row execute function epas_guard_survey_drawing_snapshot_update();

-- ================================================================
-- 2. Exact execution-basis versions + immutable fingerprint
-- ================================================================
create table if not exists survey_execution_basis_versions (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null references survey_executions(id) on delete cascade,
  rfi_id uuid not null references rfis(id) on delete cascade,
  basis_version integer not null,
  scope_version integer not null,
  drawing_package_version integer,
  checklist_version integer,
  assignment_id uuid references survey_assignments(id),
  assignment_version integer not null default 1,
  package_ack_version integer,
  scope_ack_version integer,
  basis_snapshot jsonb not null,
  basis_sha256 text not null,
  frozen_by uuid not null references profiles(id),
  frozen_at timestamptz not null default now(),
  unique(execution_id,basis_version)
);
create index if not exists idx_survey_execution_basis_versions_exec
  on survey_execution_basis_versions(execution_id,basis_version desc);

alter table survey_executions add column if not exists execution_basis_version integer;
alter table survey_executions add column if not exists basis_sha256 text;
alter table survey_executions add column if not exists basis_frozen_at timestamptz;
alter table survey_executions add column if not exists scope_acknowledged_at timestamptz;
alter table survey_executions add column if not exists scope_acknowledged_version integer;
alter table survey_executions add column if not exists drawing_package_ack_version integer;
alter table survey_executions add column if not exists assignment_version integer not null default 1;

-- ================================================================
-- 3. Scope acknowledgement + amendment cascade
-- ================================================================
create table if not exists survey_scope_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  scope_version integer not null,
  acknowledged_by uuid not null references profiles(id),
  acknowledged_role text not null,
  acknowledged_at timestamptz not null default now(),
  note text,
  unique(rfi_id,scope_version,acknowledged_by)
);
create index if not exists idx_scope_ack_rfi on survey_scope_acknowledgements(rfi_id,scope_version desc);

alter table survey_scope_amendments add column if not exists previous_scope_version integer;
alter table survey_scope_amendments add column if not exists approved_scope_version integer;

create or replace function epas_acknowledge_survey_scope(p_rfi_id uuid,p_note text default null)
returns survey_scope_acknowledgements
language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_scopes; a survey_scope_acknowledgements; role_name text;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  select * into s from survey_scopes where rfi_id=r.id;
  if s.id is null then raise exception 'Survey scope not found'; end if;
  select role into role_name from profiles where id=auth.uid();
  if role_name<>'surveyor' then raise exception 'Only assigned Surveyor may acknowledge survey scope'; end if;
  if r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  insert into survey_scope_acknowledgements(rfi_id,scope_version,acknowledged_by,acknowledged_role,note)
  values(r.id,s.current_version,auth.uid(),role_name,p_note)
  on conflict(rfi_id,scope_version,acknowledged_by) do update set acknowledged_at=now(),note=excluded.note
  returning * into a;
  update survey_executions set scope_acknowledged_at=a.acknowledged_at,scope_acknowledged_version=a.scope_version,updated_at=now()
  where rfi_id=r.id and surveyor_id=auth.uid();
  perform epas_audit(r.project_id,'SURVEY_SCOPE_ACKNOWLEDGED','rfi',r.id,'surveyor','ACKNOWLEDGED',coalesce(p_note,''),jsonb_build_object('scope_version',s.current_version));
  return a;
end;$$;
grant execute on function epas_acknowledge_survey_scope(uuid,text) to authenticated;

create or replace function epas_dm_decide_rfi_scope_amendment(p_amendment_id uuid,p_approve boolean,p_note text)
returns survey_scope_amendments language plpgsql security definer set search_path=public as $$
declare a survey_scope_amendments; r rfis; s survey_scopes; next_ver integer; old_ver integer;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide scope amendments'; end if;
  select * into a from survey_scope_amendments where id=p_amendment_id for update;
  if a.id is null then raise exception 'Amendment not found'; end if;
  if a.status<>'PENDING' then raise exception 'Amendment already decided'; end if;
  select * into r from rfis where id=a.rfi_id for update;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may decide this amendment'; end if;
  select * into s from survey_scopes where rfi_id=r.id for update;
  if s.id is null then raise exception 'Survey scope not found'; end if;
  old_ver:=coalesce(s.current_version,s.scope_version,1);
  update survey_scope_amendments set previous_scope_version=old_ver where id=a.id;
  if p_approve then
    next_ver:=old_ver+1;
    insert into survey_scope_versions(rfi_id,version_no,scope_text,survey_type,phase,created_by,source_amendment_id)
    values(r.id,next_ver,coalesce(nullif(a.proposed_scope,''),s.scope_text),s.survey_type,s.phase,auth.uid(),a.id);
    update survey_scopes set scope_text=coalesce(nullif(a.proposed_scope,''),scope_text),scope_version=next_ver,current_version=next_ver,status='SUBMITTED',amended_at=now(),amended_by=auth.uid(),updated_at=now()
    where rfi_id=r.id;
    update rfis set scope_note=coalesce(nullif(a.proposed_scope,''),scope_note),updated_at=now() where id=r.id;
    update survey_scope_amendments set status='APPROVED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note,approved_scope_version=next_ver where id=a.id;

    -- Scope changes invalidate any pre-existing survey basis/acceptance and require a fresh DM assignment.
    update survey_rfi_drawings set revoked_at=now(),package_state='REVOKED' where rfi_id=r.id and revoked_at is null;
    update survey_assignments set status='REASSIGNED',reassigned_at=now(),notes=coalesce(notes,'')||E'\nScope amended; reassignment required.' where rfi_id=r.id and status in ('ASSIGNED','ACCEPTED','IN_PROGRESS');
    update survey_executions set status='RETURNED',basis_frozen_at=null,execution_basis='{}'::jsonb,execution_basis_version=null,basis_sha256=null,scope_version=next_ver,drawing_package_version=null,checklist_completed_at=null,drawing_package_acknowledged_at=null,scope_acknowledged_at=null,scope_acknowledged_version=null,updated_at=now() where rfi_id=r.id and status in ('NOT_STARTED','IN_PROGRESS','RETURNED');
    update survey_scopes set status='SUBMITTED' where rfi_id=r.id;
    insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,rfi_id,created_at)
    values(r.project_id,'SURVEY_SCOPE_AMENDMENT_REASSIGNMENT',auth.uid(),r.assigned_surveyor_id,'pending','Scope version changed; DM must reassign Surveyor / rebuild controlled survey package.',r.id,now());
  else
    update survey_scopes set status='LOCKED',updated_at=now() where rfi_id=r.id;
    update survey_scope_amendments set status='REJECTED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  end if;
  select * into a from survey_scope_amendments where id=a.id;
  perform epas_audit(r.project_id,'RFI_SCOPE_AMENDMENT_DECIDED','rfi',r.id,'dm',a.status,coalesce(p_note,''),jsonb_build_object('amendment_id',a.id,'previous_scope_version',old_ver,'approved_scope_version',a.approved_scope_version));
  return a;
end;$$;
grant execute on function epas_dm_decide_rfi_scope_amendment(uuid,boolean,text) to authenticated;

-- ================================================================
-- 4. Versioned survey checklist definition + response snapshot
-- ================================================================
create table if not exists survey_checklist_definitions (
  id uuid primary key default gen_random_uuid(),
  phase text not null check (phase in ('nsc_survey','in_service')),
  checklist_version integer not null,
  title text not null,
  active boolean not null default true,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique(phase,checklist_version)
);

create table if not exists survey_checklist_definition_items (
  id uuid primary key default gen_random_uuid(),
  definition_id uuid not null references survey_checklist_definitions(id) on delete cascade,
  item_code text not null,
  category text not null,
  requirement text not null,
  mandatory boolean not null default true,
  sort_order integer not null default 0,
  unique(definition_id,item_code)
);

alter table survey_checklist_items add column if not exists definition_id uuid references survey_checklist_definitions(id);
alter table survey_checklist_items add column if not exists checklist_version integer not null default 1;

insert into survey_checklist_definitions(phase,checklist_version,title,active)
select distinct r.phase,1,upper(replace(r.phase,'_',' '))||' PRE-SURVEY CHECKLIST',true
from rfis r
where r.phase in ('nsc_survey','in_service')
on conflict(phase,checklist_version) do nothing;

insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'ACCESS_001','Access','Vessel/site access and survey attendance confirmed',true,10
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'DOC_001','Documents','Approved/current drawings and applicable documents available',true,20
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'DOC_002','Documents','Previous survey reports reviewed',case when d.phase='in_service' then true else false end,30
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'DOC_003','Documents','Maintenance / repair records reviewed',case when d.phase='in_service' then true else false end,40
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'CLASS_001','Class','Current class / certificate status reviewed',true,50
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'SAFETY_001','Safety','Required safety arrangements confirmed',true,60
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'SCOPE_001','Scope','Survey scope and requested survey type confirmed',true,70
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;
insert into survey_checklist_definition_items(definition_id,item_code,category,requirement,mandatory,sort_order)
select d.id,'CHANGE_001','Change of Class','Change-of-class requirement assessed',case when d.phase='in_service' then true else false end,80
from survey_checklist_definitions d where d.checklist_version=1
on conflict(definition_id,item_code) do nothing;

create or replace function epas_initialize_survey_checklist(p_rfi_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare r rfis; d survey_checklist_definitions; n integer:=0;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not (epas_has_role('gm') or epas_has_role('dm') or (epas_has_role('surveyor') and r.assigned_surveyor_id=auth.uid())) then
    raise exception 'Not authorized to initialize survey checklist';
  end if;
  select * into d from survey_checklist_definitions where phase=r.phase and active order by checklist_version desc limit 1;
  if d.id is null then raise exception 'No active checklist definition for survey phase'; end if;
  insert into survey_checklist_items(rfi_id,item_code,category,requirement,mandatory,status,definition_id,checklist_version)
  select r.id,i.item_code,i.category,i.requirement,i.mandatory,'pending',d.id,d.checklist_version
  from survey_checklist_definition_items i where i.definition_id=d.id
  on conflict(rfi_id,item_code) do update set definition_id=excluded.definition_id,checklist_version=excluded.checklist_version,category=excluded.category,requirement=excluded.requirement,mandatory=excluded.mandatory;
  select count(*) into n from survey_checklist_items where rfi_id=r.id;
  return n;
end;$$;
grant execute on function epas_initialize_survey_checklist(uuid) to authenticated;

-- ================================================================
-- 5. Structured surveyor declaration and final survey submission gate
-- ================================================================
create table if not exists survey_execution_declarations (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null unique references survey_executions(id) on delete cascade,
  rfi_id uuid not null references rfis(id) on delete cascade,
  surveyor_id uuid not null references profiles(id),
  scope_confirmed boolean not null,
  drawings_confirmed boolean not null,
  attendance_confirmed boolean not null,
  safety_confirmed boolean not null,
  report_complete boolean not null,
  declaration_text text not null,
  declared_at timestamptz not null default now()
);

create or replace function epas_confirm_survey_execution_declaration(
  p_rfi_id uuid,p_scope_confirmed boolean,p_drawings_confirmed boolean,
  p_attendance_confirmed boolean,p_safety_confirmed boolean,p_report_complete boolean,p_declaration_text text
) returns survey_execution_declarations
language plpgsql security definer set search_path=public as $$
declare e survey_executions; r rfis; d survey_execution_declarations;
begin
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  select * into r from rfis where id=p_rfi_id;
  if e.id is null or r.id is null then raise exception 'Survey execution not found'; end if;
  if e.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Only assigned Surveyor may submit declaration'; end if;
  if not p_scope_confirmed or not p_drawings_confirmed or not p_attendance_confirmed or not p_safety_confirmed or not p_report_complete then
    raise exception 'All professional survey declarations must be confirmed';
  end if;
  if coalesce(trim(p_declaration_text),'')='' then raise exception 'Surveyor declaration text is required'; end if;
  insert into survey_execution_declarations(execution_id,rfi_id,surveyor_id,scope_confirmed,drawings_confirmed,attendance_confirmed,safety_confirmed,report_complete,declaration_text)
  values(e.id,r.id,auth.uid(),p_scope_confirmed,p_drawings_confirmed,p_attendance_confirmed,p_safety_confirmed,p_report_complete,p_declaration_text)
  on conflict(execution_id) do update set scope_confirmed=excluded.scope_confirmed,drawings_confirmed=excluded.drawings_confirmed,attendance_confirmed=excluded.attendance_confirmed,safety_confirmed=excluded.safety_confirmed,report_complete=excluded.report_complete,declaration_text=excluded.declaration_text,declared_at=now()
  returning * into d;
  update survey_executions set declaration=d.declaration_text,updated_at=now() where id=e.id;
  return d;
end;$$;
grant execute on function epas_confirm_survey_execution_declaration(uuid,boolean,boolean,boolean,boolean,boolean,text) to authenticated;

-- ================================================================
-- 6. Assignment versioning / acceptance / package ack identity
-- ================================================================
alter table survey_assignments add column if not exists assignment_version integer not null default 1;
alter table survey_assignments add column if not exists acceptance_note text;
alter table survey_rfi_drawings add column if not exists package_fingerprint text;
alter table survey_rfi_drawings add column if not exists package_ack_version integer;

update survey_rfi_drawings
set package_fingerprint=encode(digest(coalesce(shared_drawing_no,'')||'|'||coalesce(shared_title,'')||'|'||coalesce(shared_discipline,'')||'|'||coalesce(shared_revision::text,'')||'|'||coalesce(shared_document_id::text,'')||'|'||coalesce(shared_file_name,'')||'|'||coalesce(shared_storage_path,'')||'|'||coalesce(shared_sha256,'')||'|'||coalesce(shared_mime_type,'')||'|'||coalesce(shared_size_bytes::text,''),'sha256'),'hex')
where package_fingerprint is null;

drop function if exists epas_acknowledge_survey_drawing_package(uuid);
create function epas_acknowledge_survey_drawing_package(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; n integer; max_ver integer; package_hash text;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may acknowledge a drawing package'; end if;
  select * into r from rfis where id=p_rfi_id;
  if r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  select max(package_version) into max_ver from survey_rfi_drawings where rfi_id=r.id and surveyor_id=auth.uid() and revoked_at is null;
  if max_ver is null then raise exception 'No active drawing package is assigned to this Surveyor'; end if;
  select encode(digest(coalesce(string_agg(coalesce(package_fingerprint,''), '|' order by id),''),'sha256'),'hex')
  into package_hash from survey_rfi_drawings where rfi_id=r.id and surveyor_id=auth.uid() and revoked_at is null;
  update survey_rfi_drawings set handover_acknowledged_at=now(),handover_acknowledged_by=auth.uid(),package_ack_version=max_ver
  where rfi_id=r.id and surveyor_id=auth.uid() and revoked_at is null;
  get diagnostics n=row_count;
  select * into e from survey_executions where rfi_id=r.id for update;
  if e.id is not null then
    update survey_executions set drawing_package_acknowledged_at=now(),drawing_package_ack_version=max_ver,updated_at=now() where id=e.id;
  end if;
  insert into survey_drawing_handover_events(package_id,rfi_id,surveyor_id,event_type,revision,sha256,actor_id,note)
  select s.id,s.rfi_id,s.surveyor_id,'ACKNOWLEDGED',s.shared_revision,s.shared_sha256,auth.uid(),format('Surveyor acknowledged package version %s fingerprint %s',max_ver,package_hash)
  from survey_rfi_drawings s where s.rfi_id=r.id and s.surveyor_id=auth.uid() and s.revoked_at is null;
  perform epas_audit(r.project_id,'SURVEY_DRAWING_PACKAGE_ACKNOWLEDGED','rfi',r.id,'surveyor','ACKNOWLEDGED','Surveyor acknowledged controlled drawing package',jsonb_build_object('package_version',max_ver,'package_fingerprint',package_hash,'package_count',n));
  return jsonb_build_object('acknowledged',true,'package_version',max_ver,'package_fingerprint',package_hash,'package_count',n);
end;$$;
grant execute on function epas_acknowledge_survey_drawing_package(uuid) to authenticated;

create or replace function epas_surveyor_accept_assignment(p_rfi_id uuid,p_note text default null)
returns survey_assignments language plpgsql security definer set search_path=public as $$
declare a survey_assignments; r rfis;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may accept survey assignment'; end if;
  select * into r from rfis where id=p_rfi_id;
  select * into a from survey_assignments where rfi_id=p_rfi_id for update;
  if a.id is null then raise exception 'Survey assignment not found'; end if;
  if r.assigned_surveyor_id<>auth.uid() or a.surveyor_id<>auth.uid() then raise exception 'Survey assignment is not yours'; end if;
  if a.status not in ('ASSIGNED','REASSIGNED') then raise exception 'Assignment is not awaiting acceptance'; end if;
  update survey_assignments set status='ACCEPTED',accepted_at=now(),acceptance_note=p_note,assignment_version=assignment_version+case when status='REASSIGNED' then 1 else 0 end where id=a.id returning * into a;
  update survey_executions set assignment_accepted_at=a.accepted_at,assignment_id=a.id,assignment_version=a.assignment_version,updated_at=now() where rfi_id=p_rfi_id;
  return a;
end;$$;
grant execute on function epas_surveyor_accept_assignment(uuid,text) to authenticated;

-- ================================================================
-- 7. Composite survey-start gate: scope ack + package ack + checklist + impact + assignment
-- ================================================================
create or replace function epas_survey_start_gate_v26(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r rfis; e survey_executions; a survey_assignments; s survey_scopes; has_pkg boolean; pkg_ack boolean; checklist_ok boolean; impact_ok boolean; scope_ack boolean; result jsonb;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  select * into e from survey_executions where rfi_id=r.id;
  select * into a from survey_assignments where rfi_id=r.id;
  select * into s from survey_scopes where rfi_id=r.id;
  if not (epas_has_role('gm') or epas_is_project_member(r.project_id)) then raise exception 'Not authorized to inspect survey start gate'; end if;
  has_pkg:=not exists(select 1 from plan_drawings d where d.project_id=r.project_id and d.status='approved')
           or exists(select 1 from survey_rfi_drawings x where x.rfi_id=r.id and x.surveyor_id=r.assigned_surveyor_id and x.revoked_at is null);
  pkg_ack:=not exists(select 1 from survey_rfi_drawings x where x.rfi_id=r.id and x.revoked_at is null)
           or not exists(select 1 from survey_rfi_drawings x where x.rfi_id=r.id and x.revoked_at is null and (x.handover_acknowledged_at is null or x.package_ack_version is distinct from x.package_version));
  checklist_ok:=epas_survey_checklist_ready(r.id);
  impact_ok:=not exists(
    select 1 from survey_rfi_drawings x
    join plan_drawings d on d.id=x.drawing_id
    join documents doc on doc.id=d.document_id
    left join survey_drawing_impact_decisions di on di.package_id=x.id
    where x.rfi_id=r.id and x.revoked_at is null
      and (x.shared_revision is distinct from d.revision or coalesce(x.shared_sha256,'') is distinct from coalesce(doc.sha256,''))
      and coalesce(di.impact,'')<>'NO_IMPACT'
  );
  scope_ack:=exists(select 1 from survey_scope_acknowledgements x where x.rfi_id=r.id and x.scope_version=coalesce(s.current_version,s.scope_version,1) and x.acknowledged_by=r.assigned_surveyor_id);
  result:=jsonb_build_object(
    'assignment_accepted',coalesce(a.status in ('ACCEPTED','IN_PROGRESS'),false),
    'package_exists',has_pkg,
    'package_acknowledged',pkg_ack,
    'checklist_ready',checklist_ok,
    'revision_impact_clear',impact_ok,
    'scope_acknowledged',scope_ack,
    'scope_version',coalesce(s.current_version,s.scope_version,1),
    'assignment_version',coalesce(a.assignment_version,0),
    'package_version',(select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null)
  );
  result:=result || jsonb_build_object('ready',
    (result->>'assignment_accepted')::boolean
    and (result->>'package_acknowledged')::boolean
    and (result->>'checklist_ready')::boolean
    and (result->>'revision_impact_clear')::boolean
    and (result->>'scope_acknowledged')::boolean
  );
  return result;
end;$$;
grant execute on function epas_survey_start_gate_v26(uuid) to authenticated;

-- ================================================================
-- 8. Freeze execution basis as an immutable version before start
-- ================================================================
create or replace function epas_freeze_survey_execution_basis(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
declare e survey_executions; r rfis; a survey_assignments; s survey_scopes; gate jsonb; basis jsonb; v integer; sha text;
begin
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  select * into r from rfis where id=p_rfi_id;
  select * into a from survey_assignments where rfi_id=p_rfi_id;
  select * into s from survey_scopes where rfi_id=p_rfi_id;
  if e.id is null or r.id is null then raise exception 'Survey execution not found'; end if;
  if e.basis_frozen_at is not null and e.status not in ('NOT_STARTED','RETURNED') then raise exception 'Execution basis is already frozen for an active/completed survey; create a new assignment/package version for any change'; end if;
  if not (e.surveyor_id=auth.uid() or (epas_has_role('dm') and r.assigned_dm_id=auth.uid()) or epas_has_role('gm')) then raise exception 'Not authorized to freeze survey execution basis'; end if;
  gate:=epas_survey_start_gate_v26(p_rfi_id);
  if not coalesce((gate->>'ready')::boolean,false) then raise exception 'Survey start gate is not ready: %',gate::text; end if;
  basis:=jsonb_build_object(
    'rfi_id',r.id,
    'scope_version',(gate->>'scope_version')::integer,
    'scope_snapshot',(select to_jsonb(sv) from survey_scope_versions sv where sv.rfi_id=r.id and sv.version_no=(gate->>'scope_version')::integer),
    'assignment_id',a.id,
    'assignment_version',a.assignment_version,
    'assignment_snapshot',(select to_jsonb(x) from survey_assignments x where x.id=a.id),
    'drawing_package_version',(gate->>'package_version')::integer,
    'drawings',(select coalesce(jsonb_agg(jsonb_build_object('package_id',x.id,'package_version',x.package_version,'drawing_no',x.shared_drawing_no,'title',x.shared_title,'discipline',x.shared_discipline,'revision',x.shared_revision,'document_id',x.shared_document_id,'file_name',x.shared_file_name,'storage_path',x.shared_storage_path,'sha256',x.shared_sha256,'mime_type',x.shared_mime_type,'size_bytes',x.shared_size_bytes,'package_fingerprint',x.package_fingerprint)),'[]'::jsonb) from survey_rfi_drawings x where x.rfi_id=r.id and x.revoked_at is null),
    'checklist_version',(select coalesce(max(checklist_version),1) from survey_checklist_items where rfi_id=r.id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(ci)),'[]'::jsonb) from survey_checklist_items ci where ci.rfi_id=r.id),
    'scope_acknowledged_version',e.scope_acknowledged_version,
    'drawing_package_ack_version',e.drawing_package_ack_version
  );
  sha:=encode(digest(basis::text,'sha256'),'hex');
  select coalesce(max(basis_version),0)+1 into v from survey_execution_basis_versions where execution_id=e.id;
  insert into survey_execution_basis_versions(execution_id,rfi_id,basis_version,scope_version,drawing_package_version,checklist_version,assignment_id,assignment_version,package_ack_version,scope_ack_version,basis_snapshot,basis_sha256,frozen_by)
  values(e.id,r.id,v,(gate->>'scope_version')::integer,(gate->>'package_version')::integer,(basis->>'checklist_version')::integer,a.id,a.assignment_version,e.drawing_package_ack_version,e.scope_acknowledged_version,basis,sha,auth.uid());
  update survey_executions set execution_basis=basis,execution_basis_version=v,basis_sha256=sha,basis_frozen_at=now(),scope_version=(gate->>'scope_version')::integer,drawing_package_version=(gate->>'package_version')::integer,checklist_version=(basis->>'checklist_version')::integer,updated_at=now() where id=e.id returning * into e;
  return e;
end;$$;
grant execute on function epas_freeze_survey_execution_basis(uuid) to authenticated;

-- Start wrapper uses v2.6 gate and freezes the exact execution basis.
create or replace function epas_start_survey_execution_v26(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
declare e survey_executions; r rfis; a survey_assignments; g jsonb;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may start survey execution'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  select * into a from survey_assignments where rfi_id=p_rfi_id for update;
  if r.assigned_surveyor_id<>auth.uid() or a.surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  g:=epas_survey_start_gate_v26(p_rfi_id);
  if not coalesce((g->>'ready')::boolean,false) then raise exception 'Survey start gate failed: %',g::text; end if;
  perform epas_freeze_survey_execution_basis(p_rfi_id);
  update survey_executions set status='IN_PROGRESS',started_at=coalesce(started_at,now()),started_by=auth.uid(),updated_at=now() where rfi_id=p_rfi_id returning * into e;
  update survey_assignments set status='IN_PROGRESS' where id=a.id;
  return e;
end;$$;
grant execute on function epas_start_survey_execution_v26(uuid) to authenticated;

-- ================================================================
-- 9. Certificate decision package final freeze + fingerprint + versioned ACK
-- ================================================================
create table if not exists certificate_decision_acknowledgement_versions (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references certificate_decision_packages(id) on delete cascade,
  package_version integer not null,
  package_sha256 text not null,
  acknowledged_by uuid not null references profiles(id),
  acknowledged_at timestamptz not null default now(),
  note text,
  unique(package_id,package_version,acknowledged_by)
);

alter table certificate_decision_packages add column if not exists package_sha256 text;
alter table certificate_decision_packages add column if not exists scope_version integer;
alter table certificate_decision_packages add column if not exists execution_basis_version integer;
alter table certificate_decision_packages add column if not exists execution_basis_sha256 text;
alter table certificate_decision_acknowledgements add column if not exists package_version integer;
alter table certificate_decision_acknowledgements add column if not exists package_sha256 text;

create or replace function epas_freeze_certificate_decision_package(p_rfi_id uuid,p_decision text)
returns certificate_decision_packages language plpgsql security definer set search_path=public as $$
declare r rfis; p projects; v certificate_decision_packages; ver integer; c uuid; snapshot jsonb; sha text; e survey_executions;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may freeze a certificate decision package'; end if;
  if p_decision not in ('APPROVED','INTERIM','RETURNED') then raise exception 'Invalid certificate decision'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null then raise exception 'RFI not found'; end if;
  select * into p from projects where id=r.project_id;
  select * into e from survey_executions where rfi_id=r.id order by created_at desc limit 1;
  if e.id is null or e.basis_frozen_at is null then raise exception 'Survey execution basis must be frozen before certificate decision package'; end if;
  if not exists(select 1 from survey_execution_declarations where execution_id=e.id) then raise exception 'Surveyor professional declaration is required before certificate decision package'; end if;
  select coalesce(max(package_version),0)+1 into ver from certificate_decision_packages where rfi_id=r.id;
  select id into c from certificates where rfi_id=r.id order by created_at desc limit 1;
  snapshot:=jsonb_build_object(
    'rfi_id',r.id,
    'project_id',p.id,
    'vessel_id',r.vessel_id,
    'decision',p_decision,
    'survey_execution',(select to_jsonb(x) from survey_executions x where x.id=e.id),
    'execution_basis',(select to_jsonb(x) from survey_execution_basis_versions x where x.execution_id=e.id order by basis_version desc limit 1),
    'observations',(select coalesce(jsonb_agg(to_jsonb(o)),'[]'::jsonb) from observations o where o.rfi_id=r.id),
    'corrective_actions',(select coalesce(jsonb_agg(to_jsonb(ca)),'[]'::jsonb) from corrective_actions ca where ca.rfi_id=r.id),
    'drawing_package',(select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from survey_rfi_drawings s where s.rfi_id=r.id and s.revoked_at is null),
    'scope_version',(select current_version from survey_scopes where rfi_id=r.id),
    'gm_decision',(select coalesce(to_jsonb(g),'{}'::jsonb) from gm_decisions g where g.rfi_id=r.id order by decided_at desc limit 1)
  );
  sha:=encode(digest(snapshot::text,'sha256'),'hex');
  insert into certificate_decision_packages(certificate_id,rfi_id,project_id,vessel_id,package_version,decision,frozen_by,survey_snapshot,observation_snapshot,corrective_action_snapshot,drawing_package_snapshot,gm_decision_snapshot,dm_ack_snapshot,package_sha256,scope_version,execution_basis_version,execution_basis_sha256)
  values(c,r.id,p.id,r.vessel_id,ver,p_decision,auth.uid(),snapshot->'survey_execution',snapshot->'observations',snapshot->'corrective_actions',snapshot->'drawing_package',snapshot->'gm_decision','{}'::jsonb,sha,(snapshot->>'scope_version')::integer,(snapshot->'execution_basis'->>'basis_version')::integer,(snapshot->'execution_basis'->>'basis_sha256'))
  returning * into v;
  perform epas_audit(r.project_id,'CERTIFICATE_DECISION_PACKAGE_FROZEN','rfi',r.id,'gm',p_decision,'Immutable certificate decision package frozen',jsonb_build_object('package_id',v.id,'package_version',ver,'package_sha256',sha));
  return v;
end;$$;
grant execute on function epas_freeze_certificate_decision_package(uuid,text) to authenticated;

create or replace function epas_acknowledge_certificate_decision_package(p_package_id uuid,p_note text default null)
returns certificate_decision_acknowledgements language plpgsql security definer set search_path=public as $$
declare p certificate_decision_packages; r rfis; a certificate_decision_acknowledgements; sha text;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may acknowledge certificate decision package'; end if;
  select * into p from certificate_decision_packages where id=p_package_id;
  if p.id is null then raise exception 'Decision package not found'; end if;
  select * into r from rfis where id=p.rfi_id;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may acknowledge this package'; end if;
  if p.package_sha256 is null then raise exception 'Decision package is not fully frozen'; end if;
  sha:=p.package_sha256;
  insert into certificate_decision_acknowledgements(package_id,rfi_id,acknowledged_by,acknowledged_at,note,package_version,package_sha256)
  values(p.id,r.id,auth.uid(),now(),p_note,p.package_version,sha)
  on conflict(package_id,acknowledged_by) do update set acknowledged_at=now(),note=excluded.note,package_version=excluded.package_version,package_sha256=excluded.package_sha256
  returning * into a;
  insert into certificate_decision_acknowledgement_versions(package_id,package_version,package_sha256,acknowledged_by,acknowledged_at,note)
  values(p.id,p.package_version,sha,auth.uid(),a.acknowledged_at,p_note)
  on conflict(package_id,package_version,acknowledged_by) do update set acknowledged_at=excluded.acknowledged_at,note=excluded.note;
  update certificate_decision_packages set dm_ack_snapshot=jsonb_build_object('acknowledged',true,'acknowledged_by',auth.uid(),'acknowledged_at',a.acknowledged_at,'note',a.note,'package_version',p.package_version,'package_sha256',sha) where id=p.id;
  return a;
end;$$;
grant execute on function epas_acknowledge_certificate_decision_package(uuid,text) to authenticated;

-- Certificate issuance must consume the exact package version/sha that was acknowledged.
create or replace function epas_certificate_issuance_gate(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare p certificate_decision_packages; r rfis; open_obs integer; dm_ack boolean; gate boolean; latest_ack certificate_decision_acknowledgements;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not (epas_has_role('gm') or epas_is_project_member(r.project_id)) then raise exception 'Not authorized for certificate gate'; end if;
  select count(*) into open_obs from observations where rfi_id=r.id and status='open';
  select * into p from certificate_decision_packages where rfi_id=r.id order by package_version desc limit 1;
  select * into latest_ack from certificate_decision_acknowledgements where package_id=p.id order by acknowledged_at desc limit 1;
  dm_ack:=latest_ack.id is not null and latest_ack.package_version=p.package_version and latest_ack.package_sha256=p.package_sha256;
  gate:=p.id is not null and p.package_sha256 is not null and dm_ack and r.status in ('approved_no_observations','approved_with_observations')
    and ((open_obs=0 and p_cert_type<>'interim_certificate' and p.decision='APPROVED') or (open_obs>0 and p_cert_type='interim_certificate' and p.decision='INTERIM'));
  return jsonb_build_object('gate_passed',gate,'decision_package_id',p.id,'package_version',p.package_version,'package_sha256',p.package_sha256,'dm_acknowledged',dm_ack,'open_observations',open_obs,'certificate_type',p_cert_type);
end;$$;
grant execute on function epas_certificate_issuance_gate(uuid,text) to authenticated;

-- ================================================================
-- 10. Evidence authorization + exact observation binding (final wrapper)
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
  select role into role_name from profiles where id=auth.uid();
  if not epas_is_project_member(r.project_id) then raise exception 'Not an active project member'; end if;
  if role_name='ship_management' then
    if p_corrective_action_id is null or not exists(select 1 from corrective_actions x where x.id=p_corrective_action_id and x.rfi_id=o.rfi_id and x.assigned_to=auth.uid() and x.status in ('assigned','in_progress','returned_for_rework','submitted')) then raise exception 'Evidence is not linked to a corrective action assigned to this Ship Management user'; end if;
  elsif role_name='surveyor' then
    if r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
    if not exists(select 1 from survey_executions e where e.rfi_id=r.id and e.surveyor_id=auth.uid()) then raise exception 'Survey execution is not assigned to this Surveyor'; end if;
  elsif role_name='dm' then
    if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may register DM evidence'; end if;
  else
    raise exception 'Role cannot submit observation evidence';
  end if;
  if p_corrective_action_id is not null and not exists(select 1 from corrective_action_observations x where x.corrective_action_id=p_corrective_action_id and x.observation_id=o.id) then
    raise exception 'Observation is not explicitly linked to this corrective action';
  end if;
  insert into observation_evidence(observation_id,corrective_action_id,uploaded_by,file_name,storage_path,sha256,mime_type,size_bytes,evidence_type)
  values(o.id,p_corrective_action_id,auth.uid(),p_file_name,p_storage_path,p_sha256,p_mime_type,p_size_bytes,p_evidence_type)
  returning * into e;
  return e;
end;$$;
grant execute on function epas_register_observation_evidence(uuid,uuid,text,text,text,text,bigint,text) to authenticated;

-- ================================================================
-- 11. Recurring In-Service schedule: explicit basis, no silent 12-month fallback
-- ================================================================
update survey_schedules set due_basis='CERTIFICATE_EXPIRY' where due_basis='CERTIFICATE' or due_basis is null;
alter table survey_schedules add column if not exists schedule_config_status text not null default 'CONFIGURED';
update survey_schedules set schedule_config_status='REVIEW_REQUIRED' where due_basis='CERTIFICATE_EXPIRY' and coalesce(survey_interval_months,interval_months)=12;
alter table survey_schedules add column if not exists schedule_basis_date date;
alter table survey_schedules add column if not exists window_days_after integer not null default 30;
alter table survey_schedules add column if not exists intent_action text;
alter table survey_schedules add column if not exists current_cycle_started_at timestamptz;
alter table survey_schedules add column if not exists cycle_completed_at timestamptz;
alter table survey_schedules drop constraint if exists survey_schedules_due_basis_check_v26;
alter table survey_schedules add constraint survey_schedules_due_basis_check_v26 check(due_basis in ('CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED'));
alter table survey_schedules drop constraint if exists survey_schedules_config_status_check_v26;
alter table survey_schedules add constraint survey_schedules_config_status_check_v26 check(schedule_config_status in ('CONFIGURED','REVIEW_REQUIRED','CONFIGURATION_REQUIRED'));

create table if not exists survey_schedule_basis_history (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references survey_schedules(id) on delete cascade,
  old_interval_months integer,
  new_interval_months integer,
  old_due_basis text,
  new_due_basis text,
  old_basis_reference text,
  new_basis_reference text,
  changed_by uuid references profiles(id),
  changed_at timestamptz not null default now(),
  reason text
);

create or replace function epas_set_in_service_schedule_basis_v26(
  p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_window_days_before integer,p_window_days_after integer default 30
) returns survey_schedules language plpgsql security definer set search_path=public as $$
declare s survey_schedules; p projects; old survey_schedules; v_project_id uuid;
begin
  select project_id into v_project_id from vessels where id=p_vessel_id;
  if v_project_id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v_project_id;
  if not (epas_has_role('gm') or epas_is_project_member(p.id)) then raise exception 'Not authorized for this vessel schedule'; end if;
  if not (epas_has_role('gm') or exists(select 1 from project_members pm where pm.project_id=p.id and pm.user_id=auth.uid() and pm.active and pm.role='dm')) then raise exception 'Only assigned DM or GM may configure schedule basis'; end if;
  if p_interval_months is null or p_interval_months<=0 then raise exception 'Schedule interval must be explicitly configured and positive'; end if;
  if p_due_basis not in ('CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED') then raise exception 'Invalid schedule basis'; end if;
  if coalesce(trim(p_basis_reference),'')='' then raise exception 'Schedule basis reference is mandatory'; end if;
  select * into old from survey_schedules where vessel_id=p_vessel_id and phase='in_service' and active for update;
  if old.id is null then raise exception 'Active In-Service schedule not found'; end if;
  insert into survey_schedule_basis_history(schedule_id,old_interval_months,new_interval_months,old_due_basis,new_due_basis,old_basis_reference,new_basis_reference,changed_by,reason)
  values(old.id,old.survey_interval_months,p_interval_months,old.due_basis,p_due_basis,old.due_basis_reference,p_basis_reference,auth.uid(),'Explicit schedule configuration update');
  update survey_schedules set survey_interval_months=p_interval_months,interval_months=p_interval_months,due_basis=p_due_basis,due_basis_reference=p_basis_reference,due_window_days_before=greatest(1,p_window_days_before),window_days_after=greatest(1,p_window_days_after),schedule_config_status='CONFIGURED',window_start=(next_due_date-greatest(1,p_window_days_before))::date,window_end=(next_due_date+greatest(1,p_window_days_after))::date,updated_at=now() where id=old.id returning * into s;
  return s;
end;$$;
grant execute on function epas_set_in_service_schedule_basis_v26(uuid,integer,text,text,integer,integer) to authenticated;

-- Preserve explicit schedule basis and never silently invent a 12-month interval.
create or replace function epas_sync_survey_schedule_v26(p_vessel_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; s survey_schedules; c certificates; due date; base_date date; interval_m integer; current_rfi uuid; completed_date date; months_from_cert integer;
begin
  select * into v from vessels where id=p_vessel_id;
  if v.id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v.project_id;
  if not ('in_service'=any(coalesce(p.phases,'{}'::text[]))) then return null; end if;
  select * into s from survey_schedules where vessel_id=v.id and phase='in_service' and active for update;
  select * into c from certificates where vessel_id=v.id and status in ('active','expiring') order by expiry_date desc limit 1;

  if s.id is null then
    if c.id is null then return null; end if;
    base_date:=c.issue_date;
    due:=c.expiry_date;
    select extract(year from age(c.expiry_date,c.issue_date))::integer*12 + extract(month from age(c.expiry_date,c.issue_date))::integer into months_from_cert;
    interval_m:=nullif(months_from_cert,0);
    insert into survey_schedules(vessel_id,project_id,survey_type,phase,interval_months,survey_interval_months,last_completed_date,next_due_date,window_start,window_end,status,source_certificate_id,source_rfi_id,due_basis,due_basis_reference,due_window_days_before,window_days_after,cycle_number,active,schedule_config_status,schedule_basis_date,intent_action)
    values(v.id,v.project_id,'Scheduled In-Service Survey','in_service',interval_m,interval_m,c.issue_date,due,(due-interval '90 days')::date,(due+interval '30 days')::date,case when due<current_date then 'OVERDUE' when due<=current_date+30 then 'DUE' when due<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,c.id,c.rfi_id,'CERTIFICATE_EXPIRY',c.cert_number,90,30,1,true,case when interval_m is null then 'CONFIGURATION_REQUIRED' else 'REVIEW_REQUIRED' end,due,'CREATE_IN_SERVICE_RFI') returning * into s;
    return s;
  end if;

  interval_m:=coalesce(s.survey_interval_months,s.interval_months);
  if interval_m is null or interval_m<=0 then
    update survey_schedules set schedule_config_status='CONFIGURATION_REQUIRED',status=case when current_rfi_id is not null then 'RFI_OPEN' else 'SUSPENDED' end,updated_at=now() where id=s.id returning * into s;
    return s;
  end if;

  current_rfi:=s.current_rfi_id;
  if current_rfi is not null and exists(select 1 from rfis r where r.id=current_rfi and r.status in ('certificate_issued','closed')) then
    select max(coalesce(e.completed_at,sr.submitted_at)::date) into completed_date
    from survey_executions e left join survey_reports sr on sr.rfi_id=e.rfi_id
    where e.rfi_id=current_rfi;
    if completed_date is null then completed_date:=s.last_completed_date; end if;
    base_date:=completed_date;
    due:=(base_date + make_interval(months=>interval_m))::date;
    update survey_schedules set last_completed_date=base_date,next_due_date=due,window_start=(due-due_window_days_before)::date,window_end=(due+window_days_after)::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=current_rfi,cycle_completed_at=now(),cycle_number=cycle_number+1,updated_at=now() where id=s.id returning * into s;
  end if;

  if s.current_rfi_id is null then
    select r.id into current_rfi from rfis r where r.project_id=s.project_id and r.vessel_id=s.vessel_id and r.phase='in_service' and r.status not in ('certificate_issued','closed') order by r.created_at desc limit 1;
    if current_rfi is not null then
      update survey_schedules set current_rfi_id=current_rfi,source_rfi_id=current_rfi,status='RFI_OPEN',current_cycle_started_at=coalesce(current_cycle_started_at,now()),intent_action='RFI_OPEN',updated_at=now() where id=s.id returning * into s;
    end if;
  end if;

  update survey_schedules set schedule_config_status=case when due_basis is null or due_basis_reference is null or survey_interval_months is null then 'CONFIGURATION_REQUIRED' else 'CONFIGURED' end,
    status=case when current_rfi_id is not null then 'RFI_OPEN' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,
    window_start=(next_due_date-due_window_days_before)::date,
    window_end=(next_due_date+window_days_after)::date,
    updated_at=now()
  where id=s.id returning * into s;
  return s;
end;$$;
grant execute on function epas_sync_survey_schedule_v26(uuid) to authenticated;

-- ================================================================
-- 12. Schedule -> RFI authoritative linkage + guided initiation
-- ================================================================
create or replace function epas_stakeholder_create_scheduled_in_service_rfi(
  p_schedule_id uuid,p_survey_type text,p_requested_date date,p_priority text,p_scope_note text
) returns rfis language plpgsql security definer set search_path=public as $$
declare s survey_schedules; v_role text; p projects; r rfis; code text; gate text; v vessel; linked boolean;
begin
  select * into s from survey_schedules where id=p_schedule_id and active for update;
  if s.id is null then raise exception 'Survey schedule not found'; end if;
  select role into v_role from profiles where id=auth.uid();
  if v_role not in ('owner','ship_management') then raise exception 'Only Owner or Ship Management may initiate scheduled In-Service RFI'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=s.project_id and pm.user_id=auth.uid() and pm.active and pm.role=v_role) then raise exception 'Not an active stakeholder member of this project'; end if;
  select status into gate from project_phase_control where project_id=s.project_id and phase='in_service';
  if coalesce(gate,'LOCKED') not in ('READY','IN_PROGRESS') then raise exception 'In-Service phase is not currently eligible'; end if;
  if s.current_rfi_id is not null and exists(select 1 from rfis x where x.id=s.current_rfi_id and x.status not in ('certificate_issued','closed')) then raise exception 'An In-Service RFI is already open for this survey cycle'; end if;
  if coalesce(trim(p_scope_note),'')='' then raise exception 'Survey scope is required'; end if;
  select * into v from vessels where id=s.vessel_id;
  code:='RFI-SCH-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(s.project_id,s.vessel_id,'in_service',coalesce(nullif(p_survey_type,''),s.survey_type),code,'pending_allocation',auth.uid(),coalesce(p_requested_date,s.next_due_date),p_priority,p_scope_note,v_role)
  returning * into r;
  insert into survey_scopes(rfi_id,scope_text,survey_type,phase,status,current_version)
  values(r.id,p_scope_note,coalesce(nullif(p_survey_type,''),s.survey_type),'in_service','SUBMITTED',1)
  on conflict(rfi_id) do nothing;
  update survey_schedules set current_rfi_id=r.id,source_rfi_id=r.id,status='RFI_OPEN',current_cycle_started_at=now(),intent_action='RFI_OPEN',updated_at=now() where id=s.id;
  perform epas_audit(r.project_id,'SCHEDULED_IN_SERVICE_RFI_CREATED','rfi',r.id,v_role,'pending_allocation',p_scope_note,jsonb_build_object('schedule_id',s.id,'cycle_number',s.cycle_number,'due_date',s.next_due_date,'basis',s.due_basis,'basis_reference',s.due_basis_reference));
  return r;
end;$$;
grant execute on function epas_stakeholder_create_scheduled_in_service_rfi(uuid,text,date,text,text) to authenticated;

create or replace function epas_survey_schedule_action_context(p_schedule_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare s survey_schedules; v_role text;
begin
  select * into s from survey_schedules where id=p_schedule_id;
  if s.id is null then raise exception 'Survey schedule not found'; end if;
  select role into v_role from profiles where id=auth.uid();
  if v_role not in ('gm','dm','owner','ship_management') then raise exception 'Not authorized to view schedule action context'; end if;
  if not epas_is_project_member(s.project_id) then raise exception 'Not authorized for this project'; end if;
  return jsonb_build_object('schedule_id',s.id,'project_id',s.project_id,'vessel_id',s.vessel_id,'phase',s.phase,'survey_type',s.survey_type,'cycle_number',s.cycle_number,'next_due_date',s.next_due_date,'window_start',s.window_start,'window_end',s.window_end,'status',s.status,'schedule_config_status',s.schedule_config_status,'due_basis',s.due_basis,'due_basis_reference',s.due_basis_reference,'survey_interval_months',s.survey_interval_months,'current_rfi_id',s.current_rfi_id,'can_initiate_in_service',(v_role in ('owner','ship_management') and s.phase='in_service' and s.current_rfi_id is null and s.schedule_config_status='CONFIGURED'));
end;$$;
grant execute on function epas_survey_schedule_action_context(uuid) to authenticated;

-- ================================================================
-- 13. Correct vessel status projection + date semantics
-- ================================================================
alter table vessels add column if not exists last_survey_completed_at timestamptz;
alter table vessels add column if not exists last_survey_report_submitted_at timestamptz;
alter table vessels add column if not exists last_certificate_issued_date date;

create or replace function epas_refresh_vessel_survey_status_v26(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; old_status text; new_status text; phase_name text; source_id uuid; last_completed timestamptz; last_report timestamptz; last_cert date; next_due date; active_nsc boolean; active_in boolean; nsc_done boolean; in_exists boolean; open_obs integer;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v.project_id;
  if auth.uid() is not null and not (epas_has_role('gm') or epas_has_role('dm') or epas_is_project_member(p.id)) then raise exception 'Not authorized for vessel status'; end if;
  old_status:=v.survey_status;
  select exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey' and r.status not in ('certificate_issued','closed')) into active_nsc;
  select exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='in_service' and r.status not in ('certificate_issued','closed')) into active_in;
  select exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey' and r.status in ('certificate_issued','closed')) into nsc_done;
  select exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='in_service' and r.status in ('certificate_issued','closed')) into in_exists;
  select count(*) into open_obs from observations o join rfis r on r.id=o.rfi_id where r.vessel_id=v.id and o.status='open';

  select max(e.completed_at),max(sr.submitted_at) into last_completed,last_report
  from survey_executions e left join survey_reports sr on sr.rfi_id=e.rfi_id where e.surveyor_id is not null and e.rfi_id in (select id from rfis where vessel_id=v.id) and e.status in ('COMPLETED','REPORT_SUBMITTED','DM_REVIEW','GM_REVIEW');
  select max(issue_date) into last_cert from certificates where vessel_id=v.id and status in ('active','expiring');
  select min(next_due_date) into next_due from survey_schedules where vessel_id=v.id and active;
  select id into source_id from rfis where vessel_id=v.id order by updated_at desc limit 1;

  if p.status='closed' then new_status:='PROJECT_CLOSED'; phase_name:=null;
  elsif active_in then new_status:='IN_SERVICE_IN_PROGRESS'; phase_name:='in_service';
  elsif exists(select 1 from survey_schedules s where s.vessel_id=v.id and s.active and s.status='OVERDUE') then new_status:='IN_SERVICE_OVERDUE'; phase_name:='in_service';
  elsif open_obs>0 and in_exists then new_status:='OBSERVATIONS_OPEN'; phase_name:='in_service';
  elsif exists(select 1 from survey_schedules s where s.vessel_id=v.id and s.active and s.status in ('DUE','DUE_SOON')) then new_status:='IN_SERVICE_DUE'; phase_name:='in_service';
  elsif active_nsc then new_status:='NSC_IN_PROGRESS'; phase_name:='nsc_survey';
  elsif nsc_done then new_status:='CLASS_ACTIVE'; phase_name:='nsc_survey';
  elsif 'in_service'=any(p.phases) then new_status:='IN_SERVICE_DUE'; phase_name:='in_service';
  elsif 'nsc_survey'=any(p.phases) then new_status:='NSC_DUE'; phase_name:='nsc_survey';
  else new_status:='PLAN_APPRAISAL'; phase_name:='plan_appraisal'; end if;

  update vessels set survey_status=new_status,survey_status_updated_at=now(),next_survey_due=next_due,last_survey_date=case when last_completed is not null then (last_completed at time zone 'UTC')::date else last_survey_date end,last_survey_phase=phase_name,last_survey_completed_at=last_completed,last_survey_report_submitted_at=last_report,last_certificate_issued_date=last_cert,class_status=case when nsc_done or last_cert is not null then 'CLASS_ACTIVE' else class_status end where id=v.id returning * into v;
  if old_status is distinct from new_status then
    insert into vessel_survey_status_history(vessel_id,project_id,status,phase,source_type,source_id,note) values(v.id,v.project_id,new_status,phase_name,'SYSTEM',source_id,'Central survey status engine v2.6');
  end if;
  return v;
end;$$;
grant execute on function epas_refresh_vessel_survey_status_v26(uuid) to authenticated;

-- ================================================================
-- 14. Project scope state machine: explicit phase vs cycle vs project status
-- ================================================================
create or replace function epas_project_scope_state(p_project_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare p projects; plan_state text; nsc_state text; in_state text; project_scope_status text;
begin
  select * into p from projects where id=p_project_id;
  if p.id is null then raise exception 'Project not found'; end if;
  if not epas_is_project_member(p.id) then raise exception 'Not authorized for project scope state'; end if;
  select status into plan_state from project_phase_control where project_id=p.id and phase='plan_appraisal';
  select status into nsc_state from project_phase_control where project_id=p.id and phase='nsc_survey';
  select status into in_state from project_phase_control where project_id=p.id and phase='in_service';
  if 'in_service'=any(p.phases) then project_scope_status:='IN_SERVICE_ACTIVE';
  elsif 'nsc_survey'=any(p.phases) then project_scope_status:=case when nsc_state='COMPLETED' then 'NSC_COMPLETE' else 'NSC_ACTIVE' end;
  elsif 'plan_appraisal'=any(p.phases) then project_scope_status:=case when plan_state='COMPLETED' then 'PLAN_ONLY_COMPLETE' else 'PLAN_ACTIVE' end;
  else project_scope_status:='NOT_STARTED'; end if;
  return jsonb_build_object('project_id',p.id,'project_status',p.status,'project_scope_status',project_scope_status,'plan_phase_status',plan_state,'nsc_phase_status',nsc_state,'in_service_phase_status',in_state,'in_service_phase_continuing',('in_service'=any(p.phases)));
end;$$;
grant execute on function epas_project_scope_state(uuid) to authenticated;

-- ================================================================
-- 15. Lifecycle consistency triggers
-- ================================================================
create or replace function epas_sync_workflow_projections_after_rfi()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  begin perform epas_refresh_vessel_survey_status_v26(new.vessel_id); exception when others then null; end;
  begin perform epas_refresh_project_phase_state(new.project_id); exception when others then null; end;
  return new;
end;$$;
drop trigger if exists trg_epas_sync_workflow_projections_after_rfi on rfis;
create trigger trg_epas_sync_workflow_projections_after_rfi
after insert or update of status,phase,assigned_surveyor_id,scheduled_date on rfis
for each row execute function epas_sync_workflow_projections_after_rfi();

-- ================================================================
-- 16. Role-aware recurring notification policy
-- ================================================================
create table if not exists survey_notification_policy (
  phase text not null,
  role_name text not null,
  event_type text not null,
  allowed boolean not null default true,
  unique(phase,role_name,event_type)
);
insert into survey_notification_policy(phase,role_name,event_type,allowed) values
('nsc_survey','gm','SURVEY_DUE',true),('nsc_survey','dm','SURVEY_DUE',true),('nsc_survey','shipyard','SURVEY_DUE',true),('nsc_survey','owner','SURVEY_DUE',false),('nsc_survey','ship_management','SURVEY_DUE',false),
('in_service','gm','SURVEY_DUE',true),('in_service','dm','SURVEY_DUE',true),('in_service','owner','SURVEY_DUE',true),('in_service','ship_management','SURVEY_DUE',true),('in_service','shipyard','SURVEY_DUE',false)
on conflict(phase,role_name,event_type) do update set allowed=excluded.allowed;

create table if not exists scheduler_runs (
  id uuid primary key default gen_random_uuid(),
  run_type text not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'RUNNING',
  processed_count integer not null default 0,
  error_message text,
  metadata jsonb not null default '{}'::jsonb
);

create or replace function epas_generate_survey_due_notifications_v26()
returns integer language plpgsql security definer set search_path=public as $$
declare s record; m record; allowed boolean; n integer:=0;
begin
  update survey_schedules set status=case when current_rfi_id is not null then 'RFI_OPEN' when schedule_config_status='CONFIGURATION_REQUIRED' then 'SUSPENDED' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,updated_at=now() where active;
  for s in select * from survey_schedules where active and status in ('DUE_SOON','DUE','OVERDUE') loop
    for m in select pm.user_id,pm.role from project_members pm where pm.project_id=s.project_id and pm.active loop
      select coalesce(max(x.allowed::int),0)::boolean into allowed from survey_notification_policy x where x.phase=s.phase and x.role_name=m.role and x.event_type='SURVEY_DUE';
      if allowed and not exists(select 1 from notifications x where x.user_id=m.user_id and x.project_id=s.project_id and x.link_page='survey_schedule:'||s.id::text and x.created_at::date=current_date) then
        insert into notifications(user_id,title,body,project_id,link_page)
        values(m.user_id,
          case s.status when 'OVERDUE' then 'Survey overdue' when 'DUE' then 'Survey due' else 'Survey window approaching' end,
          format('%s %s survey cycle %s due %s (%s days). Use the controlled survey action for this vessel.',s.survey_type,(select name from vessels where id=s.vessel_id),s.cycle_number,s.next_due_date,(s.next_due_date-current_date)),
          s.project_id,'survey_schedule:'||s.id::text);
        n:=n+1;
      end if;
    end loop;
  end loop;
  return n;
end;$$;
grant execute on function epas_generate_survey_due_notifications_v26() to service_role;

-- Manual management action remains available through a narrow wrapper.
create or replace function epas_generate_survey_due_notifications_as_operator()
returns integer language plpgsql security definer set search_path=public as $$
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may run manual due notifications'; end if;
  return epas_generate_survey_due_notifications_v26();
end;$$;
grant execute on function epas_generate_survey_due_notifications_as_operator() to authenticated;

-- ================================================================
-- 17. Automated scheduler tick (service role only) + manual refresh wrapper
-- ================================================================
create or replace function epas_scheduler_tick()
returns scheduler_runs language plpgsql security definer set search_path=public as $$
declare run scheduler_runs; n integer:=0; v record;
begin
  if current_user <> 'service_role' then raise exception 'Scheduler tick is restricted to service_role'; end if;
  insert into scheduler_runs(run_type,status,metadata) values('SURVEY_LIFECYCLE_TICK','RUNNING',jsonb_build_object('environment_role',current_user)) returning * into run;
  begin
    for v in select id from vessels loop
      begin perform epas_sync_survey_schedule_v26(v.id); n:=n+1; exception when others then null; end;
      begin perform epas_refresh_vessel_survey_status_v26(v.id); exception when others then null; end;
    end loop;
    n:=n+epas_generate_survey_due_notifications_v26();
    update scheduler_runs set completed_at=now(),status='COMPLETED',processed_count=n where id=run.id returning * into run;
  exception when others then
    update scheduler_runs set completed_at=now(),status='FAILED',error_message=sqlerrm where id=run.id returning * into run;
  end;
  return run;
end;$$;
grant execute on function epas_scheduler_tick() to service_role;

create or replace function epas_refresh_all_survey_schedules_as_operator()
returns integer language plpgsql security definer set search_path=public as $$
declare v record; n integer:=0;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may manually refresh survey schedules'; end if;
  for v in select id from vessels where project_id in (select project_id from project_members where user_id=auth.uid() and active) loop
    begin perform epas_sync_survey_schedule_v26(v.id); n:=n+1; exception when others then null; end;
  end loop;
  return n;
end;$$;
grant execute on function epas_refresh_all_survey_schedules_as_operator() to authenticated;

-- Revoke broad direct scheduler capabilities.
revoke all on function epas_refresh_all_survey_schedules() from authenticated;
revoke all on function epas_generate_survey_due_notifications() from authenticated;

-- ================================================================
-- 18. Timeline and control tower remain membership-safe, plus stakeholder-safe
-- ================================================================
create or replace function epas_project_timeline(p_project_id uuid,p_limit integer default 200)
returns table(created_at timestamptz,event_type text,entity_type text,entity_id uuid,actor_id uuid,from_state text,to_state text,note text,metadata jsonb)
language sql security definer set search_path=public stable as $$
  select le.created_at,le.event_type,le.entity_type,le.entity_id,le.actor_id,le.from_state,le.to_state,le.note,le.metadata
  from lifecycle_events le
  where le.project_id=p_project_id and epas_is_project_member(p_project_id)
  union all
  select a.created_at,a.action,'audit',a.id,a.actor_id,null,null,null,a.details
  from audit_log a
  where a.project_id=p_project_id and epas_is_project_member(p_project_id)
  order by created_at desc
  limit p_limit;
$$;
grant execute on function epas_project_timeline(uuid,integer) to authenticated;

drop function if exists epas_survey_schedule_queue(uuid);
create function epas_survey_schedule_queue(p_project_id uuid default null)
returns table(schedule_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,next_due_date date,window_start date,window_end date,status text,days_to_due integer,rfi_id uuid,schedule_config_status text,due_basis text,due_basis_reference text,cycle_number integer)
language plpgsql security definer set search_path=public stable as $$
begin
  if p_project_id is not null and not epas_is_project_member(p_project_id) then raise exception 'Not authorized for survey schedule queue'; end if;
  if p_project_id is null and not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Global survey schedule queue requires GM or DM'; end if;
  return query
  select s.id,s.vessel_id,v.name,s.phase,s.survey_type,s.next_due_date,s.window_start,s.window_end,s.status,(s.next_due_date-current_date),s.current_rfi_id,s.schedule_config_status,s.due_basis,s.due_basis_reference,s.cycle_number
  from survey_schedules s join vessels v on v.id=s.vessel_id
  where s.active and (p_project_id is null or s.project_id=p_project_id)
  order by s.next_due_date;
end;$$;
grant execute on function epas_survey_schedule_queue(uuid) to authenticated;

-- ================================================================
-- 19. Survey report gate now includes declaration + exact frozen execution basis
-- ================================================================
create or replace function epas_survey_submission_gate_v26(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare r rfis; e survey_executions; d survey_execution_declarations; gate jsonb; open_obs integer;
begin
  select * into r from rfis where id=p_rfi_id;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  select * into d from survey_execution_declarations where execution_id=e.id;
  if r.id is null or e.id is null then raise exception 'Survey execution not found'; end if;
  gate:=epas_survey_start_gate_v26(p_rfi_id);
  select count(*) into open_obs from observations where rfi_id=p_rfi_id and status='open';
  return gate || jsonb_build_object(
    'basis_frozen',e.basis_frozen_at is not null,
    'execution_basis_version',e.execution_basis_version,
    'basis_sha256',e.basis_sha256,
    'declaration_complete',d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete,
    'open_observations',open_obs,
    'ready_to_submit',coalesce((gate->>'ready')::boolean,false) and e.basis_frozen_at is not null and d.id is not null and d.scope_confirmed and d.drawings_confirmed and d.attendance_confirmed and d.safety_confirmed and d.report_complete
  );
end;$$;
grant execute on function epas_survey_submission_gate_v26(uuid) to authenticated;

create or replace function epas_guard_survey_report_submit()
returns trigger language plpgsql security definer set search_path=public as $$
declare g jsonb; r rfis; e survey_executions;
begin
  select * into r from rfis where id=new.rfi_id;
  select * into e from survey_executions where rfi_id=new.rfi_id;
  if r.id is null or e.id is null then raise exception 'Controlled survey execution is required'; end if;
  if new.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey report must be submitted by assigned Surveyor'; end if;
  g:=epas_survey_submission_gate_v26(new.rfi_id);
  if not coalesce((g->>'ready_to_submit')::boolean,false) then raise exception 'Survey report submission gate failed: %',g::text; end if;
  return new;
end;$$;
drop trigger if exists trg_epas_guard_survey_report_submit on survey_reports;
create trigger trg_epas_guard_survey_report_submit
before insert or update on survey_reports
for each row execute function epas_guard_survey_report_submit();

-- ================================================================
-- 20. Automatic next-cycle lifecycle event and guided RFI intent
-- ================================================================
create or replace function epas_mark_in_service_cycle_complete(p_rfi_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare r rfis; s survey_schedules; e survey_executions; due date; interval_m integer; base_date date;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.phase<>'in_service' then raise exception 'RFI is not In-Service'; end if;
  select * into s from survey_schedules where vessel_id=r.vessel_id and phase='in_service' and active for update;
  select * into e from survey_executions where rfi_id=r.id;
  interval_m:=s.survey_interval_months;
  if interval_m is null or interval_m<=0 then raise exception 'In-Service schedule requires explicit survey interval before next cycle can be generated'; end if;
  base_date:=coalesce((e.completed_at at time zone 'UTC')::date,(select max(submitted_at)::date from survey_reports where rfi_id=r.id),current_date);
  due:=(base_date+make_interval(months=>interval_m))::date;
  update survey_schedules set last_completed_date=base_date,next_due_date=due,window_start=(due-due_window_days_before)::date,window_end=(due+window_days_after)::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=r.id,cycle_completed_at=now(),cycle_number=cycle_number+1,intent_action='CREATE_IN_SERVICE_RFI',updated_at=now() where id=s.id returning * into s;
  perform epas_refresh_vessel_survey_status_v26(r.vessel_id);
  perform epas_audit(r.project_id,'IN_SERVICE_CYCLE_COMPLETED','rfi',r.id,'system','SCHEDULED','Current In-Service cycle complete; next cycle scheduled',jsonb_build_object('schedule_id',s.id,'cycle_number',s.cycle_number,'next_due_date',s.next_due_date));
  return s;
end;$$;
grant execute on function epas_mark_in_service_cycle_complete(uuid) to authenticated;

-- ================================================================
-- 21. Final security policies on v2.6 tables
-- ================================================================
alter table survey_scope_acknowledgements enable row level security;
alter table survey_execution_basis_versions enable row level security;
alter table survey_execution_declarations enable row level security;
alter table survey_checklist_definitions enable row level security;
alter table survey_checklist_definition_items enable row level security;
alter table certificate_decision_acknowledgement_versions enable row level security;
alter table survey_schedule_basis_history enable row level security;
alter table scheduler_runs enable row level security;
alter table survey_notification_policy enable row level security;
alter table survey_drawing_impact_decision_history enable row level security;

-- Select policies are intentionally project-scoped. Writes are RPC-only.
drop policy if exists scope_ack_select_v26 on survey_scope_acknowledgements;
create policy scope_ack_select_v26 on survey_scope_acknowledgements for select to authenticated using (exists(select 1 from rfis r where r.id=survey_scope_acknowledgements.rfi_id and epas_is_project_member(r.project_id)));
drop policy if exists scope_ack_write_v26 on survey_scope_acknowledgements;
create policy scope_ack_write_v26 on survey_scope_acknowledgements for all to authenticated using(false) with check(false);

drop policy if exists basis_versions_select_v26 on survey_execution_basis_versions;
create policy basis_versions_select_v26 on survey_execution_basis_versions for select to authenticated using (exists(select 1 from rfis r where r.id=survey_execution_basis_versions.rfi_id and epas_is_project_member(r.project_id)));
drop policy if exists basis_versions_write_v26 on survey_execution_basis_versions;
create policy basis_versions_write_v26 on survey_execution_basis_versions for all to authenticated using(false) with check(false);

drop policy if exists declaration_select_v26 on survey_execution_declarations;
create policy declaration_select_v26 on survey_execution_declarations for select to authenticated using (surveyor_id=auth.uid() or exists(select 1 from rfis r where r.id=survey_execution_declarations.rfi_id and (r.assigned_dm_id=auth.uid() or epas_has_role('gm'))));
drop policy if exists declaration_write_v26 on survey_execution_declarations;
create policy declaration_write_v26 on survey_execution_declarations for all to authenticated using(false) with check(false);

drop policy if exists schedule_basis_select_v26 on survey_schedule_basis_history;
create policy schedule_basis_select_v26 on survey_schedule_basis_history for select to authenticated using (exists(select 1 from survey_schedules s where s.id=survey_schedule_basis_history.schedule_id and epas_is_project_member(s.project_id)));
drop policy if exists schedule_basis_write_v26 on survey_schedule_basis_history;
create policy schedule_basis_write_v26 on survey_schedule_basis_history for all to authenticated using(false) with check(false);

drop policy if exists scheduler_runs_select_v26 on scheduler_runs;
create policy scheduler_runs_select_v26 on scheduler_runs for select to authenticated using (epas_has_role('gm') or epas_has_role('dm'));
drop policy if exists scheduler_runs_write_v26 on scheduler_runs;
create policy scheduler_runs_write_v26 on scheduler_runs for all to authenticated using(false) with check(false);

-- Checklist definitions are internal system reference data; participants can read,
-- but only migrations/service role should modify templates.
drop policy if exists checklist_def_select_v26 on survey_checklist_definitions;
create policy checklist_def_select_v26 on survey_checklist_definitions for select to authenticated using (true);
drop policy if exists checklist_def_write_v26 on survey_checklist_definitions;
create policy checklist_def_write_v26 on survey_checklist_definitions for all to authenticated using(false) with check(false);
drop policy if exists checklist_def_item_select_v26 on survey_checklist_definition_items;
create policy checklist_def_item_select_v26 on survey_checklist_definition_items for select to authenticated using (true);
drop policy if exists checklist_def_item_write_v26 on survey_checklist_definition_items;
create policy checklist_def_item_write_v26 on survey_checklist_definition_items for all to authenticated using(false) with check(false);

-- Keep notification policy inaccessible for stakeholder clients.
drop policy if exists notification_policy_select_v26 on survey_notification_policy;
create policy notification_policy_select_v26 on survey_notification_policy for select to authenticated using (epas_has_role('gm') or epas_has_role('dm'));
drop policy if exists notification_policy_write_v26 on survey_notification_policy;
create policy notification_policy_write_v26 on survey_notification_policy for all to authenticated using(false) with check(false);

-- ================================================================
-- 22. Final direct-execution restrictions
-- ================================================================
revoke all on function epas_sync_survey_schedule(uuid) from authenticated;
revoke all on function epas_refresh_vessel_survey_status(uuid) from authenticated;
revoke all on function epas_refresh_project_phase_state(uuid) from authenticated;
revoke all on function epas_phase_gate_status(uuid,text) from authenticated;
revoke all on function epas_refresh_all_survey_schedules() from authenticated;
revoke all on function epas_generate_survey_due_notifications() from authenticated;

-- ================================================================
-- 23. Operational acceptance matrix metadata
-- ================================================================
create table if not exists workflow_acceptance_cases_v26 (
  case_code text primary key,
  role_name text not null,
  phase text,
  positive boolean not null,
  expected_result text not null,
  security_boundary text,
  created_at timestamptz not null default now()
);
insert into workflow_acceptance_cases_v26(case_code,role_name,phase,positive,expected_result,security_boundary) values
('GM_PLAN_ONLY','gm','plan_appraisal',true,'Plan-only project reaches scope completion after all mandatory Plan Appraisal gates pass','GM can govern project and certificate lifecycle'),
('SHIPYARD_NSC_RFI','shipyard','nsc_survey',true,'Shipyard can create NSC RFI only','Shipyard cannot create or read internal In-Service workflow'),
('SHIPYARD_IN_SERVICE_DENY','shipyard','in_service',false,'RFI creation rejected','No In-Service authority'),
('OWNER_IN_SERVICE_RFI','owner','in_service',true,'Owner can initiate current in-service cycle','Owner cannot create NSC RFI'),
('OWNER_NSC_DENY','owner','nsc_survey',false,'RFI creation rejected','No NSC authority'),
('SM_IN_SERVICE_RFI','ship_management','in_service',true,'Ship Management can initiate current in-service cycle','Ship Management cannot create NSC RFI'),
('DM_ASSIGN_ELIGIBLE_SURVEYOR','dm',null,true,'Only eligible/authorized/available Surveyor may be assigned','Project-scoped resource governance'),
('SURVEYOR_ACCEPT','surveyor',null,true,'Assignment must be explicitly accepted','Only assigned Surveyor'),
('SURVEYOR_SCOPE_ACK','surveyor',null,true,'Current scope version must be acknowledged','Only assigned Surveyor'),
('SURVEYOR_DRAWING_ACK','surveyor',null,true,'Exact immutable drawing package must be acknowledged','Only assigned Surveyor'),
('SURVEYOR_CHECKLIST','surveyor',null,true,'All mandatory checklist items must be complete','Only assigned Surveyor'),
('SURVEYOR_DECLARATION','surveyor',null,true,'Structured professional declaration required before report','Only assigned Surveyor'),
('DM_REVISION_IMPACT','dm',null,true,'Revision/hash change requires explicit no-impact or reissue decision','Assigned DM only'),
('CERTIFICATE_PACKAGE','gm',null,true,'Frozen decision package plus exact DM acknowledgement required','GM/DM scoped to project'),
('IN_SERVICE_RECURRENCE','system','in_service',true,'Completed cycle creates next due schedule without closing In-Service phase','Service scheduler only'),
('CROSS_PROJECT_TIMELINE','owner',null,false,'Timeline access to another project rejected','Project membership'),
('CROSS_PROJECT_SCHEDULE','owner',null,false,'Survey schedule access to another project rejected','Project membership'),
('EVIDENCE_WRONG_ACTION','ship_management',null,false,'Evidence for another user''s corrective action rejected','Assigned corrective action only')
on conflict(case_code) do update set expected_result=excluded.expected_result,security_boundary=excluded.security_boundary,positive=excluded.positive,role_name=excluded.role_name,phase=excluded.phase;


-- ================================================================
-- 24. Authoritative stakeholder RFI creation with schedule linkage
-- ================================================================
create or replace function epas_stakeholder_create_rfi(
  p_project_id uuid,p_vessel_id uuid,p_phase text,p_survey_type text,p_requested_date date,p_priority text,p_scope_note text
) returns rfis language plpgsql security definer set search_path=public as $$
declare v_role_name text; r rfis; code text; gate text; s survey_scopes; sched survey_schedules;
begin
  select role into v_role_name from profiles where id=auth.uid();
  if not exists(select 1 from rfi_creation_policy where role_name=v_role_name and phase=p_phase and allowed) then
    raise exception 'This role is not authorized to create this RFI type';
  end if;
  if not exists(select 1 from project_members where project_id=p_project_id and user_id=auth.uid() and active and role=v_role_name) then
    raise exception 'Not an active stakeholder member of this project';
  end if;
  if not exists(select 1 from vessels where id=p_vessel_id and project_id=p_project_id) then
    raise exception 'Vessel does not belong to project';
  end if;
  select status into gate from project_phase_control where project_id=p_project_id and phase=p_phase;
  if coalesce(gate,'LOCKED') not in ('READY','IN_PROGRESS') then
    raise exception 'Survey phase is not currently eligible: %',coalesce(gate,'LOCKED');
  end if;
  if coalesce(trim(p_scope_note),'')='' then raise exception 'Survey scope is required'; end if;
  if p_phase='in_service' then
    select * into sched from survey_schedules where project_id=p_project_id and vessel_id=p_vessel_id and phase='in_service' and active for update;
    if sched.id is not null and sched.current_rfi_id is not null and exists(select 1 from rfis x where x.id=sched.current_rfi_id and x.status not in ('certificate_issued','closed')) then
      raise exception 'An In-Service RFI is already open for the active survey cycle';
    end if;
  end if;
  code:='RFI-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(p_project_id,p_vessel_id,p_phase,p_survey_type,code,'pending_allocation',auth.uid(),coalesce(p_requested_date,current_date),p_priority,p_scope_note,v_role_name)
  returning * into r;
  insert into survey_scopes(rfi_id,scope_text,survey_type,phase,status,current_version)
  values(r.id,p_scope_note,p_survey_type,p_phase,'SUBMITTED',1)
  on conflict(rfi_id) do update set scope_text=excluded.scope_text,survey_type=excluded.survey_type,updated_at=now();
  insert into survey_scope_versions(rfi_id,version_no,scope_text,survey_type,phase,created_by)
  values(r.id,1,p_scope_note,p_survey_type,p_phase,auth.uid())
  on conflict(rfi_id,version_no) do nothing;
  if p_phase='in_service' and sched.id is not null then
    update survey_schedules set current_rfi_id=r.id,source_rfi_id=r.id,status='RFI_OPEN',current_cycle_started_at=now(),intent_action='RFI_OPEN',updated_at=now() where id=sched.id;
  end if;
  perform epas_audit(r.project_id,'STAKEHOLDER_RFI_CREATED','rfi',r.id,v_role_name,'pending_allocation',p_scope_note,
    jsonb_build_object('phase',p_phase,'policy_enforced',true,'schedule_id',(select id from survey_schedules where current_rfi_id=r.id limit 1)));
  return r;
end;$$;
grant execute on function epas_stakeholder_create_rfi(uuid,uuid,text,text,date,text,text) to authenticated;

-- ================================================================
-- 25. Complete live-acceptance helper functions for the seven roles
-- ================================================================
create or replace function epas_role_workflow_acceptance_summary(p_project_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare role_name text; pid uuid; summary jsonb;
begin
  select role into role_name from profiles where id=auth.uid();
  pid:=p_project_id;
  if pid is not null and not epas_is_project_member(pid) then raise exception 'Not authorized for project'; end if;
  summary:=jsonb_build_object(
    'role',role_name,
    'project_id',pid,
    'rfi_policy',coalesce((select jsonb_agg(to_jsonb(x) order by role_name,phase) from rfi_creation_policy x),'[]'::jsonb),
    'project_scope_state',case when pid is null then '{}'::jsonb else epas_project_scope_state(pid) end,
    'my_tasks',(select count(*) from workflow_tasks where to_user_id=auth.uid() and status in ('pending','accepted','in_progress')),
    'my_rfIs',(select count(*) from rfis where requested_by=auth.uid())
  );
  return summary;
end;$$;
grant execute on function epas_role_workflow_acceptance_summary(uuid) to authenticated;

commit;

-- Deployment note:
-- Configure Supabase Cron / scheduler once per environment, for example:
--   select cron.schedule('epas-survey-lifecycle-hourly','5 * * * *','select public.epas_scheduler_tick();');
-- The scheduler function itself rejects non-service_role execution.
