-- EPAS v2.4 — State-of-the-Art Lifecycle, Survey Scheduling, Immutable Handover & Audit Hardening
-- Cumulative after v2.3.
-- Purpose: close the remaining lifecycle/data-flow gaps identified in the v2.3 audit.
-- Business rules:
--   * Shipyard creates NSC RFIs only.
--   * Owner / Ship Management create In-Service RFIs only.
--   * Plan Appraisal is a prerequisite where selected.
--   * NSC is a prerequisite for In-Service where selected.
--   * In-Service is a continuing operational phase; completion of one survey cycle
--     does NOT complete the In-Service phase.
--   * Surveyor drawing handover is immutable at the exact revision/hash level.
--   * Certificate decisions are frozen into an auditable decision package.

begin;

create extension if not exists pgcrypto;

-- ================================================================
-- 23. Explicit survey scope / assignment / execution objects
-- ================================================================
create table if not exists survey_scopes (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null unique references rfis(id) on delete cascade,
  scope_version integer not null default 1,
  scope_text text not null,
  survey_type text not null,
  phase text not null check (phase in ('nsc_survey','in_service')),
  status text not null default 'LOCKED' check (status in ('DRAFT','SUBMITTED','LOCKED','AMENDMENT_REQUESTED','AMENDED','CANCELLED')),
  locked_at timestamptz,
  locked_by uuid references profiles(id),
  amended_at timestamptz,
  amended_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists survey_scope_amendments (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  requested_by uuid not null references profiles(id),
  requested_role text not null,
  reason text not null,
  proposed_scope text,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  decided_by uuid references profiles(id),
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now()
);

create table if not exists survey_assignments (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null unique references rfis(id) on delete cascade,
  surveyor_id uuid not null references profiles(id),
  assigned_by uuid not null references profiles(id),
  scheduled_date date,
  status text not null default 'ASSIGNED' check (status in ('ASSIGNED','ACCEPTED','IN_PROGRESS','COMPLETED','REASSIGNED','CANCELLED')),
  assigned_at timestamptz not null default now(),
  accepted_at timestamptz,
  completed_at timestamptz,
  reassigned_at timestamptz,
  notes text
);

create table if not exists survey_executions (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null unique references rfis(id) on delete cascade,
  assignment_id uuid references survey_assignments(id),
  surveyor_id uuid not null references profiles(id),
  phase text not null check (phase in ('nsc_survey','in_service')),
  started_at timestamptz,
  completed_at timestamptz,
  location text,
  attendance text,
  method text,
  conditions text,
  declaration text,
  status text not null default 'NOT_STARTED' check (status in ('NOT_STARTED','IN_PROGRESS','REPORT_SUBMITTED','DM_REVIEW','GM_REVIEW','COMPLETED','RETURNED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_survey_scopes_rfi on survey_scopes(rfi_id);
create index if not exists idx_survey_assignments_surveyor on survey_assignments(surveyor_id,status);
create index if not exists idx_survey_executions_phase on survey_executions(phase,status);

-- Backfill one scope/execution shell per existing RFI without changing workflow state.
insert into survey_scopes(rfi_id,scope_text,survey_type,phase,status,locked_at)
select r.id, coalesce(r.scope_note,'Scope inherited from RFI'), r.survey_type, r.phase,
       case when r.status in ('survey_in_progress','observations_logged','pending_gm_approval','approved_no_observations','approved_with_observations','certificate_issued','closed') then 'LOCKED' else 'SUBMITTED' end,
       case when r.status in ('survey_in_progress','observations_logged','pending_gm_approval','approved_no_observations','approved_with_observations','certificate_issued','closed') then r.updated_at end
from rfis r
where not exists(select 1 from survey_scopes s where s.rfi_id=r.id);

insert into survey_assignments(rfi_id,surveyor_id,assigned_by,scheduled_date,status)
select r.id,r.assigned_surveyor_id,coalesce(r.assigned_dm_id,r.requested_by),r.scheduled_date,
       case when r.status='survey_in_progress' then 'IN_PROGRESS' when r.status in ('observations_logged','pending_gm_approval','approved_no_observations','approved_with_observations','certificate_issued','closed') then 'COMPLETED' else 'ASSIGNED' end
from rfis r
where r.assigned_surveyor_id is not null
and not exists(select 1 from survey_assignments a where a.rfi_id=r.id);

insert into survey_executions(rfi_id,assignment_id,surveyor_id,phase,status,completed_at)
select r.id,a.id,r.assigned_surveyor_id,r.phase,
       case when r.status='survey_in_progress' then 'IN_PROGRESS' when r.status in ('observations_logged','pending_gm_approval','approved_no_observations','approved_with_observations','certificate_issued','closed') then 'COMPLETED' else 'NOT_STARTED' end,
       case when r.status in ('observations_logged','pending_gm_approval','approved_no_observations','approved_with_observations','certificate_issued','closed') then r.updated_at end
from rfis r left join survey_assignments a on a.rfi_id=r.id
where r.assigned_surveyor_id is not null
and not exists(select 1 from survey_executions e where e.rfi_id=r.id);

-- ================================================================
-- 24. Recurring In-Service survey schedule engine
-- ================================================================
create table if not exists survey_schedules (
  id uuid primary key default gen_random_uuid(),
  vessel_id uuid not null references vessels(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  survey_type text not null,
  phase text not null check (phase in ('nsc_survey','in_service')),
  interval_months integer,
  last_completed_date date,
  next_due_date date not null,
  window_start date,
  window_end date,
  status text not null default 'SCHEDULED' check (status in ('SCHEDULED','DUE_SOON','DUE','OVERDUE','RFI_OPEN','COMPLETED','SUSPENDED')),
  source_certificate_id uuid references certificates(id),
  source_rfi_id uuid references rfis(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists uq_active_vessel_survey_schedule on survey_schedules(vessel_id,phase) where active=true;
create index if not exists idx_survey_schedules_due on survey_schedules(next_due_date,status,active);

create table if not exists survey_schedule_events (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references survey_schedules(id) on delete cascade,
  event_type text not null,
  actor_id uuid references profiles(id),
  old_status text,
  new_status text,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ================================================================
-- 25. Immutable Surveyor drawing handover snapshot
-- ================================================================
alter table survey_rfi_drawings add column if not exists shared_revision integer;
alter table survey_rfi_drawings add column if not exists shared_document_id uuid references documents(id);
alter table survey_rfi_drawings add column if not exists shared_file_name text;
alter table survey_rfi_drawings add column if not exists shared_storage_path text;
alter table survey_rfi_drawings add column if not exists shared_sha256 text;
alter table survey_rfi_drawings add column if not exists shared_mime_type text;
alter table survey_rfi_drawings add column if not exists shared_size_bytes bigint;
alter table survey_rfi_drawings add column if not exists package_version integer not null default 1;
alter table survey_rfi_drawings add column if not exists package_state text not null default 'ACTIVE';
alter table survey_rfi_drawings drop constraint if exists survey_rfi_drawings_package_state_check;
alter table survey_rfi_drawings add constraint survey_rfi_drawings_package_state_check check(package_state in ('ACTIVE','REVOKED','SUPERSEDED','ARCHIVED'));

update survey_rfi_drawings s set
  shared_revision=d.revision,
  shared_document_id=d.document_id,
  shared_file_name=doc.file_name,
  shared_storage_path=doc.storage_path,
  shared_sha256=doc.sha256,
  shared_mime_type=doc.mime_type,
  shared_size_bytes=doc.file_size_bytes
from plan_drawings d join documents doc on doc.id=d.document_id
where d.id=s.drawing_id and s.shared_revision is null;

create table if not exists survey_drawing_handover_events (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references survey_rfi_drawings(id) on delete cascade,
  rfi_id uuid not null references rfis(id) on delete cascade,
  surveyor_id uuid not null references profiles(id),
  event_type text not null,
  revision integer,
  sha256 text,
  actor_id uuid references profiles(id),
  note text,
  created_at timestamptz not null default now()
);

-- Redefine assignment so the package freezes exact file identity at handover.
create or replace function epas_assign_surveyor_with_drawings(
  p_rfi_id uuid,p_surveyor_id uuid,p_scheduled_date date,p_drawing_ids uuid[],p_discipline text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r rfis; v_role text; gate text; n integer; did uuid; t workflow_tasks; note text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select role into v_role from profiles where id=auth.uid();
  if v_role<>'dm' then raise exception 'Only the Department Manager may assign a Surveyor'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null then raise exception 'RFI not found'; end if;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only the assigned Department Manager may assign this survey'; end if;
  if r.phase not in ('nsc_survey','in_service') then raise exception 'Invalid survey phase'; end if;
  if r.status not in ('allocated_to_dm','pending_allocation','sent_back_for_rework') then raise exception 'RFI is not ready for Surveyor assignment'; end if;
  select status into gate from project_phase_control where project_id=r.project_id and phase=r.phase;
  if coalesce(gate,'LOCKED') not in ('READY','IN_PROGRESS') then raise exception 'Survey phase is not open for assignment: %',coalesce(gate,'LOCKED'); end if;
  if not exists(select 1 from profiles where id=p_surveyor_id and role='surveyor') then raise exception 'Selected user is not a Surveyor'; end if;
  if not exists(select 1 from project_members where project_id=r.project_id and user_id=p_surveyor_id and active and role='surveyor') then raise exception 'Surveyor is not an active member of this project'; end if;
  select count(*) into n from plan_drawings where project_id=r.project_id and status='approved';
  if n>0 and coalesce(array_length(p_drawing_ids,1),0)=0 then raise exception 'Select relevant approved Plan Appraisal drawings'; end if;
  if coalesce(array_length(p_drawing_ids,1),0)>0 then
    select count(*) into n from plan_drawings where id=any(p_drawing_ids) and project_id=r.project_id and status='approved';
    if n<>array_length(p_drawing_ids,1) then raise exception 'Every shared drawing must be an approved drawing in this project'; end if;
  end if;
  update survey_rfi_drawings set revoked_at=now(),package_state='REVOKED' where rfi_id=r.id and revoked_at is null;
  if coalesce(array_length(p_drawing_ids,1),0)>0 then
    foreach did in array p_drawing_ids loop
      insert into survey_rfi_drawings(rfi_id,drawing_id,surveyor_id,granted_by,relevance_note,shared_revision,shared_document_id,shared_file_name,shared_storage_path,shared_sha256,shared_mime_type,shared_size_bytes,package_version,package_state)
      select r.id,did,p_surveyor_id,auth.uid(),coalesce(p_discipline,'Relevant approved Plan Appraisal drawing'),d.revision,d.document_id,doc.file_name,doc.storage_path,doc.sha256,doc.mime_type,doc.file_size_bytes,coalesce((select max(package_version)+1 from survey_rfi_drawings x where x.rfi_id=r.id),1),'ACTIVE'
      from plan_drawings d join documents doc on doc.id=d.document_id where d.id=did;
    end loop;
  end if;
  update rfis set assigned_surveyor_id=p_surveyor_id,scheduled_date=p_scheduled_date,status='survey_in_progress',updated_at=now() where id=r.id;
  insert into survey_assignments(rfi_id,surveyor_id,assigned_by,scheduled_date,status,assigned_at)
  values(r.id,p_surveyor_id,auth.uid(),p_scheduled_date,'ASSIGNED',now())
  on conflict(rfi_id) do update set surveyor_id=excluded.surveyor_id,assigned_by=excluded.assigned_by,scheduled_date=excluded.scheduled_date,status='ASSIGNED',assigned_at=now(),reassigned_at=now();
  insert into survey_executions(rfi_id,assignment_id,surveyor_id,phase,status,updated_at)
  select r.id,a.id,p_surveyor_id,r.phase,'NOT_STARTED',now() from survey_assignments a where a.rfi_id=r.id
  on conflict(rfi_id) do update set assignment_id=excluded.assignment_id,surveyor_id=excluded.surveyor_id,phase=excluded.phase,status='NOT_STARTED',updated_at=now();
  insert into survey_drawing_handover_events(package_id,rfi_id,surveyor_id,event_type,revision,sha256,actor_id,note)
  select s.id,r.id,p_surveyor_id,'HANDED_OVER',s.shared_revision,s.shared_sha256,auth.uid(),s.relevance_note from survey_rfi_drawings s where s.rfi_id=r.id and s.revoked_at is null;
  note:=format('%s assigned to Surveyor with immutable drawing package.',r.rfi_code);
  insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,rfi_id,created_at)
  values(r.project_id,'SURVEY_RFI_EXECUTION',auth.uid(),p_surveyor_id,'pending',note,r.id,now()) returning * into t;
  perform epas_audit(r.project_id,'SURVEY_DRAWING_PACKAGE_CREATED','rfi',r.id,'dm','surveyor_package_created',note,jsonb_build_object('immutable_snapshot',true,'rfi_id',r.id));
  return jsonb_build_object('rfi_id',r.id,'surveyor_id',p_surveyor_id,'drawing_count',(select count(*) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),'task_id',t.id);
end;$$;
grant execute on function epas_assign_surveyor_with_drawings(uuid,uuid,date,uuid[],text) to authenticated;

create or replace function epas_surveyor_drawing_package(p_rfi_id uuid)
returns table(package_id uuid,rfi_id uuid,drawing_id uuid,drawing_no text,title text,discipline text,revision integer,document_id uuid,file_name text,storage_path text,shared_sha256 text,shared_mime_type text,shared_size_bytes bigint,shared_at timestamptz,relevance_note text,package_state text)
language sql security definer set search_path=public stable as $$
 select s.id,s.rfi_id,d.id,d.drawing_no,d.title,d.discipline,s.shared_revision,s.shared_document_id,s.shared_file_name,s.shared_storage_path,s.shared_sha256,s.shared_mime_type,s.shared_size_bytes,s.granted_at,s.relevance_note,s.package_state
 from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id
 where s.rfi_id=p_rfi_id and s.surveyor_id=auth.uid() and s.revoked_at is null;
$$;
grant execute on function epas_surveyor_drawing_package(uuid) to authenticated;

-- ================================================================
-- 26. Certificate decision package — immutable issuance basis
-- ================================================================
create table if not exists certificate_decision_packages (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid references certificates(id) on delete set null,
  rfi_id uuid not null references rfis(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  vessel_id uuid not null references vessels(id) on delete cascade,
  package_version integer not null default 1,
  decision text not null check (decision in ('APPROVED','INTERIM','RETURNED')),
  frozen_at timestamptz not null default now(),
  frozen_by uuid not null references profiles(id),
  survey_snapshot jsonb not null default '{}'::jsonb,
  observation_snapshot jsonb not null default '[]'::jsonb,
  corrective_action_snapshot jsonb not null default '[]'::jsonb,
  drawing_package_snapshot jsonb not null default '[]'::jsonb,
  gm_decision_snapshot jsonb not null default '{} '::jsonb,
  dm_ack_snapshot jsonb not null default '{} '::jsonb
);
create unique index if not exists uq_cert_decision_package_version on certificate_decision_packages(rfi_id,package_version);

create or replace function epas_freeze_certificate_decision_package(p_rfi_id uuid,p_decision text)
returns certificate_decision_packages language plpgsql security definer set search_path=public as $$
declare r rfis; p projects; v certificate_decision_packages; ver integer; c uuid;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may freeze a certificate decision package'; end if;
  if p_decision not in ('APPROVED','INTERIM','RETURNED') then raise exception 'Invalid certificate decision'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null then raise exception 'RFI not found'; end if;
  select * into p from projects where id=r.project_id;
  select coalesce(max(package_version),0)+1 into ver from certificate_decision_packages where rfi_id=r.id;
  select id into c from certificates where rfi_id=r.id order by created_at desc limit 1;
  insert into certificate_decision_packages(certificate_id,rfi_id,project_id,vessel_id,package_version,decision,frozen_by,survey_snapshot,observation_snapshot,corrective_action_snapshot,drawing_package_snapshot,gm_decision_snapshot,dm_ack_snapshot)
  values(c,r.id,p.id,r.vessel_id,ver,p_decision,auth.uid(),
    coalesce((select to_jsonb(x) from survey_executions x where x.rfi_id=r.id order by created_at desc limit 1),'{}'::jsonb),
    coalesce((select jsonb_agg(to_jsonb(o)) from observations o where o.rfi_id=r.id),'[]'::jsonb),
    coalesce((select jsonb_agg(to_jsonb(ca)) from corrective_actions ca where ca.rfi_id=r.id),'[]'::jsonb),
    coalesce((select jsonb_agg(to_jsonb(s)) from survey_rfi_drawings s where s.rfi_id=r.id and s.revoked_at is null),'[]'::jsonb),
    coalesce((select to_jsonb(g) from gm_decisions g where g.rfi_id=r.id order by decided_at desc limit 1),'{}'::jsonb),
    coalesce((select jsonb_build_object('acknowledged',true,'actor',auth.uid()) where exists(select 1 from profiles where id=auth.uid() and role='dm')),'{}'::jsonb)) returning * into v;
  perform epas_audit(r.project_id,'CERTIFICATE_DECISION_PACKAGE_FROZEN','rfi',r.id,'gm',p_decision,'Immutable certificate decision basis created',jsonb_build_object('package_id',v.id,'package_version',ver));
  return v;
end;$$;
grant execute on function epas_freeze_certificate_decision_package(uuid,text) to authenticated;

-- ================================================================
-- 27. Observation evidence at exact observation level
-- ================================================================
create table if not exists observation_evidence (
  id uuid primary key default gen_random_uuid(),
  observation_id uuid not null references observations(id) on delete cascade,
  corrective_action_id uuid references corrective_actions(id) on delete set null,
  uploaded_by uuid not null references profiles(id),
  file_name text not null,
  storage_path text not null,
  sha256 text,
  mime_type text,
  size_bytes bigint,
  evidence_type text not null default 'CORRECTIVE_EVIDENCE',
  created_at timestamptz not null default now()
);
create index if not exists idx_observation_evidence_obs on observation_evidence(observation_id,created_at desc);

-- ================================================================
-- 28. Central RFI creation policy + lifecycle amendment control
-- ================================================================
create table if not exists rfi_creation_policy (
  id uuid primary key default gen_random_uuid(),
  role_name text not null,
  phase text not null,
  allowed boolean not null default true,
  description text,
  unique(role_name,phase)
);
insert into rfi_creation_policy(role_name,phase,allowed,description) values
('shipyard','nsc_survey',true,'Shipyard may initiate NSC Survey RFI'),
('shipyard','in_service',false,'Shipyard may not initiate In-Service RFI'),
('owner','nsc_survey',false,'Owner may not initiate NSC RFI'),
('owner','in_service',true,'Owner may initiate In-Service RFI'),
('ship_management','nsc_survey',false,'Ship Management may not initiate NSC RFI'),
('ship_management','in_service',true,'Ship Management may initiate In-Service RFI')
on conflict(role_name,phase) do update set allowed=excluded.allowed,description=excluded.description;

create or replace function epas_stakeholder_create_rfi(p_project_id uuid,p_vessel_id uuid,p_phase text,p_survey_type text,p_requested_date date,p_priority text,p_scope_note text)
returns rfis language plpgsql security definer set search_path=public as $$
declare v_role_name text; r rfis; code text; gate text;
begin
  select role into v_role_name from profiles where id=auth.uid();
  if not exists(select 1 from rfi_creation_policy where role_name=v_role_name and phase=p_phase and allowed) then raise exception 'This role is not authorized to create this RFI type'; end if;
  if not exists(select 1 from project_members where project_id=p_project_id and user_id=auth.uid() and active and role=v_role_name) then raise exception 'Not an active stakeholder member of this project'; end if;
  if not exists(select 1 from vessels where id=p_vessel_id and project_id=p_project_id) then raise exception 'Vessel does not belong to project'; end if;
  select status into gate from project_phase_control where project_id=p_project_id and phase=p_phase;
  if coalesce(gate,'LOCKED') not in ('READY','IN_PROGRESS') then raise exception 'Survey phase is not currently eligible: %',coalesce(gate,'LOCKED'); end if;
  if coalesce(trim(p_scope_note),'')='' then raise exception 'Survey scope is required'; end if;
  code:='RFI-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(p_project_id,p_vessel_id,p_phase,p_survey_type,code,'pending_allocation',auth.uid(),coalesce(p_requested_date,current_date),p_priority,p_scope_note,v_role_name) returning * into r;
  insert into survey_scopes(rfi_id,scope_text,survey_type,phase,status) values(r.id,p_scope_note,p_survey_type,p_phase,'SUBMITTED') on conflict(rfi_id) do update set scope_text=excluded.scope_text,survey_type=excluded.survey_type,updated_at=now();
  perform epas_audit(r.project_id,'STAKEHOLDER_RFI_CREATED','rfi',r.id,v_role_name,'pending_allocation',p_scope_note,jsonb_build_object('phase',p_phase,'policy_enforced',true));
  return r;
end;$$;
grant execute on function epas_stakeholder_create_rfi(uuid,uuid,text,text,date,text,text) to authenticated;

create or replace function epas_request_rfi_scope_amendment(p_rfi_id uuid,p_reason text,p_proposed_scope text default null)
returns survey_scope_amendments language plpgsql security definer set search_path=public as $$
declare r rfis; role_name text; a survey_scope_amendments;
begin
  select role into role_name from profiles where id=auth.uid();
  select * into r from rfis where id=p_rfi_id for update;
  if r.id is null then raise exception 'RFI not found'; end if;
  if r.requested_by<>auth.uid() then raise exception 'Only the RFI requester may request an amendment'; end if;
  if r.status not in ('pending_allocation','allocated_to_dm','sent_back_for_rework') then raise exception 'Scope is locked after survey execution begins'; end if;
  if coalesce(trim(p_reason),'')='' then raise exception 'Amendment reason is required'; end if;
  insert into survey_scope_amendments(rfi_id,requested_by,requested_role,reason,proposed_scope) values(r.id,auth.uid(),role_name,p_reason,p_proposed_scope) returning * into a;
  update survey_scopes set status='AMENDMENT_REQUESTED',updated_at=now() where rfi_id=r.id;
  perform epas_audit(r.project_id,'RFI_SCOPE_AMENDMENT_REQUESTED','rfi',r.id,role_name,'AMENDMENT_REQUESTED',p_reason,jsonb_build_object('proposed_scope',p_proposed_scope));
  return a;
end;$$;
grant execute on function epas_request_rfi_scope_amendment(uuid,text,text) to authenticated;

create or replace function epas_dm_decide_rfi_scope_amendment(p_amendment_id uuid,p_approve boolean,p_note text)
returns survey_scope_amendments language plpgsql security definer set search_path=public as $$
declare a survey_scope_amendments; r rfis; s survey_scopes;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide scope amendments'; end if;
  select * into a from survey_scope_amendments where id=p_amendment_id for update;
  if a.status<>'PENDING' then raise exception 'Amendment already decided'; end if;
  select * into r from rfis where id=a.rfi_id for update;
  if p_approve then
    update survey_scopes set scope_text=coalesce(a.proposed_scope,scope_text),scope_version=scope_version+1,status='SUBMITTED',amended_at=now(),amended_by=auth.uid(),updated_at=now() where rfi_id=r.id returning * into s;
    update rfis set scope_note=s.scope_text,updated_at=now() where id=r.id;
    update survey_scope_amendments set status='APPROVED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  else
    update survey_scopes set status='LOCKED',updated_at=now() where rfi_id=r.id;
    update survey_scope_amendments set status='REJECTED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  end if;
  select * into a from survey_scope_amendments where id=a.id;
  perform epas_audit(r.project_id,'RFI_SCOPE_AMENDMENT_DECIDED','rfi',r.id,'dm',a.status,coalesce(p_note,''),jsonb_build_object('amendment_id',a.id));
  return a;
end;$$;
grant execute on function epas_dm_decide_rfi_scope_amendment(uuid,boolean,text) to authenticated;

-- ================================================================
-- 29. In-Service is a continuing phase; survey cycles are separate
-- ================================================================
create or replace function epas_refresh_project_phase_state(p_project_id uuid)
returns setof project_phase_control language plpgsql security definer set search_path=public as $$
declare p text; s text; g boolean; n text; phases text[]; seq integer; prev_phase text; prev_status text; old_started timestamptz; old_completed timestamptz;
begin
  select phases into phases from projects where id=p_project_id;
  if phases is null then raise exception 'Project not found'; end if;
  foreach p in array array['plan_appraisal','nsc_survey','in_service'] loop
    seq:=case p when 'plan_appraisal' then 1 when 'nsc_survey' then 2 else 3 end;
    if not(p=any(phases)) then
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note) values(p_project_id,p,seq,'NOT_APPLICABLE',false,p||' not selected')
      on conflict(project_id,phase) do update set status='NOT_APPLICABLE',gate_passed=false,gate_note=excluded.gate_note,updated_at=now();
    else
      select status,gate_passed,note into s,g,n from epas_phase_gate_status(p_project_id,p) limit 1;
      if p='in_service' then
        -- In-Service is operationally continuous. Once the prerequisite gate has
        -- opened, the phase remains IN_PROGRESS even when the latest survey cycle closes.
        if 'nsc_survey'=any(phases) then
          select status into prev_status from project_phase_control where project_id=p_project_id and phase='nsc_survey';
        elsif 'plan_appraisal'=any(phases) then
          select status into prev_status from project_phase_control where project_id=p_project_id and phase='plan_appraisal';
        end if;
        if exists(select 1 from rfis r where r.project_id=p_project_id and r.phase='in_service' and r.status in ('certificate_issued','closed')) then
          if prev_status is null or prev_status='COMPLETED' then s:='IN_PROGRESS'; g:=true; n:='In-Service operational phase remains active; individual survey cycles are tracked separately'; end if;
        elsif coalesce(prev_status,'')<>'COMPLETED' and prev_status is not null then
          s:='LOCKED'; g:=false; n:='Waiting for prerequisite phase completion';
        end if;
      elsif p='nsc_survey' and 'plan_appraisal'=any(phases) then
        select status into prev_status from project_phase_control where project_id=p_project_id and phase='plan_appraisal';
        if coalesce(prev_status,'')<>'COMPLETED' then s:='LOCKED'; g:=false; n:='Waiting for Plan Appraisal completion'; end if;
      end if;
      select started_at,completed_at into old_started,old_completed from project_phase_control where project_id=p_project_id and phase=p;
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note,started_at,completed_at)
      values(p_project_id,p,seq,s,g,n,case when s in ('IN_PROGRESS','COMPLETED') then coalesce(old_started,now()) end,case when p<>'in_service' and s='COMPLETED' then coalesce(old_completed,now()) end)
      on conflict(project_id,phase) do update set status=excluded.status,gate_passed=excluded.gate_passed,gate_note=excluded.gate_note,started_at=excluded.started_at,completed_at=excluded.completed_at,updated_at=now();
    end if;
  end loop;
  update projects set current_phase=(select pc.phase from project_phase_control pc where pc.project_id=p_project_id and pc.status in ('READY','IN_PROGRESS') order by pc.sequence_no limit 1), current_phase_status=(select pc.status from project_phase_control pc where pc.project_id=p_project_id and pc.status in ('READY','IN_PROGRESS') order by pc.sequence_no limit 1),updated_at=now() where id=p_project_id;
  return query select * from project_phase_control where project_id=p_project_id order by sequence_no;
end;$$;
grant execute on function epas_refresh_project_phase_state(uuid) to authenticated;

-- ================================================================
-- 30. Vessel status engine + recurring schedule / reminders
-- ================================================================
create or replace function epas_refresh_vessel_survey_status(p_vessel_id uuid)
returns vessels language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; s text:='NOT_STARTED'; ph text; next_due date; last_date date; last_phase text; open_obs integer; active_in boolean; active_nsc boolean; nsc_done boolean; in_done boolean; prev text;
begin
 select * into v from vessels where id=p_vessel_id for update; if v.id is null then raise exception 'Vessel not found'; end if; select * into p from projects where id=v.project_id;
 select exists(select 1 from rfis where vessel_id=v.id and phase='nsc_survey' and status not in ('certificate_issued','closed')), exists(select 1 from rfis where vessel_id=v.id and phase='nsc_survey' and status in ('certificate_issued','closed')) into active_nsc,nsc_done;
 select exists(select 1 from rfis where vessel_id=v.id and phase='in_service' and status not in ('certificate_issued','closed')), exists(select 1 from rfis where vessel_id=v.id and phase='in_service' and status in ('certificate_issued','closed')) into active_in,in_done;
 select count(*) into open_obs from observations o join rfis r on r.id=o.rfi_id where r.vessel_id=v.id and o.status='open';
 select max(c.expiry_date) into next_due from certificates c where c.vessel_id=v.id and c.status in ('active','expiring');
 select max(coalesce(r.scheduled_date,r.requested_date)),(array_agg(r.phase order by coalesce(r.scheduled_date,r.requested_date) desc))[1] into last_date,last_phase from rfis r where r.vessel_id=v.id and r.status in ('certificate_issued','closed');
 if p.status='closed' then s:='PROJECT_CLOSED';
 elsif active_in then s:='IN_SERVICE_IN_PROGRESS'; ph:='in_service';
 elsif in_done and open_obs>0 then s:='OBSERVATIONS_OPEN'; ph:='in_service';
 elsif 'in_service'=any(p.phases) and in_done then s:='IN_SERVICE_COMPLETE'; ph:='in_service';
 elsif active_nsc then s:='NSC_IN_PROGRESS'; ph:='nsc_survey';
 elsif nsc_done then s:='CLASS_ACTIVE'; ph:='nsc_survey';
 elsif 'in_service'=any(p.phases) then s:='IN_SERVICE_DUE'; ph:='in_service';
 elsif 'nsc_survey'=any(p.phases) then s:='NSC_DUE'; ph:='nsc_survey';
 elsif 'plan_appraisal'=any(p.phases) then s:='PLAN_APPRAISAL'; ph:='plan_appraisal';
 end if;
 update vessels set survey_status=s,survey_status_updated_at=now(),next_survey_due=next_due,last_survey_date=last_date,last_survey_phase=last_phase,class_status=case when nsc_done or exists(select 1 from certificates c where c.vessel_id=v.id and c.status in ('active','expiring')) then 'CLASS_ACTIVE' else class_status end where id=v.id returning * into v;
 if v.survey_status is distinct from s then insert into vessel_survey_status_history(vessel_id,project_id,status,phase,source_type,source_id,note) values(v.id,v.project_id,s,ph,'SYSTEM',null,'Central survey status engine'); end if;
 return v;
end;$$;
grant execute on function epas_refresh_vessel_survey_status(uuid) to authenticated;

create or replace function epas_sync_survey_schedule(p_vessel_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare v vessels; p projects; c certificates; sid uuid; cnt integer:=0; due date; months integer:=12;
begin
 select * into v from vessels where id=p_vessel_id; if v.id is null then raise exception 'Vessel not found'; end if; select * into p from projects where id=v.project_id;
 select * into c from certificates where vessel_id=v.id and status in ('active','expiring') order by expiry_date desc limit 1;
 if c.id is not null and 'in_service'=any(p.phases) then
   due:=c.expiry_date;
   insert into survey_schedules(vessel_id,project_id,survey_type,phase,interval_months,last_completed_date,next_due_date,window_start,window_end,status,source_certificate_id,source_rfi_id,active)
   values(v.id,v.project_id,'Scheduled In-Service Survey','in_service',months,(select max(issue_date) from certificates where vessel_id=v.id),due,due-interval '90 days',due+interval '30 days',case when due<current_date then 'OVERDUE' when due<=current_date+30 then 'DUE' when due<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,c.id,c.rfi_id,true)
   on conflict(vessel_id,phase) where active=true do update set next_due_date=excluded.next_due_date,window_start=excluded.window_start,window_end=excluded.window_end,status=excluded.status,source_certificate_id=excluded.source_certificate_id,source_rfi_id=excluded.source_rfi_id,updated_at=now();
   cnt:=cnt+1;
 end if;
 return cnt;
end;$$;
grant execute on function epas_sync_survey_schedule(uuid) to authenticated;

create or replace function epas_refresh_all_survey_schedules()
returns integer language plpgsql security definer set search_path=public as $$
declare v record; n integer:=0; st text;
begin
 for v in select id from vessels loop
   n:=n+epas_sync_survey_schedule(v.id);
 end loop;
 update survey_schedules set status=case when exists(select 1 from rfis r where r.id=survey_schedules.source_rfi_id and r.status not in ('certificate_issued','closed')) then 'RFI_OPEN' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,updated_at=now() where active=true;
 return n;
end;$$;
grant execute on function epas_refresh_all_survey_schedules() to authenticated;

create or replace function epas_survey_schedule_queue(p_project_id uuid default null)
returns table(schedule_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,next_due_date date,window_start date,window_end date,status text,days_to_due integer,rfi_id uuid)
language sql security definer set search_path=public stable as $$
 select s.id,s.vessel_id,v.name,s.phase,s.survey_type,s.next_due_date,s.window_start,s.window_end,s.status,(s.next_due_date-current_date),r.id
 from survey_schedules s join vessels v on v.id=s.vessel_id left join rfis r on r.id=s.source_rfi_id
 where s.active and (p_project_id is null or s.project_id=p_project_id)
 order by s.next_due_date;
$$;
grant execute on function epas_survey_schedule_queue(uuid) to authenticated;

-- ================================================================
-- 31. Lifecycle event timeline + notification generation
-- ================================================================
create table if not exists lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references projects(id) on delete cascade,
  vessel_id uuid references vessels(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  event_type text not null,
  actor_id uuid references profiles(id),
  from_state text,
  to_state text,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_lifecycle_events_project on lifecycle_events(project_id,created_at desc);
create index if not exists idx_lifecycle_events_entity on lifecycle_events(entity_type,entity_id,created_at desc);

create or replace function epas_record_lifecycle_event(p_project_id uuid,p_vessel_id uuid,p_entity_type text,p_entity_id uuid,p_event_type text,p_from text,p_to text,p_note text,p_metadata jsonb default '{}'::jsonb)
returns lifecycle_events language plpgsql security definer set search_path=public as $$
declare e lifecycle_events;
begin
 insert into lifecycle_events(project_id,vessel_id,entity_type,entity_id,event_type,actor_id,from_state,to_state,note,metadata) values(p_project_id,p_vessel_id,p_entity_type,p_entity_id,p_event_type,auth.uid(),p_from,p_to,p_note,coalesce(p_metadata,'{}'::jsonb)) returning * into e;
 return e;
end;$$;
grant execute on function epas_record_lifecycle_event(uuid,uuid,text,uuid,text,text,text,jsonb) to authenticated;

create or replace function epas_project_timeline(p_project_id uuid,p_limit integer default 200)
returns table(created_at timestamptz,event_type text,entity_type text,entity_id uuid,actor_id uuid,from_state text,to_state text,note text,metadata jsonb)
language sql security definer set search_path=public stable as $$
 select created_at,event_type,entity_type,entity_id,actor_id,from_state,to_state,note,metadata from lifecycle_events where project_id=p_project_id
 union all
 select created_at,action,'audit',id,actor_id,null,null,null,details from audit_log where project_id=p_project_id
 order by created_at desc limit p_limit;
$$;
grant execute on function epas_project_timeline(uuid,integer) to authenticated;

create or replace function epas_generate_survey_due_notifications()
returns integer language plpgsql security definer set search_path=public as $$
declare s record; m record; n integer:=0;
begin
 update survey_schedules set status=case when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end where active=true;
 for s in select * from survey_schedules where active and status in ('DUE_SOON','DUE','OVERDUE') loop
   for m in select pm.user_id from project_members pm where pm.project_id=s.project_id and pm.active and pm.role in ('gm','dm','owner','ship_management','shipyard') loop
     if not exists(select 1 from notifications x where x.user_id=m.user_id and x.project_id=s.project_id and x.link_page='survey_schedule:'||s.id::text and x.created_at::date=current_date) then
       insert into notifications(user_id,title,body,project_id,link_page) values(m.user_id,case s.status when 'OVERDUE' then 'Survey overdue' when 'DUE' then 'Survey due' else 'Survey window approaching' end,format('%s %s survey due %s (%s days).',s.survey_type,(select name from vessels where id=s.vessel_id),s.next_due_date,(s.next_due_date-current_date)),s.project_id,'survey_schedule:'||s.id::text);
       n:=n+1;
     end if;
   end loop;
 end loop;
 return n;
end;$$;
grant execute on function epas_generate_survey_due_notifications() to authenticated;


-- ================================================================
-- 31A. Exact observation evidence and drawing-impact control
-- ================================================================
create or replace function epas_register_observation_evidence(
  p_observation_id uuid,p_corrective_action_id uuid,p_file_name text,p_storage_path text,
  p_sha256 text,p_mime_type text,p_size_bytes bigint,p_evidence_type text default 'CORRECTIVE_EVIDENCE'
) returns observation_evidence language plpgsql security definer set search_path=public as $$
declare o observations; ca corrective_actions; e observation_evidence;
begin
  select * into o from observations where id=p_observation_id for update;
  if o.id is null then raise exception 'Observation not found'; end if;
  if p_corrective_action_id is not null then
    select * into ca from corrective_actions where id=p_corrective_action_id;
    if ca.id is null or ca.rfi_id<>o.rfi_id then raise exception 'Corrective action is not linked to this observation RFI'; end if;
    if not exists(select 1 from corrective_action_observations where corrective_action_id=ca.id and observation_id=o.id) then raise exception 'Evidence must be linked to an exact corrective-action observation pair'; end if;
  end if;
  if not epas_has_role('ship_management') and not epas_has_role('surveyor') and not epas_has_role('dm') then raise exception 'Role cannot submit observation evidence'; end if;
  insert into observation_evidence(observation_id,corrective_action_id,uploaded_by,file_name,storage_path,sha256,mime_type,size_bytes,evidence_type)
  values(o.id,p_corrective_action_id,auth.uid(),p_file_name,p_storage_path,p_sha256,p_mime_type,p_size_bytes,p_evidence_type) returning * into e;
  perform epas_audit((select project_id from rfis where id=o.rfi_id),'OBSERVATION_EVIDENCE_REGISTERED','observation',o.id,null,'evidence_registered',p_file_name,jsonb_build_object('evidence_id',e.id,'sha256',p_sha256));
  return e;
end;$$;
grant execute on function epas_register_observation_evidence(uuid,uuid,text,text,text,text,bigint,text) to authenticated;

create or replace function epas_survey_drawing_revision_impact(p_rfi_id uuid)
returns table(package_id uuid,drawing_id uuid,drawing_no text,shared_revision integer,current_revision integer,shared_sha256 text,current_sha256 text,impact text,recommendation text)
language sql security definer set search_path=public stable as $$
 select s.id,d.id,d.drawing_no,s.shared_revision,d.revision,s.shared_sha256,doc.sha256,
        case when s.shared_revision=d.revision and coalesce(s.shared_sha256,'')=coalesce(doc.sha256,'') then 'NO_CHANGE' else 'REVISION_CHANGED' end,
        case when s.shared_revision=d.revision and coalesce(s.shared_sha256,'')=coalesce(doc.sha256,'') then 'Continue with existing controlled package' else 'DM must review impact and explicitly reissue the new approved revision if required' end
 from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id join documents doc on doc.id=d.document_id
 where s.rfi_id=p_rfi_id and s.revoked_at is null;
$$;
grant execute on function epas_survey_drawing_revision_impact(uuid) to authenticated;

-- Enhanced authoritative Ship Register projection. Original first columns are preserved.
create or replace view ship_register as
select v.id as vessel_id,
       v.name as vessel_name,
       v.imo_number,
       v.flag_state,
       v.current_class,
       v.owner_company,
       c.cert_number as latest_cert_number,
       c.cert_type as latest_cert_type,
       c.issue_date as latest_cert_issue_date,
       coalesce(s.next_due_date,c.expiry_date) as next_due_date,
       (coalesce(s.next_due_date,c.expiry_date)-current_date) as days_until_due,
       c.status as latest_cert_status,
       v.class_status,
       v.survey_status,
       v.survey_status_updated_at,
       v.last_survey_date,
       v.last_survey_phase,
       v.next_survey_due as vessel_next_survey_due,
       s.status as schedule_status,
       s.next_due_date as scheduled_next_survey_date,
       s.window_start,
       s.window_end
from vessels v
left join lateral(select * from survey_schedules ss where ss.vessel_id=v.id and ss.active order by ss.next_due_date limit 1) s on true
left join lateral(select * from certificates cc where cc.vessel_id=v.id order by cc.issue_date desc limit 1) c on true;

-- ================================================================
-- 32. Lifecycle triggers: keep phase, vessel, schedule and timeline coherent
-- ================================================================
create or replace function epas_lifecycle_sync_rfi()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_phase text; old_s text; new_s text;
begin
 old_s:=case when tg_op='INSERT' then null else old.status end; new_s:=new.status;
 perform epas_refresh_project_phase_state(new.project_id);
 perform epas_refresh_vessel_survey_status(new.vessel_id);
 if new.phase='in_service' and new.status in ('certificate_issued','closed') then perform epas_sync_survey_schedule(new.vessel_id); end if;
 perform epas_record_lifecycle_event(new.project_id,new.vessel_id,'rfi',new.id,'RFI_STATE_CHANGED',old_s,new_s,'RFI lifecycle state updated',jsonb_build_object('phase',new.phase,'rfi_code',new.rfi_code));
 return new;
end;$$;
drop trigger if exists trg_epas_lifecycle_rfi on rfis;
create trigger trg_epas_lifecycle_rfi after insert or update of status,assigned_surveyor_id,scheduled_date on rfis for each row execute function epas_lifecycle_sync_rfi();

create or replace function epas_lifecycle_sync_certificate()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform epas_refresh_vessel_survey_status(new.vessel_id);
 perform epas_sync_survey_schedule(new.vessel_id);
 perform epas_record_lifecycle_event(new.project_id,new.vessel_id,'certificate',new.id,'CERTIFICATE_STATE_CHANGED',case when tg_op='INSERT' then null else old.status end,new.status,'Certificate lifecycle updated',jsonb_build_object('cert_number',new.cert_number,'expiry_date',new.expiry_date));
 return new;
end;$$;
drop trigger if exists trg_epas_lifecycle_certificate on certificates;
create trigger trg_epas_lifecycle_certificate after insert or update of status,expiry_date,issue_date on certificates for each row execute function epas_lifecycle_sync_certificate();

create or replace function epas_lifecycle_sync_survey_report()
returns trigger language plpgsql security definer set search_path=public as $$
declare r rfis;
begin
 select * into r from rfis where id=new.rfi_id;
 insert into survey_executions(rfi_id,surveyor_id,phase,status,completed_at,location,attendance,declaration,updated_at)
 values(r.id,new.surveyor_id,r.phase,'REPORT_SUBMITTED',new.submitted_at,new.location,new.attendance,new.declaration,now())
 on conflict(rfi_id) do update set status='REPORT_SUBMITTED',completed_at=excluded.completed_at,location=excluded.location,attendance=excluded.attendance,declaration=excluded.declaration,updated_at=now();
 perform epas_record_lifecycle_event(r.project_id,r.vessel_id,'survey_report',new.id,'SURVEY_REPORT_SUBMITTED',null,'REPORT_SUBMITTED','Survey report submitted',jsonb_build_object('rfi_id',r.id));
 return new;
end;$$;
drop trigger if exists trg_epas_lifecycle_survey_report on survey_reports;
create trigger trg_epas_lifecycle_survey_report after insert on survey_reports for each row execute function epas_lifecycle_sync_survey_report();



create or replace function epas_lifecycle_sync_schedule()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status or new.next_due_date is distinct from old.next_due_date then
   insert into survey_schedule_events(schedule_id,event_type,actor_id,old_status,new_status,note,metadata)
   values(new.id,'SCHEDULE_STATE_CHANGED',auth.uid(),old.status,new.status,'Survey schedule updated',jsonb_build_object('next_due_date',new.next_due_date));
 end if;
 return new;
end;$$;
drop trigger if exists trg_epas_lifecycle_schedule on survey_schedules;
create trigger trg_epas_lifecycle_schedule after update on survey_schedules for each row execute function epas_lifecycle_sync_schedule();

-- ================================================================
-- Security: RLS on new business tables
-- ================================================================
alter table survey_scopes enable row level security;
alter table survey_scope_amendments enable row level security;
alter table survey_assignments enable row level security;
alter table survey_executions enable row level security;
alter table survey_schedules enable row level security;
alter table survey_schedule_events enable row level security;
alter table survey_drawing_handover_events enable row level security;
alter table certificate_decision_packages enable row level security;
alter table observation_evidence enable row level security;
alter table rfi_creation_policy enable row level security;
alter table lifecycle_events enable row level security;

drop policy if exists survey_scope_amendments_select_v24 on survey_scope_amendments;
create policy survey_scope_amendments_select_v24 on survey_scope_amendments for select to authenticated using (requested_by=auth.uid() or epas_has_role('dm') or epas_has_role('gm'));
drop policy if exists survey_scope_amendments_write_v24 on survey_scope_amendments;
create policy survey_scope_amendments_write_v24 on survey_scope_amendments for all to authenticated using(false) with check(false);

-- Controlled read access; all writes occur through SECURITY DEFINER workflow RPCs.
drop policy if exists survey_scopes_select_v24 on survey_scopes;
create policy survey_scopes_select_v24 on survey_scopes for select to authenticated using (exists(select 1 from rfis r where r.id=survey_scopes.rfi_id and epas_is_project_member(r.project_id)));
drop policy if exists survey_scopes_write_v24 on survey_scopes;
create policy survey_scopes_write_v24 on survey_scopes for all to authenticated using(false) with check(false);

drop policy if exists survey_assignments_select_v24 on survey_assignments;
create policy survey_assignments_select_v24 on survey_assignments for select to authenticated using (surveyor_id=auth.uid() or epas_has_role('dm') or epas_has_role('gm'));
drop policy if exists survey_assignments_write_v24 on survey_assignments;
create policy survey_assignments_write_v24 on survey_assignments for all to authenticated using(false) with check(false);

drop policy if exists survey_executions_select_v24 on survey_executions;
create policy survey_executions_select_v24 on survey_executions for select to authenticated using (surveyor_id=auth.uid() or epas_has_role('dm') or epas_has_role('gm'));
drop policy if exists survey_executions_write_v24 on survey_executions;
create policy survey_executions_write_v24 on survey_executions for all to authenticated using(false) with check(false);

drop policy if exists survey_schedules_select_v24 on survey_schedules;
create policy survey_schedules_select_v24 on survey_schedules for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists survey_schedules_write_v24 on survey_schedules;
create policy survey_schedules_write_v24 on survey_schedules for all to authenticated using(false) with check(false);

drop policy if exists cert_decision_select_v24 on certificate_decision_packages;
create policy cert_decision_select_v24 on certificate_decision_packages for select to authenticated using (epas_has_role('gm') or epas_has_role('dm'));
drop policy if exists cert_decision_write_v24 on certificate_decision_packages;
create policy cert_decision_write_v24 on certificate_decision_packages for all to authenticated using(false) with check(false);

drop policy if exists observation_evidence_select_v24 on observation_evidence;
create policy observation_evidence_select_v24 on observation_evidence for select to authenticated using (uploaded_by=auth.uid() or epas_has_role('dm') or epas_has_role('gm') or epas_has_role('surveyor') or epas_has_role('ship_management'));
drop policy if exists observation_evidence_write_v24 on observation_evidence;
create policy observation_evidence_write_v24 on observation_evidence for all to authenticated using(false) with check(false);

drop policy if exists lifecycle_events_select_v24 on lifecycle_events;
create policy lifecycle_events_select_v24 on lifecycle_events for select to authenticated using (epas_is_project_member(project_id));
drop policy if exists lifecycle_events_write_v24 on lifecycle_events;
create policy lifecycle_events_write_v24 on lifecycle_events for all to authenticated using(false) with check(false);

drop policy if exists rfi_creation_policy_select_v24 on rfi_creation_policy;
create policy rfi_creation_policy_select_v24 on rfi_creation_policy for select to authenticated using(true);
drop policy if exists rfi_creation_policy_write_v24 on rfi_creation_policy;
create policy rfi_creation_policy_write_v24 on rfi_creation_policy for all to authenticated using(false) with check(false);

-- Centralized policy is the authoritative rule. Do not permit direct RFI writes.
revoke insert,update,delete on rfis from authenticated;

commit;
