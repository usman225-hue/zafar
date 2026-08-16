-- EPAS v2.5 — Workflow Enforcement, Security Hardening, Immutable Survey Basis & Recurring In-Service Control
-- Cumulative after v2.4.
-- Purpose: close the remaining workflow gaps identified in the v2.4 audit.
-- Business rules:
--   * Shipyard creates NSC Survey RFIs ONLY.
--   * Owner / Ship Management create In-Service RFIs ONLY.
--   * Plan Appraisal gates NSC/In-Service when Plan Appraisal is part of project scope.
--   * NSC gates In-Service when NSC is part of project scope.
--   * In-Service is a continuing operational phase; survey cycles complete independently.
--   * Survey execution starts only after assignment acceptance, drawing handover acknowledgement,
--     mandatory pre-survey checklist completion and an explicit DM-approved drawing revision impact decision.
--   * Certificate issuance requires a frozen certificate decision package for the exact RFI.
--   * SECURITY DEFINER read/control RPCs enforce project membership explicitly.

begin;

create extension if not exists pgcrypto;

-- Reassert authoritative stakeholder RFI policy in the final cumulative migration.
insert into rfi_creation_policy(role_name,phase,allowed,description) values
('shipyard','nsc_survey',true,'Shipyard may initiate NSC Survey RFI'),
('shipyard','in_service',false,'Shipyard may not initiate In-Service RFI'),
('owner','nsc_survey',false,'Owner may not initiate NSC RFI'),
('owner','in_service',true,'Owner may initiate In-Service RFI'),
('ship_management','nsc_survey',false,'Ship Management may not initiate NSC RFI'),
('ship_management','in_service',true,'Ship Management may initiate In-Service RFI')
on conflict(role_name,phase) do update set allowed=excluded.allowed,description=excluded.description;

-- ================================================================
-- 1. Immutable scope/version snapshots
-- ================================================================
create table if not exists survey_scope_versions (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  version_no integer not null,
  scope_text text not null,
  survey_type text not null,
  phase text not null check (phase in ('nsc_survey','in_service')),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  source_amendment_id uuid references survey_scope_amendments(id) on delete set null,
  unique(rfi_id,version_no)
);
create index if not exists idx_survey_scope_versions_rfi on survey_scope_versions(rfi_id,version_no desc);

alter table survey_scopes add column if not exists current_version integer not null default 1;
alter table survey_executions add column if not exists scope_version integer;
alter table survey_executions add column if not exists drawing_package_version integer;
alter table survey_executions add column if not exists checklist_version integer;
alter table survey_executions add column if not exists assignment_accepted_at timestamptz;
alter table survey_executions add column if not exists drawing_package_acknowledged_at timestamptz;
alter table survey_executions add column if not exists checklist_completed_at timestamptz;
alter table survey_executions add column if not exists started_by uuid references profiles(id);

insert into survey_scope_versions(rfi_id,version_no,scope_text,survey_type,phase,created_by,created_at)
select s.rfi_id, coalesce(s.current_version,s.scope_version,1), s.scope_text, s.survey_type, s.phase, coalesce(s.amended_by,s.locked_by), coalesce(s.amended_at,s.locked_at,s.created_at)
from survey_scopes s
where not exists (
  select 1 from survey_scope_versions sv where sv.rfi_id=s.rfi_id and sv.version_no=coalesce(s.current_version,s.scope_version,1)
);

-- Freeze scope versions on amendment approval.
create or replace function epas_dm_decide_rfi_scope_amendment(p_amendment_id uuid,p_approve boolean,p_note text)
returns survey_scope_amendments language plpgsql security definer set search_path=public as $$
declare a survey_scope_amendments; r rfis; s survey_scopes; next_ver integer;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide scope amendments'; end if;
  select * into a from survey_scope_amendments where id=p_amendment_id for update;
  if a.id is null then raise exception 'Amendment not found'; end if;
  if a.status<>'PENDING' then raise exception 'Amendment already decided'; end if;
  select * into r from rfis where id=a.rfi_id for update;
  if r.assigned_dm_id <> auth.uid() then raise exception 'Only the assigned DM may decide this amendment'; end if;
  select * into s from survey_scopes where rfi_id=r.id for update;
  if p_approve then
    next_ver := coalesce(s.current_version,s.scope_version,1)+1;
    insert into survey_scope_versions(rfi_id,version_no,scope_text,survey_type,phase,created_by,source_amendment_id)
    values(r.id,next_ver,coalesce(nullif(a.proposed_scope,''),s.scope_text),s.survey_type,s.phase,auth.uid(),a.id);
    update survey_scopes set scope_text=coalesce(nullif(a.proposed_scope,''),scope_text),scope_version=next_ver,current_version=next_ver,status='SUBMITTED',amended_at=now(),amended_by=auth.uid(),updated_at=now() where rfi_id=r.id;
    update rfis set scope_note=coalesce(nullif(a.proposed_scope,''),scope_note),updated_at=now() where id=r.id;
    update survey_scope_amendments set status='APPROVED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  else
    update survey_scopes set status='LOCKED',updated_at=now() where rfi_id=r.id;
    update survey_scope_amendments set status='REJECTED',decided_by=auth.uid(),decided_at=now(),decision_note=p_note where id=a.id;
  end if;
  select * into a from survey_scope_amendments where id=a.id;
  perform epas_audit(r.project_id,'RFI_SCOPE_AMENDMENT_DECIDED','rfi',r.id,'dm',a.status,coalesce(p_note,''),jsonb_build_object('amendment_id',a.id,'scope_version',coalesce((select current_version from survey_scopes where rfi_id=r.id),1)));
  return a;
end;$$;
grant execute on function epas_dm_decide_rfi_scope_amendment(uuid,boolean,text) to authenticated;

-- ================================================================
-- 2. Freeze complete drawing metadata at handover
-- ================================================================
alter table survey_rfi_drawings add column if not exists shared_drawing_no text;
alter table survey_rfi_drawings add column if not exists shared_title text;
alter table survey_rfi_drawings add column if not exists shared_discipline text;
alter table survey_rfi_drawings add column if not exists handover_acknowledged_at timestamptz;
alter table survey_rfi_drawings add column if not exists handover_acknowledged_by uuid references profiles(id);

update survey_rfi_drawings s
set shared_drawing_no=d.drawing_no,
    shared_title=d.title,
    shared_discipline=d.discipline
from plan_drawings d
where d.id=s.drawing_id and s.shared_drawing_no is null;

-- ================================================================
-- 3. Revision impact decision is mandatory before survey start
-- ================================================================
create table if not exists survey_drawing_impact_decisions (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  package_id uuid not null references survey_rfi_drawings(id) on delete cascade,
  impact text not null check (impact in ('NO_IMPACT','REISSUE_REQUIRED','NOT_APPLICABLE')),
  note text not null,
  decided_by uuid not null references profiles(id),
  decided_at timestamptz not null default now(),
  unique(package_id)
);

create or replace function epas_dm_decide_drawing_revision_impact(p_package_id uuid,p_impact text,p_note text)
returns survey_drawing_impact_decisions language plpgsql security definer set search_path=public as $$
declare s survey_rfi_drawings; r rfis; d survey_drawing_impact_decisions; current_revision integer; current_sha text; impact_ok boolean;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may decide drawing revision impact'; end if;
  if p_impact not in ('NO_IMPACT','REISSUE_REQUIRED','NOT_APPLICABLE') then raise exception 'Invalid impact decision'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Decision note is required'; end if;
  select * into s from survey_rfi_drawings where id=p_package_id for update;
  if s.id is null then raise exception 'Drawing package not found'; end if;
  select * into r from rfis where id=s.rfi_id;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only the assigned DM may decide this package impact'; end if;
  select d.revision,doc.sha256 into current_revision,current_sha from plan_drawings d join documents doc on doc.id=d.document_id where d.id=s.drawing_id;
  impact_ok := s.shared_revision=current_revision and coalesce(s.shared_sha256,'')=coalesce(current_sha,'');
  if impact_ok and p_impact='REISSUE_REQUIRED' then raise exception 'No revision/hash change exists; REISSUE_REQUIRED is invalid'; end if;
  insert into survey_drawing_impact_decisions(rfi_id,package_id,impact,note,decided_by) values(r.id,s.id,p_impact,p_note,auth.uid()) on conflict(package_id) do update set impact=excluded.impact,note=excluded.note,decided_by=excluded.decided_by,decided_at=now() returning * into d;
  perform epas_audit(r.project_id,'SURVEY_DRAWING_IMPACT_DECIDED','rfi',r.id,'dm',p_impact,p_note,jsonb_build_object('package_id',s.id,'shared_revision',s.shared_revision,'current_revision',current_revision));
  return d;
end;$$;
grant execute on function epas_dm_decide_drawing_revision_impact(uuid,text,text) to authenticated;

-- Re-issue package to current approved revision for one drawing.
create or replace function epas_reissue_survey_drawing_package(p_package_id uuid)
returns survey_rfi_drawings language plpgsql security definer set search_path=public as $$
declare old_pkg survey_rfi_drawings; new_pkg survey_rfi_drawings; r rfis; d plan_drawings; doc documents; vnext integer;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may reissue a survey drawing package'; end if;
  select * into old_pkg from survey_rfi_drawings where id=p_package_id for update;
  if old_pkg.id is null then raise exception 'Package not found'; end if;
  select * into r from rfis where id=old_pkg.rfi_id;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may reissue this package'; end if;
  select * into d from plan_drawings where id=old_pkg.drawing_id and project_id=r.project_id and status='approved';
  if d.id is null then raise exception 'Current drawing revision is not approved'; end if;
  select * into doc from documents where id=d.document_id;
  update survey_rfi_drawings set package_state='SUPERSEDED',revoked_at=now() where id=old_pkg.id;
  select coalesce(max(package_version),0)+1 into vnext from survey_rfi_drawings where rfi_id=r.id;
  insert into survey_rfi_drawings(rfi_id,drawing_id,surveyor_id,granted_by,relevance_note,shared_revision,shared_document_id,shared_file_name,shared_storage_path,shared_sha256,shared_mime_type,shared_size_bytes,package_version,package_state,shared_drawing_no,shared_title,shared_discipline)
  values(r.id,d.id,old_pkg.surveyor_id,auth.uid(),old_pkg.relevance_note,d.revision,d.document_id,doc.file_name,doc.storage_path,doc.sha256,doc.mime_type,doc.file_size_bytes,vnext,'ACTIVE',d.drawing_no,d.title,d.discipline) returning * into new_pkg;
  insert into survey_drawing_handover_events(package_id,rfi_id,surveyor_id,event_type,revision,sha256,actor_id,note) values(new_pkg.id,r.id,new_pkg.surveyor_id,'REISSUED',new_pkg.shared_revision,new_pkg.shared_sha256,auth.uid(),'Drawing package reissued after approved revision impact review');
  return new_pkg;
end;$$;
grant execute on function epas_reissue_survey_drawing_package(uuid) to authenticated;

create or replace function epas_acknowledge_survey_drawing_package(p_rfi_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may acknowledge a drawing package'; end if;
  update survey_rfi_drawings set handover_acknowledged_at=now(),handover_acknowledged_by=auth.uid()
  where rfi_id=p_rfi_id and surveyor_id=auth.uid() and revoked_at is null;
  get diagnostics n=row_count;
  if n=0 then raise exception 'No active drawing package is assigned to this Surveyor'; end if;
  insert into survey_drawing_handover_events(package_id,rfi_id,surveyor_id,event_type,revision,sha256,actor_id,note)
  select s.id,s.rfi_id,s.surveyor_id,'ACKNOWLEDGED',s.shared_revision,s.shared_sha256,auth.uid(),'Surveyor acknowledged the controlled drawing package'
  from survey_rfi_drawings s where s.rfi_id=p_rfi_id and s.surveyor_id=auth.uid() and s.revoked_at is null;
  perform epas_audit((select project_id from rfis where id=p_rfi_id),'SURVEY_DRAWING_PACKAGE_ACKNOWLEDGED','rfi',p_rfi_id,'surveyor','ACKNOWLEDGED','Surveyor acknowledged controlled drawing package',jsonb_build_object('package_count',n));
  return n;
end;$$;
grant execute on function epas_acknowledge_survey_drawing_package(uuid) to authenticated;

-- ================================================================
-- 4. Resource governance is mandatory for Surveyor assignment
-- ================================================================
create or replace function epas_assign_surveyor_with_drawings(
  p_rfi_id uuid,p_surveyor_id uuid,p_scheduled_date date,p_drawing_ids uuid[],p_discipline text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare r rfis; v_role text; gate text; n integer; did uuid; t workflow_tasks; v_elig record;
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
  select * into v_elig from epas_resource_allocation_matrix(r.project_id,'surveyor',coalesce(p_discipline,'survey'),coalesce(p_scheduled_date,current_date)) where user_id=p_surveyor_id;
  if not found or not v_elig.authorization_ok or not v_elig.competency_ok or not v_elig.availability_ok then raise exception 'Selected Surveyor is not resource-eligible for the scheduled date'; end if;
  select count(*) into n from plan_drawings where project_id=r.project_id and status='approved';
  if n>0 and coalesce(array_length(p_drawing_ids,1),0)=0 then raise exception 'Select relevant approved Plan Appraisal drawings'; end if;
  if coalesce(array_length(p_drawing_ids,1),0)>0 then
    select count(*) into n from plan_drawings where id=any(p_drawing_ids) and project_id=r.project_id and status='approved';
    if n<>array_length(p_drawing_ids,1) then raise exception 'Every shared drawing must be an approved drawing in this project'; end if;
  end if;
  update survey_rfi_drawings set revoked_at=now(),package_state='REVOKED' where rfi_id=r.id and revoked_at is null;
  if coalesce(array_length(p_drawing_ids,1),0)>0 then
    foreach did in array p_drawing_ids loop
      insert into survey_rfi_drawings(rfi_id,drawing_id,surveyor_id,granted_by,relevance_note,shared_revision,shared_document_id,shared_file_name,shared_storage_path,shared_sha256,shared_mime_type,shared_size_bytes,package_version,package_state,shared_drawing_no,shared_title,shared_discipline)
      select r.id,did,p_surveyor_id,auth.uid(),'Relevant approved Plan Appraisal drawing',d.revision,d.document_id,doc.file_name,doc.storage_path,doc.sha256,doc.mime_type,doc.file_size_bytes,coalesce((select max(package_version)+1 from survey_rfi_drawings x where x.rfi_id=r.id),1),'ACTIVE',d.drawing_no,d.title,d.discipline
      from plan_drawings d join documents doc on doc.id=d.document_id where d.id=did;
    end loop;
  end if;
  update rfis set assigned_surveyor_id=p_surveyor_id,scheduled_date=p_scheduled_date,status='survey_in_progress',updated_at=now() where id=r.id;
  insert into survey_assignments(rfi_id,surveyor_id,assigned_by,scheduled_date,status,assigned_at) values(r.id,p_surveyor_id,auth.uid(),p_scheduled_date,'ASSIGNED',now())
  on conflict(rfi_id) do update set surveyor_id=excluded.surveyor_id,assigned_by=excluded.assigned_by,scheduled_date=excluded.scheduled_date,status='ASSIGNED',assigned_at=now(),accepted_at=null,reassigned_at=now();
  insert into survey_executions(rfi_id,assignment_id,surveyor_id,phase,status,scope_version,drawing_package_version,updated_at)
  select r.id,a.id,p_surveyor_id,r.phase,'NOT_STARTED',(select current_version from survey_scopes where rfi_id=r.id),(select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),now() from survey_assignments a where a.rfi_id=r.id
  on conflict(rfi_id) do update set assignment_id=excluded.assignment_id,surveyor_id=excluded.surveyor_id,phase=excluded.phase,status='NOT_STARTED',scope_version=excluded.scope_version,drawing_package_version=excluded.drawing_package_version,assignment_accepted_at=null,drawing_package_acknowledged_at=null,checklist_completed_at=null,updated_at=now();
  insert into survey_drawing_handover_events(package_id,rfi_id,surveyor_id,event_type,revision,sha256,actor_id,note)
  select s.id,r.id,p_surveyor_id,'HANDED_OVER',s.shared_revision,s.shared_sha256,auth.uid(),s.relevance_note from survey_rfi_drawings s where s.rfi_id=r.id and s.revoked_at is null;
  insert into resource_assignment_snapshots(project_id,entity_type,entity_id,resource_id,role,discipline,allocation_date,eligible,authorization_ok,competency_ok,availability_ok,workload_pct,conflict_note,captured_by)
  values(r.project_id,'survey_assignment',r.id,p_surveyor_id,'surveyor',p_discipline,p_scheduled_date,true,v_elig.authorization_ok,v_elig.competency_ok,v_elig.availability_ok,v_elig.workload_pct,null,auth.uid());
  insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,rfi_id,created_at) values(r.project_id,'SURVEY_RFI_EXECUTION',auth.uid(),p_surveyor_id,'pending',format('%s assigned to Surveyor. Assignment acceptance and package acknowledgement required before survey start.',r.rfi_code),r.id,now()) returning * into t;
  perform epas_audit(r.project_id,'SURVEY_DRAWING_PACKAGE_CREATED','rfi',r.id,'dm','surveyor_package_created','Surveyor assigned with resource eligibility and immutable drawing package',jsonb_build_object('immutable_snapshot',true,'rfi_id',r.id,'resource_snapshot',true));
  return jsonb_build_object('rfi_id',r.id,'surveyor_id',p_surveyor_id,'drawing_count',(select count(*) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),'task_id',t.id,'resource_eligible',true);
end;$$;
grant execute on function epas_assign_surveyor_with_drawings(uuid,uuid,date,uuid[],text) to authenticated;

-- ================================================================
-- 5. Assignment acceptance, pre-checklist, package acknowledgement, start gate
-- ================================================================
alter table survey_checklist_items add column if not exists checklist_version integer not null default 1;

create or replace function epas_surveyor_accept_assignment(p_rfi_id uuid,p_note text default null)
returns survey_assignments language plpgsql security definer set search_path=public as $$
declare a survey_assignments; r rfis;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may accept survey assignment'; end if;
  select * into a from survey_assignments where rfi_id=p_rfi_id for update;
  select * into r from rfis where id=p_rfi_id for update;
  if a.id is null or r.id is null then raise exception 'Survey assignment not found'; end if;
  if a.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Assignment belongs to another Surveyor'; end if;
  if a.status not in ('ASSIGNED','REASSIGNED') then raise exception 'Assignment is not awaiting acceptance'; end if;
  update survey_assignments set status='ACCEPTED',accepted_at=now(),notes=coalesce(p_note,notes) where id=a.id returning * into a;
  update survey_executions set status='NOT_STARTED',assignment_accepted_at=now(),updated_at=now() where rfi_id=r.id;
  perform epas_audit(r.project_id,'SURVEY_ASSIGNMENT_ACCEPTED','rfi',r.id,'surveyor','ACCEPTED',coalesce(p_note,''),jsonb_build_object('assignment_id',a.id));
  return a;
end;$$;
grant execute on function epas_surveyor_accept_assignment(uuid,text) to authenticated;

create or replace function epas_prepare_survey_execution(p_rfi_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; pkg_count integer; ack_count integer; checklist_ready boolean; checklist_count integer; accepted boolean; rev_pending integer;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not a project member'; end if;
  if r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  select * into e from survey_executions where rfi_id=p_rfi_id;
  if e.id is null then raise exception 'Survey execution not initialized'; end if;
  select (status='ACCEPTED') into accepted from survey_assignments where rfi_id=p_rfi_id;
  select count(*) into pkg_count from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null;
  select count(*) into ack_count from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null and handover_acknowledged_at is not null and handover_acknowledged_by=auth.uid();
  perform epas_initialize_survey_checklist(p_rfi_id);
  checklist_ready:=epas_survey_checklist_ready(p_rfi_id);
  select count(*) into checklist_count from survey_checklist_items where rfi_id=p_rfi_id and mandatory;
    rev_pending := (select count(*) from survey_rfi_drawings s left join survey_drawing_impact_decisions di on di.package_id=s.id join plan_drawings pd on pd.id=s.drawing_id join documents doc on doc.id=pd.document_id where s.rfi_id=p_rfi_id and s.revoked_at is null and (s.shared_revision is distinct from pd.revision or coalesce(s.shared_sha256,'') is distinct from coalesce(doc.sha256,'')) and coalesce(di.impact,'')='');
  return jsonb_build_object('assignment_accepted',coalesce(accepted,false),'package_count',pkg_count,'package_acknowledged',pkg_count>0 and ack_count=pkg_count,'checklist_ready',checklist_ready,'checklist_items',checklist_count,'revision_impact_pending',rev_pending,'ready',coalesce(accepted,false) and (pkg_count=0 or ack_count=pkg_count) and checklist_ready and rev_pending=0);
end;$$;
grant execute on function epas_prepare_survey_execution(uuid) to authenticated;

create or replace function epas_start_survey_execution(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
declare r rfis; e survey_executions; gate jsonb;
begin
  if not epas_has_role('surveyor') then raise exception 'Only Surveyor may start survey execution'; end if;
  select * into r from rfis where id=p_rfi_id for update;
  if r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  gate:=epas_prepare_survey_execution(p_rfi_id);
  if not (gate->>'ready')::boolean then raise exception 'Survey start gate is not satisfied: %',gate::text; end if;
  update survey_executions set status='IN_PROGRESS',started_at=coalesce(started_at,now()),started_by=auth.uid(),checklist_version=coalesce((select max(checklist_version) from survey_checklist_items where rfi_id=r.id),1),drawing_package_version=(select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),scope_version=(select current_version from survey_scopes where rfi_id=r.id),updated_at=now() where rfi_id=r.id returning * into e;
  update survey_assignments set status='IN_PROGRESS' where rfi_id=r.id and surveyor_id=auth.uid();
  perform epas_audit(r.project_id,'SURVEY_EXECUTION_STARTED','rfi',r.id,'surveyor','IN_PROGRESS','Composite survey start gate passed',gate);
  return e;
end;$$;
grant execute on function epas_start_survey_execution(uuid) to authenticated;

-- ================================================================
-- 6. Mandatory survey completion gate / report binding
-- ================================================================
create or replace function epas_survey_submission_gate(p_rfi_id uuid)
returns table(assignment_accepted boolean,package_acknowledged boolean,checklist_ready boolean,revision_impact_clear boolean,scope_version integer,drawing_package_version integer,ready_to_submit boolean,open_observations bigint,latest_report_at timestamptz)
language plpgsql security definer set search_path=public stable as $$
select coalesce((select status='ACCEPTED' or status='IN_PROGRESS' or status='COMPLETED' from survey_assignments where rfi_id=p_rfi_id and surveyor_id=auth.uid()),false),
       coalesce((select count(*)=0 or count(*)=count(*) filter(where handover_acknowledged_at is not null and handover_acknowledged_by=auth.uid()) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),true),
       epas_survey_checklist_ready(p_rfi_id),
       not exists(select 1 from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id join documents doc on doc.id=d.document_id left join survey_drawing_impact_decisions di on di.package_id=s.id where s.rfi_id=p_rfi_id and s.revoked_at is null and (s.shared_revision is distinct from d.revision or coalesce(s.shared_sha256,'') is distinct from coalesce(doc.sha256,'')) and coalesce(di.impact,'')=''),
       (select current_version from survey_scopes where rfi_id=p_rfi_id),
       (select max(package_version) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),
       (coalesce((select status='ACCEPTED' or status='IN_PROGRESS' or status='COMPLETED' from survey_assignments where rfi_id=p_rfi_id and surveyor_id=auth.uid()),false)
        and coalesce((select count(*)=0 or count(*)=count(*) filter(where handover_acknowledged_at is not null and handover_acknowledged_by=auth.uid()) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),true)
        and epas_survey_checklist_ready(p_rfi_id)
        and not exists(select 1 from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id join documents doc on doc.id=d.document_id left join survey_drawing_impact_decisions di on di.package_id=s.id where s.rfi_id=p_rfi_id and s.revoked_at is null and (s.shared_revision is distinct from d.revision or coalesce(s.shared_sha256,'') is distinct from coalesce(doc.sha256,'')) and coalesce(di.impact,'')='')),
       (select count(*) from observations where rfi_id=p_rfi_id and status='open'),
       (select max(submitted_at) from survey_reports where rfi_id=p_rfi_id);
$$;
grant execute on function epas_survey_submission_gate(uuid) to authenticated;

-- ================================================================
-- 7. Survey execution scope/package snapshots + immutable report basis
-- ================================================================
alter table survey_executions add column if not exists execution_basis jsonb not null default '{}'::jsonb;

create or replace function epas_freeze_survey_execution_basis(p_rfi_id uuid)
returns survey_executions language plpgsql security definer set search_path=public as $$
declare e survey_executions; r rfis; basis jsonb;
begin
  select * into e from survey_executions where rfi_id=p_rfi_id for update;
  select * into r from rfis where id=p_rfi_id;
  if e.id is null or r.id is null then raise exception 'Survey execution not found'; end if;
  if not (e.surveyor_id=auth.uid() or epas_has_role('dm') or epas_has_role('gm')) then raise exception 'Not authorized to freeze survey execution basis'; end if;
  basis:=jsonb_build_object(
    'rfi_id',r.id,
    'scope_version',(select current_version from survey_scopes where rfi_id=r.id),
    'scope_snapshot',(select to_jsonb(sv) from survey_scope_versions sv where sv.rfi_id=r.id order by sv.version_no desc limit 1),
    'drawing_package_version',(select max(package_version) from survey_rfi_drawings where rfi_id=r.id and revoked_at is null),
    'drawings',(select coalesce(jsonb_agg(jsonb_build_object('package_id',s.id,'drawing_no',s.shared_drawing_no,'title',s.shared_title,'discipline',s.shared_discipline,'revision',s.shared_revision,'document_id',s.shared_document_id,'file_name',s.shared_file_name,'sha256',s.shared_sha256)), '[]'::jsonb) from survey_rfi_drawings s where s.rfi_id=r.id and s.revoked_at is null),
    'checklist_version',(select coalesce(max(checklist_version),1) from survey_checklist_items where rfi_id=r.id)
  );
  update survey_executions set execution_basis=basis,scope_version=(basis->>'scope_version')::integer,drawing_package_version=(basis->>'drawing_package_version')::integer,checklist_version=(basis->>'checklist_version')::integer,updated_at=now() where id=e.id returning * into e;
  return e;
end;$$;
grant execute on function epas_freeze_survey_execution_basis(uuid) to authenticated;

-- ================================================================
-- 8. Certificate issuance gate + real DM acknowledgement
-- ================================================================
create table if not exists certificate_decision_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references certificate_decision_packages(id) on delete cascade,
  rfi_id uuid not null references rfis(id) on delete cascade,
  acknowledged_by uuid not null references profiles(id),
  acknowledged_at timestamptz not null default now(),
  note text,
  unique(package_id,acknowledged_by)
);

create or replace function epas_acknowledge_certificate_decision_package(p_package_id uuid,p_note text default null)
returns certificate_decision_acknowledgements language plpgsql security definer set search_path=public as $$
declare p certificate_decision_packages; r rfis; a certificate_decision_acknowledgements;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may acknowledge certificate decision package'; end if;
  select * into p from certificate_decision_packages where id=p_package_id;
  if p.id is null then raise exception 'Decision package not found'; end if;
  select * into r from rfis where id=p.rfi_id;
  if r.assigned_dm_id<>auth.uid() then raise exception 'Only assigned DM may acknowledge this package'; end if;
  insert into certificate_decision_acknowledgements(package_id,rfi_id,acknowledged_by,note) values(p.id,r.id,auth.uid(),p_note) on conflict(package_id,acknowledged_by) do update set note=excluded.note,acknowledged_at=now() returning * into a;
  update certificate_decision_packages set dm_ack_snapshot=jsonb_build_object('acknowledged',true,'acknowledged_by',auth.uid(),'acknowledged_at',a.acknowledged_at,'note',a.note) where id=p.id;
  return a;
end;$$;
grant execute on function epas_acknowledge_certificate_decision_package(uuid,text) to authenticated;

create or replace function epas_certificate_issuance_gate(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare p certificate_decision_packages; r rfis; open_obs integer; dm_ack boolean; gate boolean;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  select count(*) into open_obs from observations where rfi_id=r.id and status='open';
  select * into p from certificate_decision_packages where rfi_id=r.id order by package_version desc limit 1;
  dm_ack:=exists(select 1 from certificate_decision_acknowledgements a where a.package_id=p.id);
  gate:=p.id is not null and dm_ack and r.status in ('approved_no_observations','approved_with_observations') and ((open_obs=0 and p_cert_type<>'interim_certificate') or (open_obs>0 and p_cert_type='interim_certificate'));
  return jsonb_build_object('gate_passed',gate,'decision_package_id',p.id,'dm_acknowledged',dm_ack,'open_observations',open_obs,'certificate_type',p_cert_type);
end;$$;
grant execute on function epas_certificate_issuance_gate(uuid,text) to authenticated;

-- Re-wrap issuance so certificate cannot be created without a frozen package and DM acknowledgement.
create or replace function epas_issue_certificate(p_rfi_id uuid,p_cert_type text,p_validity_months integer)
returns certificates language plpgsql security definer set search_path=public as $$
declare v_rfi rfis; v_vessel vessels; v_cert certificates; v_open int; v_prefix text; v_number text; gate jsonb;
begin
  if not epas_has_role('gm') then raise exception 'Only GM may issue certificates'; end if;
  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.status not in ('approved_no_observations','approved_with_observations') then raise exception 'RFI is not eligible for certificate issuance'; end if;
  select * into v_vessel from vessels where id=v_rfi.vessel_id;
  select count(*) into v_open from observations where rfi_id=p_rfi_id and status='open';
  if v_open > 0 and p_cert_type <> 'interim_certificate' then raise exception 'Open observations require an Interim Certificate'; end if;
  if v_open = 0 and p_cert_type = 'interim_certificate' then raise exception 'No open observations; issue the full certificate'; end if;
  gate:=epas_certificate_issuance_gate(p_rfi_id,p_cert_type);
  if not coalesce((gate->>'gate_passed')::boolean,false) then raise exception 'Certificate issuance gate failed: %',gate::text; end if;
  if p_validity_months <= 0 then raise exception 'Validity must be positive'; end if;
  v_prefix := case p_cert_type when 'class_certificate' then 'CC' when 'interim_certificate' then 'ICC' when 'nsc_certificate' then 'NCC' else null end;
  if v_prefix is null then raise exception 'Invalid certificate type'; end if;
  v_number := v_prefix||'-'||to_char(current_date,'YYYY')||'-'||upper(replace(coalesce(v_rfi.rfi_code,'RFI'),' ','-'));
  if exists(select 1 from certificates where cert_number=v_number) then v_number := v_number||'-'||substr(gen_random_uuid()::text,1,6); end if;
  insert into certificates(vessel_id,project_id,rfi_id,cert_type,cert_number,issue_date,expiry_date,status,pending_observations,issued_by)
  values(v_vessel.id,v_rfi.project_id,v_rfi.id,p_cert_type,v_number,current_date,(current_date + make_interval(months=>p_validity_months))::date,'active',coalesce((select jsonb_agg(description) from observations where rfi_id=p_rfi_id and status='open'),'[]'::jsonb),auth.uid()) returning * into v_cert;
  update certificate_decision_packages set certificate_id=v_cert.id where rfi_id=p_rfi_id and id=(select decision_package_id from jsonb_to_record(gate) as x(decision_package_id uuid,gate_passed boolean,dm_acknowledged boolean,open_observations integer,certificate_type text) limit 1);
  update rfis set status='certificate_issued',updated_at=now() where id=p_rfi_id;
  insert into workflow_events(project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note) values(v_rfi.project_id,'rfi',p_rfi_id,'CERTIFICATE_ISSUED',v_rfi.status,'certificate_issued',auth.uid(),v_number);
  return v_cert;
end;$$;
grant execute on function epas_issue_certificate(uuid,text,integer) to authenticated;

-- ================================================================
-- 9. Correct evidence authorization and exact observation binding
-- ================================================================
create or replace function epas_register_observation_evidence(
  p_observation_id uuid,p_corrective_action_id uuid,p_file_name text,p_storage_path text,
  p_sha256 text,p_mime_type text,p_size_bytes bigint,p_evidence_type text default 'CORRECTIVE_EVIDENCE'
) returns observation_evidence language plpgsql security definer set search_path=public as $$
declare o observations; ca corrective_actions; e observation_evidence; r rfis; role_name text;
begin
  select * into o from observations where id=p_observation_id for update;
  if o.id is null then raise exception 'Observation not found'; end if;
  select * into r from rfis where id=o.rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  select role into role_name from profiles where id=auth.uid();
  if role_name not in ('ship_management','surveyor','dm') then raise exception 'Role cannot submit observation evidence'; end if;
  if not epas_is_project_member(r.project_id) then raise exception 'Not an active project member'; end if;
  if role_name='ship_management' then
    if p_corrective_action_id is null then raise exception 'Ship Management evidence must be tied to a corrective action'; end if;
    if not exists(select 1 from corrective_actions x where x.id=p_corrective_action_id and x.rfi_id=o.rfi_id and x.assigned_to=auth.uid() and x.status in ('assigned','in_progress','returned_for_rework','submitted')) then raise exception 'Corrective action is not assigned to this Ship Management user'; end if;
  elsif role_name='surveyor' then
    if r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey is assigned to another Surveyor'; end if;
  elsif role_name='dm' then
    if r.assigned_dm_id<>auth.uid() then raise exception 'RFI is assigned to another DM'; end if;
  end if;
  if p_corrective_action_id is not null then
    select * into ca from corrective_actions where id=p_corrective_action_id;
    if ca.id is null or ca.rfi_id<>o.rfi_id then raise exception 'Corrective action is not linked to this observation RFI'; end if;
    if not exists(select 1 from corrective_action_observations where corrective_action_id=ca.id and observation_id=o.id) then raise exception 'Evidence must be linked to an exact corrective-action observation pair'; end if;
  end if;
  insert into observation_evidence(observation_id,corrective_action_id,uploaded_by,file_name,storage_path,sha256,mime_type,size_bytes,evidence_type)
  values(o.id,p_corrective_action_id,auth.uid(),p_file_name,p_storage_path,p_sha256,p_mime_type,p_size_bytes,p_evidence_type) returning * into e;
  perform epas_audit(r.project_id,'OBSERVATION_EVIDENCE_REGISTERED','observation',o.id,role_name,'evidence_registered',p_file_name,jsonb_build_object('evidence_id',e.id,'sha256',p_sha256));
  return e;
end;$$;
grant execute on function epas_register_observation_evidence(uuid,uuid,text,text,text,text,bigint,text) to authenticated;

-- ================================================================
-- 10. Security-definer read paths: explicit membership enforcement
-- ================================================================
create or replace function epas_project_timeline(p_project_id uuid,p_limit integer default 200)
returns table(created_at timestamptz,event_type text,entity_type text,entity_id uuid,actor_id uuid,from_state text,to_state text,note text,metadata jsonb)
language plpgsql security definer set search_path=public stable as $$
begin
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project timeline'; end if;
  return query
  select * from (
    select le.created_at,le.event_type,le.entity_type,le.entity_id,le.actor_id,le.from_state,le.to_state,le.note,le.metadata from lifecycle_events le where le.project_id=p_project_id
    union all
    select al.created_at,al.action,'audit',al.id,al.actor_id,null,null,null,al.details from audit_log al where al.project_id=p_project_id
  ) x order by created_at desc limit greatest(1,least(coalesce(p_limit,200),500));
end;$$;
grant execute on function epas_project_timeline(uuid,integer) to authenticated;

create or replace function epas_survey_schedule_queue(p_project_id uuid default null)
returns table(schedule_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,next_due_date date,window_start date,window_end date,status text,days_to_due integer,rfi_id uuid)
language plpgsql security definer set search_path=public stable as $$
begin
  if p_project_id is not null and not epas_is_project_member(p_project_id) then raise exception 'Not authorized for project schedule'; end if;
  if p_project_id is null and not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Global survey schedule requires GM or DM access'; end if;
  return query
  select s.id,s.vessel_id,v.name,s.phase,s.survey_type,s.next_due_date,s.window_start,s.window_end,s.status,(s.next_due_date-current_date),s.source_rfi_id
  from survey_schedules s join vessels v on v.id=s.vessel_id where s.active and (p_project_id is null or s.project_id=p_project_id) order by s.next_due_date;
end;$$;
grant execute on function epas_survey_schedule_queue(uuid) to authenticated;

-- ================================================================
-- 11. Restrict global system operations
-- ================================================================
revoke all on function epas_refresh_all_survey_schedules() from authenticated;
revoke all on function epas_generate_survey_due_notifications() from authenticated;
revoke all on function epas_record_lifecycle_event(uuid,uuid,text,uuid,text,text,text,jsonb) from authenticated;

create or replace function epas_refresh_all_survey_schedules_as_operator()
returns integer language plpgsql security definer set search_path=public as $$
declare v record; n integer:=0;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may run a manual schedule refresh'; end if;
  for v in select distinct vessel_id from survey_schedules where active loop n:=n+epas_sync_survey_schedule(v.vessel_id); end loop;
  return n;
end;$$;
grant execute on function epas_refresh_all_survey_schedules_as_operator() to authenticated;

create or replace function epas_generate_survey_due_notifications_as_operator()
returns integer language plpgsql security definer set search_path=public as $$
declare s record; m record; role_gate boolean; n integer:=0;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may run manual due notifications'; end if;
  update survey_schedules set status=case when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,updated_at=now() where active;
  for s in select * from survey_schedules where active and status in ('DUE_SOON','DUE','OVERDUE') loop
    for m in select pm.user_id,pm.role from project_members pm where pm.project_id=s.project_id and pm.active and pm.role in ('gm','dm','owner','ship_management','shipyard') loop
      role_gate := (s.phase='nsc_survey' and m.role in ('gm','dm','shipyard')) or (s.phase='in_service' and m.role in ('gm','dm','owner','ship_management'));
      if role_gate and not exists(select 1 from notifications x where x.user_id=m.user_id and x.project_id=s.project_id and x.link_page='survey_schedule:'||s.id::text and x.created_at::date=current_date) then
        insert into notifications(user_id,title,body,project_id,link_page) values(m.user_id,case s.status when 'OVERDUE' then 'Survey overdue' when 'DUE' then 'Survey due' else 'Survey window approaching' end,format('%s %s survey due %s (%s days).',s.survey_type,(select name from vessels where id=s.vessel_id),s.next_due_date,(s.next_due_date-current_date)),s.project_id,'survey_schedule:'||s.id::text);
        n:=n+1;
      end if;
    end loop;
  end loop;
  return n;
end;$$;
grant execute on function epas_generate_survey_due_notifications_as_operator() to authenticated;

-- ================================================================
-- 12. True recurring In-Service schedule model
-- ================================================================
alter table survey_schedules add column if not exists due_basis text not null default 'CERTIFICATE';
alter table survey_schedules add column if not exists due_basis_reference text;
alter table survey_schedules add column if not exists survey_interval_months integer;
alter table survey_schedules add column if not exists due_window_days_before integer not null default 90;
alter table survey_schedules add column if not exists current_rfi_id uuid references rfis(id);
alter table survey_schedules add column if not exists cycle_number integer not null default 1;
alter table survey_schedules add constraint survey_schedules_interval_check check(survey_interval_months is null or survey_interval_months>0);

create or replace function epas_set_in_service_schedule_basis(p_vessel_id uuid,p_interval_months integer,p_due_basis text,p_basis_reference text,p_window_days integer default 90)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare s survey_schedules;
begin
  if not epas_has_role('gm') and not epas_has_role('dm') then raise exception 'Only GM or DM may configure survey schedule basis'; end if;
  if p_interval_months is null or p_interval_months<=0 then raise exception 'Survey interval must be positive'; end if;
  if coalesce(trim(p_basis_reference),'')='' then raise exception 'Schedule basis reference is required'; end if;
  update survey_schedules set survey_interval_months=p_interval_months,interval_months=p_interval_months,due_basis=p_due_basis,due_basis_reference=p_basis_reference,due_window_days_before=greatest(1,p_window_days),window_start=(next_due_date - make_interval(days=>greatest(1,p_window_days)))::date,updated_at=now() where vessel_id=p_vessel_id and phase='in_service' and active returning * into s;
  if s.id is null then raise exception 'Active In-Service schedule not found for vessel'; end if;
  return s;
end;$$;
grant execute on function epas_set_in_service_schedule_basis(uuid,integer,text,text,integer) to authenticated;

create or replace function epas_sync_survey_schedule(p_vessel_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare s survey_schedules; c certificates; base_date date; interval_m integer; current_rfi uuid; new_due date;
begin
  select * into s from survey_schedules where vessel_id=p_vessel_id and phase='in_service' and active for update;
  select * into c from certificates where vessel_id=p_vessel_id and status='active' order by issue_date desc limit 1;
  if s.id is null then
    if c.id is null then return null; end if;
    base_date:=coalesce(c.issue_date,current_date);
    interval_m:=coalesce(s.survey_interval_months,12);
    new_due:=(base_date + make_interval(months=>interval_m))::date;
    insert into survey_schedules(vessel_id,project_id,survey_type,phase,interval_months,survey_interval_months,last_completed_date,next_due_date,window_start,window_end,status,source_certificate_id,due_basis,due_basis_reference,due_window_days_before,cycle_number,active)
    values(p_vessel_id,c.project_id,'In-Service Survey','in_service',interval_m,interval_m,c.issue_date,new_due,(new_due-interval '90 days')::date,(new_due+interval '30 days')::date,'SCHEDULED',c.id,'CERTIFICATE',c.cert_number,90,1,true) returning * into s;
    return s;
  end if;
  interval_m:=coalesce(s.survey_interval_months,s.interval_months,12);
  current_rfi:=s.current_rfi_id;
  if current_rfi is not null and exists(select 1 from rfis r where r.id=current_rfi and r.status in ('certificate_issued','closed')) then
    select coalesce(c.issue_date,current_date) into base_date from certificates c where c.id=(select c2.id from certificates c2 where c2.rfi_id=current_rfi order by c2.issue_date desc limit 1);
    if base_date is null then base_date:=coalesce(s.last_completed_date,current_date); end if;
    new_due:=(base_date + make_interval(months=>interval_m))::date;
    update survey_schedules set last_completed_date=base_date,next_due_date=new_due,window_start=(new_due-make_interval(days=>s.due_window_days_before))::date,window_end=(new_due+interval '30 days')::date,status='SCHEDULED',current_rfi_id=null,source_rfi_id=null,source_certificate_id=coalesce((select c3.id from certificates c3 where c3.rfi_id=current_rfi order by c3.issue_date desc limit 1),source_certificate_id),cycle_number=cycle_number+1,updated_at=now() where id=s.id returning * into s;
  end if;
  if s.current_rfi_id is null then
    select r.id into current_rfi from rfis r where r.project_id=s.project_id and r.vessel_id=s.vessel_id and r.phase='in_service' and r.status not in ('certificate_issued','closed') order by r.created_at desc limit 1;
    if current_rfi is not null then update survey_schedules set current_rfi_id=current_rfi,source_rfi_id=current_rfi,status='RFI_OPEN',updated_at=now() where id=s.id returning * into s; end if;
  end if;
  update survey_schedules set survey_interval_months=interval_m,interval_months=interval_m,window_start=(next_due_date-make_interval(days=>due_window_days_before))::date,status=case when current_rfi_id is not null then 'RFI_OPEN' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,updated_at=now() where id=s.id returning * into s;
  return s;
end;$$;
grant execute on function epas_sync_survey_schedule(uuid) to authenticated;

-- ================================================================
-- 13. Vessel survey status projection correctness
-- ================================================================
create or replace function epas_refresh_vessel_survey_status(p_vessel_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v vessels; old_status text; new_status text; source_id uuid; phase_name text; last_date date;
begin
  select * into v from vessels where id=p_vessel_id for update;
  old_status:=v.survey_status;
  select case
    when exists(select 1 from rfis r where r.vessel_id=p_vessel_id and r.status not in ('certificate_issued','closed')) then case when exists(select 1 from rfis r where r.vessel_id=p_vessel_id and r.phase='in_service' and r.status not in ('certificate_issued','closed')) then 'IN_SERVICE_IN_PROGRESS' else 'SURVEY_IN_PROGRESS' end
    when exists(select 1 from survey_schedules s where s.vessel_id=p_vessel_id and s.active and s.status='OVERDUE') then 'IN_SERVICE_OVERDUE'
    when exists(select 1 from survey_schedules s where s.vessel_id=p_vessel_id and s.active and s.status in ('DUE','DUE_SOON')) then 'IN_SERVICE_DUE'
    when exists(select 1 from rfis r where r.vessel_id=p_vessel_id and r.phase='nsc_survey' and r.status in ('certificate_issued','closed')) then 'CLASS_ACTIVE'
    else 'NOT_STARTED' end into new_status;
  select max(coalesce(sr.completed_at,sr.submitted_at)::date),max(r.phase) into last_date,phase_name from survey_reports sr join rfis r on r.id=sr.rfi_id where r.vessel_id=p_vessel_id;
  select id into source_id from rfis where vessel_id=p_vessel_id order by updated_at desc limit 1;
  if old_status is distinct from new_status then
    update vessels set survey_status=new_status,survey_status_updated_at=now(),last_survey_date=last_date,last_survey_phase=phase_name,next_survey_due=(select next_due_date from survey_schedules where vessel_id=p_vessel_id and active order by next_due_date limit 1) where id=p_vessel_id;
    insert into vessel_survey_status_history(vessel_id,project_id,status,phase,source_type,source_id,note) values(v.id,v.project_id,new_status,phase_name,'SYSTEM',source_id,'Survey status projection changed');
  else
    update vessels set last_survey_date=last_date,last_survey_phase=phase_name,next_survey_due=(select next_due_date from survey_schedules where vessel_id=p_vessel_id and active order by next_due_date limit 1) where id=p_vessel_id;
  end if;
end;$$;
grant execute on function epas_refresh_vessel_survey_status(uuid) to authenticated;

-- ================================================================
-- 14. Project phase semantics: cycle completion != phase completion
-- ================================================================
alter table project_phase_control add column if not exists lifecycle_status text not null default 'ACTIVE';
alter table projects add column if not exists scope_status text;

create or replace function epas_refresh_project_phase_state(p_project_id uuid)
returns setof project_phase_control language plpgsql security definer set search_path=public as $$
declare p text; seq integer; phases text[]; gate record; prev_status text;
begin
  select projects.phases into phases from projects where id=p_project_id;
  if phases is null then raise exception 'Project not found'; end if;
  foreach p in array array['plan_appraisal','nsc_survey','in_service'] loop
    seq:=case p when 'plan_appraisal' then 1 when 'nsc_survey' then 2 else 3 end;
    if not (p=any(phases)) then
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note,lifecycle_status) values(p_project_id,p,seq,'NOT_APPLICABLE',false,p||' is not part of project scope','COMPLETED') on conflict(project_id,phase) do update set status='NOT_APPLICABLE',gate_passed=false,gate_note=excluded.gate_note,lifecycle_status='COMPLETED';
      continue;
    end if;
    select * into gate from epas_phase_gate_status(p_project_id,p) limit 1;
    prev_status:=(select status from project_phase_control where project_id=p_project_id and phase=p);
    if p='in_service' and gate.status='COMPLETED' then
      gate.status:='IN_PROGRESS';
      gate.gate_passed:=true;
      gate.note:='Current In-Service survey cycle is complete; the In-Service phase remains active for the next cycle';
    end if;
    insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note,started_at,completed_at,lifecycle_status)
    values(p_project_id,p,seq,gate.status,gate.gate_passed,gate.note,case when gate.status in ('IN_PROGRESS','COMPLETED') then coalesce((select started_at from project_phase_control where project_id=p_project_id and phase=p),now()) end,case when p<>'in_service' and gate.status='COMPLETED' then now() else null end,case when p='in_service' then 'ACTIVE' else case when gate.status='COMPLETED' then 'COMPLETED' else 'ACTIVE' end end)
    on conflict(project_id,phase) do update set status=excluded.status,gate_passed=excluded.gate_passed,gate_note=excluded.gate_note,started_at=coalesce(project_phase_control.started_at,excluded.started_at),completed_at=case when excluded.completed_at is not null then excluded.completed_at else project_phase_control.completed_at end,lifecycle_status=excluded.lifecycle_status;
  end loop;
  update projects set current_phase=case when 'in_service'=any(phases) then 'in_service' when 'nsc_survey'=any(phases) then 'nsc_survey' else 'plan_appraisal' end,
    current_phase_status=(select status from project_phase_control where project_id=p_project_id and phase=case when 'in_service'=any(phases) then 'in_service' when 'nsc_survey'=any(phases) then 'nsc_survey' else 'plan_appraisal' end),
    scope_status=case when 'in_service'=any(phases) then 'IN_SERVICE_ACTIVE' when 'nsc_survey'=any(phases) then 'NSC_COMPLETE_OR_ACTIVE' when 'plan_appraisal'=any(phases) then 'PLAN_ONLY' else 'NOT_STARTED' end
  where id=p_project_id;
  return query select * from project_phase_control where project_id=p_project_id order by sequence_no;
end;$$;
grant execute on function epas_refresh_project_phase_state(uuid) to authenticated;

-- ================================================================
-- 15. Central notification/event policy and actionable RFI prompts
-- ================================================================
create or replace function epas_generate_survey_due_notifications_as_operator()
returns integer language plpgsql security definer set search_path=public as $$
declare s record; m record; role_gate boolean; n integer:=0;
begin
  if not (epas_has_role('gm') or epas_has_role('dm')) then raise exception 'Only GM or DM may run manual due notifications'; end if;
  update survey_schedules set status=case when current_rfi_id is not null then 'RFI_OPEN' when next_due_date<current_date then 'OVERDUE' when next_due_date<=current_date+30 then 'DUE' when next_due_date<=current_date+90 then 'DUE_SOON' else 'SCHEDULED' end,updated_at=now() where active;
  for s in select * from survey_schedules where active and status in ('DUE_SOON','DUE','OVERDUE') loop
    for m in select pm.user_id,pm.role from project_members pm where pm.project_id=s.project_id and pm.active and pm.role in ('gm','dm','owner','ship_management','shipyard') loop
      role_gate := (s.phase='nsc_survey' and m.role in ('gm','dm','shipyard')) or (s.phase='in_service' and m.role in ('gm','dm','owner','ship_management'));
      if role_gate and not exists(select 1 from notifications x where x.user_id=m.user_id and x.project_id=s.project_id and x.link_page='survey_schedule:'||s.id::text and x.created_at::date=current_date) then
        insert into notifications(user_id,title,body,project_id,link_page) values(m.user_id,case s.status when 'OVERDUE' then 'Survey overdue' when 'DUE' then 'Survey due' else 'Survey window approaching' end,format('%s %s survey due %s (%s days). Open the project to initiate the appropriate survey RFI.',s.survey_type,(select name from vessels where id=s.vessel_id),s.next_due_date,(s.next_due_date-current_date)),s.project_id,'survey_schedule:'||s.id::text);
        n:=n+1;
      end if;
    end loop;
  end loop;
  return n;
end;$$;
grant execute on function epas_generate_survey_due_notifications_as_operator() to authenticated;

-- ================================================================
-- 16. Timeline recording and schedule helpers: explicit project membership
-- ================================================================
create or replace function epas_record_lifecycle_event(p_project_id uuid,p_vessel_id uuid,p_entity_type text,p_entity_id uuid,p_event_type text,p_from text,p_to text,p_note text,p_metadata jsonb default '{}'::jsonb)
returns lifecycle_events language plpgsql security definer set search_path=public as $$
declare e lifecycle_events;
begin
  if auth.uid() is not null and not (epas_has_role('gm') or epas_has_role('dm')) and not epas_is_project_member(p_project_id) then raise exception 'Not authorized to create lifecycle event'; end if;
  insert into lifecycle_events(project_id,vessel_id,entity_type,entity_id,event_type,actor_id,from_state,to_state,note,metadata) values(p_project_id,p_vessel_id,p_entity_type,p_entity_id,p_event_type,auth.uid(),p_from,p_to,p_note,coalesce(p_metadata,'{}'::jsonb)) returning * into e;
  return e;
end;$$;
grant execute on function epas_record_lifecycle_event(uuid,uuid,text,uuid,text,text,text,jsonb) to authenticated;

-- ================================================================
-- 17. Status and report gate trigger
-- ================================================================
create or replace function epas_guard_survey_report_submit()
returns trigger language plpgsql security definer set search_path=public as $$
declare g record; r rfis; e survey_executions;
begin
  select * into r from rfis where id=new.rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  select * into e from survey_executions where rfi_id=new.rfi_id;
  if e.id is null or e.status not in ('IN_PROGRESS','REPORT_SUBMITTED') then raise exception 'Survey execution has not started through the controlled start gate'; end if;
  if new.surveyor_id<>auth.uid() or r.assigned_surveyor_id<>auth.uid() then raise exception 'Survey report must be submitted by assigned Surveyor'; end if;
  select * into g from epas_survey_submission_gate(new.rfi_id) limit 1;
  if not g.ready_to_submit then raise exception 'Survey submission gate failed: assignment=% package_ack=% checklist=% revision_impact=%',g.assignment_accepted,g.package_acknowledged,g.checklist_ready,g.revision_impact_clear; end if;
  return new;
end;$$;
drop trigger if exists trg_epas_guard_survey_report_submit on survey_reports;
create trigger trg_epas_guard_survey_report_submit before insert or update on survey_reports for each row execute function epas_guard_survey_report_submit();

-- ================================================================
-- 18. RLS for v2.5 tables
-- ================================================================
alter table survey_scope_versions enable row level security;
alter table survey_drawing_impact_decisions enable row level security;
alter table certificate_decision_acknowledgements enable row level security;

drop policy if exists survey_scope_versions_select_v25 on survey_scope_versions;
create policy survey_scope_versions_select_v25 on survey_scope_versions for select to authenticated using (exists(select 1 from rfis r where r.id=survey_scope_versions.rfi_id and epas_is_project_member(r.project_id)));
drop policy if exists survey_scope_versions_write_v25 on survey_scope_versions;
create policy survey_scope_versions_write_v25 on survey_scope_versions for all to authenticated using(false) with check(false);

drop policy if exists survey_drawing_impact_decisions_select_v25 on survey_drawing_impact_decisions;
create policy survey_drawing_impact_decisions_select_v25 on survey_drawing_impact_decisions for select to authenticated using (exists(select 1 from rfis r where r.id=survey_drawing_impact_decisions.rfi_id and (r.assigned_dm_id=auth.uid() or r.assigned_surveyor_id=auth.uid() or epas_has_role('gm'))));
drop policy if exists survey_drawing_impact_decisions_write_v25 on survey_drawing_impact_decisions;
create policy survey_drawing_impact_decisions_write_v25 on survey_drawing_impact_decisions for all to authenticated using(false) with check(false);

drop policy if exists cert_decision_ack_select_v25 on certificate_decision_acknowledgements;
create policy cert_decision_ack_select_v25 on certificate_decision_acknowledgements for select to authenticated using (acknowledged_by=auth.uid() or epas_has_role('gm') or epas_has_role('dm'));
drop policy if exists cert_decision_ack_write_v25 on certificate_decision_acknowledgements;
create policy cert_decision_ack_write_v25 on certificate_decision_acknowledgements for all to authenticated using(false) with check(false);

-- ================================================================
-- 19. Helpful operational views / secured control-tower RPC
-- ================================================================
create or replace view survey_control_tower as
select s.id as schedule_id,s.project_id,s.vessel_id,v.name as vessel_name,s.phase,s.survey_type,s.cycle_number,s.next_due_date,s.window_start,s.window_end,s.status,s.current_rfi_id,
       r.rfi_code,r.status as rfi_status,r.assigned_surveyor_id,p.full_name as surveyor_name,
       s.due_basis,s.due_basis_reference,s.survey_interval_months,s.days_to_due
from (
  select ss.*, (ss.next_due_date-current_date) as days_to_due from survey_schedules ss where ss.active
) s join vessels v on v.id=s.vessel_id
left join rfis r on r.id=s.current_rfi_id
left join profiles p on p.id=r.assigned_surveyor_id;


-- ================================================================
-- 20. Final hardening of SECURITY DEFINER helpers and exposed view
-- ================================================================
revoke all on survey_control_tower from authenticated;

create or replace function epas_survey_control_tower(p_project_id uuid default null)
returns table(schedule_id uuid,project_id uuid,vessel_id uuid,vessel_name text,phase text,survey_type text,cycle_number integer,next_due_date date,window_start date,window_end date,status text,current_rfi_id uuid,rfi_code text,rfi_status text,assigned_surveyor_id uuid,surveyor_name text,due_basis text,due_basis_reference text,survey_interval_months integer,days_to_due integer)
language plpgsql security definer set search_path=public stable as $$
begin
  if p_project_id is null and not (epas_has_role('gm') or epas_has_role('dm')) then
    raise exception 'Global survey control-tower access requires GM or DM';
  end if;
  if p_project_id is not null and not epas_is_project_member(p_project_id) then
    raise exception 'Not authorized for survey control tower';
  end if;
  return query
  select s.id,s.project_id,s.vessel_id,s.vessel_name,s.phase,s.survey_type,s.cycle_number,s.next_due_date,s.window_start,s.window_end,s.status,s.current_rfi_id,s.rfi_code,s.rfi_status,s.assigned_surveyor_id,s.surveyor_name,s.due_basis,s.due_basis_reference,s.survey_interval_months,s.days_to_due
  from survey_control_tower s
  where p_project_id is null or s.project_id=p_project_id
  order by s.next_due_date;
end;$$;
grant execute on function epas_survey_control_tower(uuid) to authenticated;

-- Direct callers must use the member-aware/operator-aware wrappers. Triggers can still invoke these SECURITY DEFINER functions.
revoke all on function epas_sync_survey_schedule(uuid) from authenticated;
revoke all on function epas_refresh_vessel_survey_status(uuid) from authenticated;
revoke all on function epas_refresh_project_phase_state(uuid) from authenticated;
revoke all on function epas_phase_gate_status(uuid,text) from authenticated;

create or replace function epas_refresh_project_phase_state_as_member(p_project_id uuid)
returns setof project_phase_control language plpgsql security definer set search_path=public as $$
begin
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized to refresh project phase state'; end if;
  return query select * from epas_refresh_project_phase_state(p_project_id);
end;$$;
grant execute on function epas_refresh_project_phase_state_as_member(uuid) to authenticated;

create or replace function epas_phase_gate_status_safe(p_project_id uuid,p_phase text)
returns table(status text,gate_passed boolean,note text) language plpgsql security definer set search_path=public stable as $$
begin
  if not epas_is_project_member(p_project_id) then raise exception 'Not authorized to inspect project phase gate'; end if;
  return query select * from epas_phase_gate_status(p_project_id,p_phase);
end;$$;
grant execute on function epas_phase_gate_status_safe(uuid,text) to authenticated;

create or replace function epas_sync_survey_schedule_for_vessel(p_vessel_id uuid)
returns survey_schedules language plpgsql security definer set search_path=public as $$
declare v_project uuid; s survey_schedules;
begin
  select project_id into v_project from vessels where id=p_vessel_id;
  if v_project is null or not epas_is_project_member(v_project) then raise exception 'Not authorized for vessel survey schedule'; end if;
  select * into s from epas_sync_survey_schedule(p_vessel_id);
  return s;
end;$$;
grant execute on function epas_sync_survey_schedule_for_vessel(uuid) to authenticated;

-- Harden schedule read and drawing revision-impact helpers with explicit membership.
drop function if exists epas_survey_drawing_revision_impact(uuid);
create function epas_survey_drawing_revision_impact(p_rfi_id uuid)
returns table(package_id uuid,drawing_id uuid,drawing_no text,shared_revision integer,current_revision integer,shared_sha256 text,current_sha256 text,impact text,recommendation text)
language plpgsql security definer set search_path=public stable as $$
declare v_project uuid;
begin
  select project_id into v_project from rfis where id=p_rfi_id;
  if v_project is null or not epas_is_project_member(v_project) then raise exception 'Not authorized for drawing revision impact'; end if;
  return query select s.id,d.id,s.shared_drawing_no,s.shared_revision,d.revision,s.shared_sha256,doc.sha256,
    case when s.shared_revision=d.revision and coalesce(s.shared_sha256,'')=coalesce(doc.sha256,'') then 'NO_CHANGE' else 'REVISION_CHANGED' end,
    case when s.shared_revision=d.revision and coalesce(s.shared_sha256,'')=coalesce(doc.sha256,'') then 'Continue with existing controlled package' else 'DM must decide impact and reissue the package if required' end
  from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id join documents doc on doc.id=d.document_id
  where s.rfi_id=p_rfi_id and s.revoked_at is null;
end;$$;
grant execute on function epas_survey_drawing_revision_impact(uuid) to authenticated;

-- Prevent a direct authenticated caller from bypassing the member-aware status helper.
drop function if exists epas_survey_submission_gate(uuid);
create function epas_survey_submission_gate(p_rfi_id uuid)
returns table(assignment_accepted boolean,package_acknowledged boolean,checklist_ready boolean,revision_impact_clear boolean,scope_version integer,drawing_package_version integer,ready_to_submit boolean,open_observations bigint,latest_report_at timestamptz)
language plpgsql security definer set search_path=public stable as $$
declare v_project uuid;
begin
  select project_id into v_project from rfis where id=p_rfi_id;
  if v_project is null or not epas_is_project_member(v_project) then raise exception 'Not authorized for survey submission gate'; end if;
  return query
  select coalesce((select status in ('ACCEPTED','IN_PROGRESS','COMPLETED') from survey_assignments where rfi_id=p_rfi_id and surveyor_id=auth.uid()),false),
         coalesce((select count(*)=0 or count(*)=count(*) filter(where handover_acknowledged_at is not null and handover_acknowledged_by=auth.uid()) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),true),
         epas_survey_checklist_ready(p_rfi_id),
         not exists(select 1 from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id join documents doc on doc.id=d.document_id left join survey_drawing_impact_decisions di on di.package_id=s.id where s.rfi_id=p_rfi_id and s.revoked_at is null and (s.shared_revision is distinct from d.revision or coalesce(s.shared_sha256,'') is distinct from coalesce(doc.sha256,'')) and coalesce(di.impact,'')=''),
         (select current_version from survey_scopes where rfi_id=p_rfi_id),
         (select max(package_version) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),
         (coalesce((select status in ('ACCEPTED','IN_PROGRESS','COMPLETED') from survey_assignments where rfi_id=p_rfi_id and surveyor_id=auth.uid()),false)
          and coalesce((select count(*)=0 or count(*)=count(*) filter(where handover_acknowledged_at is not null and handover_acknowledged_by=auth.uid()) from survey_rfi_drawings where rfi_id=p_rfi_id and revoked_at is null),true)
          and epas_survey_checklist_ready(p_rfi_id)
          and not exists(select 1 from survey_rfi_drawings s join plan_drawings d on d.id=s.drawing_id join documents doc on doc.id=d.document_id left join survey_drawing_impact_decisions di on di.package_id=s.id where s.rfi_id=p_rfi_id and s.revoked_at is null and (s.shared_revision is distinct from d.revision or coalesce(s.shared_sha256,'') is distinct from coalesce(doc.sha256,'')) and coalesce(di.impact,'')=''))),
         (select count(*) from observations where rfi_id=p_rfi_id and status='open'),
         (select max(submitted_at) from survey_reports where rfi_id=p_rfi_id);
end;$$;
grant execute on function epas_survey_submission_gate(uuid) to authenticated;

-- Certificate gate is internal to GM issuance but also membership-safe for direct reads.
revoke all on function epas_certificate_issuance_gate(uuid,text) from authenticated;
create or replace function epas_certificate_issuance_gate(p_rfi_id uuid,p_cert_type text)
returns jsonb language plpgsql security definer set search_path=public stable as $$
declare p certificate_decision_packages; r rfis; open_obs integer; dm_ack boolean; gate boolean;
begin
  select * into r from rfis where id=p_rfi_id;
  if r.id is null then raise exception 'RFI not found'; end if;
  if not (epas_has_role('gm') or epas_is_project_member(r.project_id)) then raise exception 'Not authorized for certificate gate'; end if;
  select count(*) into open_obs from observations where rfi_id=r.id and status='open';
  select * into p from certificate_decision_packages where rfi_id=r.id order by package_version desc limit 1;
  dm_ack:=exists(select 1 from certificate_decision_acknowledgements a where a.package_id=p.id);
  gate:=p.id is not null and dm_ack and r.status in ('approved_no_observations','approved_with_observations') and ((open_obs=0 and p_cert_type<>'interim_certificate') or (open_obs>0 and p_cert_type='interim_certificate'));
  return jsonb_build_object('gate_passed',gate,'decision_package_id',p.id,'dm_acknowledged',dm_ack,'open_observations',open_obs,'certificate_type',p_cert_type);
end;$$;
grant execute on function epas_certificate_issuance_gate(uuid,text) to authenticated;

-- Final grant restriction on the old broad helpers.
revoke all on function epas_survey_checklist_ready(uuid) from authenticated;
create or replace function epas_survey_checklist_ready(p_rfi_id uuid)
returns boolean language plpgsql security definer set search_path=public stable as $$
declare v_project uuid;
begin
  select project_id into v_project from rfis where id=p_rfi_id;
  if v_project is null or not epas_is_project_member(v_project) then raise exception 'Not authorized for survey checklist'; end if;
  return not exists(select 1 from survey_checklist_items where rfi_id=p_rfi_id and mandatory and status='pending');
end;$$;
grant execute on function epas_survey_checklist_ready(uuid) to authenticated;


commit;
