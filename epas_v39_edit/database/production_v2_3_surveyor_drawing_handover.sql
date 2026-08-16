-- EPAS v2.3 — Controlled Approved Drawing Handover to Surveyor
-- Cumulative after v2.2.
-- Rule: Plan Appraisal approved drawings are NOT automatically exposed to every
-- surveyor. When DM assigns a survey RFI, the DM selects the relevant approved
-- drawings. The server creates a controlled drawing package for that RFI and
-- assigned Surveyor. This applies equally to NSC and In-Service surveys.

begin;

create table if not exists survey_rfi_drawings (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  drawing_id uuid not null references plan_drawings(id) on delete restrict,
  surveyor_id uuid not null references profiles(id) on delete restrict,
  granted_by uuid not null references profiles(id),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  relevance_note text,
  unique(rfi_id,drawing_id)
);
create index if not exists idx_survey_rfi_drawings_surveyor on survey_rfi_drawings(surveyor_id,rfi_id);
create index if not exists idx_survey_rfi_drawings_rfi on survey_rfi_drawings(rfi_id);

create or replace function epas_assign_surveyor_with_drawings(
  p_rfi_id uuid,
  p_surveyor_id uuid,
  p_scheduled_date date,
  p_drawing_ids uuid[],
  p_discipline text default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_rfi rfis;
  v_role text;
  v_gate text;
  v_count integer;
  v_task workflow_tasks;
  v_id uuid;
  v_project uuid;
  v_vessel uuid;
  v_note text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select role into v_role from profiles where id=auth.uid();
  if v_role <> 'dm' then raise exception 'Only the Department Manager may assign a Surveyor'; end if;

  select * into v_rfi from rfis where id=p_rfi_id for update;
  if v_rfi.id is null then raise exception 'RFI not found'; end if;
  if v_rfi.assigned_dm_id <> auth.uid() then raise exception 'Only the assigned Department Manager may assign this survey'; end if;
  if v_rfi.phase not in ('nsc_survey','in_service') then raise exception 'Invalid survey phase'; end if;
  if v_rfi.status not in ('allocated_to_dm','pending_allocation','sent_back_for_rework') then
    raise exception 'RFI is not ready for Surveyor assignment';
  end if;

  -- Phase gate: NSC / In-Service may only be assigned when the v2.2 project
  -- phase controller says the phase is READY or IN_PROGRESS.
  select status into v_gate from project_phase_control where project_id=v_rfi.project_id and phase=v_rfi.phase;
  if coalesce(v_gate,'LOCKED') not in ('READY','IN_PROGRESS') then
    raise exception 'Survey phase is not open for assignment: %', coalesce(v_gate,'LOCKED');
  end if;

  if not exists(select 1 from profiles p where p.id=p_surveyor_id and p.role='surveyor') then
    raise exception 'Selected user is not an active Surveyor';
  end if;
  if not exists(select 1 from project_members pm where pm.project_id=v_rfi.project_id and pm.user_id=p_surveyor_id and pm.active and pm.role='surveyor') then
    raise exception 'Surveyor is not an active member of this project';
  end if;

  -- A surveyor must receive a drawing package when approved plan drawings exist.
  -- The DM is responsible for selecting the drawings relevant to this survey.
  select count(*) into v_count from plan_drawings d where d.project_id=v_rfi.project_id and d.status='approved';
  if v_count > 0 and coalesce(array_length(p_drawing_ids,1),0)=0 then
    raise exception 'Select at least one approved Plan Appraisal drawing relevant to this survey';
  end if;

  if coalesce(array_length(p_drawing_ids,1),0)>0 then
    select count(*) into v_count
    from plan_drawings d
    where d.id = any(p_drawing_ids)
      and d.project_id=v_rfi.project_id
      and d.status='approved';
    if v_count <> array_length(p_drawing_ids,1) then
      raise exception 'Every shared drawing must belong to this project and be Plan Appraisal approved';
    end if;
  end if;

  -- Replace the package only for this RFI; historical RFI packages remain auditable.
  update survey_rfi_drawings set revoked_at=now()
   where rfi_id=v_rfi.id and revoked_at is null;

  if coalesce(array_length(p_drawing_ids,1),0)>0 then
    foreach v_id in array p_drawing_ids loop
      insert into survey_rfi_drawings(rfi_id,drawing_id,surveyor_id,granted_by,relevance_note)
      values(v_rfi.id,v_id,p_surveyor_id,auth.uid(),coalesce(p_discipline,'Relevant approved Plan Appraisal drawing for assigned survey'));
    end loop;
  end if;

  update rfis set assigned_surveyor_id=p_surveyor_id,scheduled_date=p_scheduled_date,
                  status='survey_in_progress',updated_at=now()
   where id=v_rfi.id;

  v_note := format('%s assigned for %s. Approved drawing package: %s drawing(s).',
                   v_rfi.rfi_code,coalesce(p_scheduled_date::text,'TBD'),coalesce(array_length(p_drawing_ids,1),0));

  -- Use the established workflow task schema; the existing application may add
  -- richer SLA fields through its normal task service, while this transaction
  -- guarantees the Surveyor receives the handover task atomically with access.
  insert into workflow_tasks(project_id,task_type,from_user_id,to_user_id,status,note,rfi_id,created_at)
  values(v_rfi.project_id,'SURVEY_RFI_EXECUTION',auth.uid(),p_surveyor_id,'pending',v_note,v_rfi.id,now())
  returning * into v_task;

  insert into plan_appraisal_events(drawing_id,event_type,actor_id,note)
  select srd.drawing_id,'SHARED_WITH_SURVEYOR',auth.uid(),
         format('Approved drawing shared with Surveyor for %s (%s).',v_rfi.rfi_code,upper(replace(v_rfi.phase,'_',' ')))
  from survey_rfi_drawings srd where srd.rfi_id=v_rfi.id and srd.revoked_at is null;

  perform epas_audit(v_rfi.project_id,'SURVEY_DRAWING_PACKAGE_CREATED','rfi',v_rfi.id,
    'dm','surveyor_package_created',v_note,
    jsonb_build_object('rfi_id',v_rfi.id,'surveyor_id',p_surveyor_id,'drawing_ids',coalesce(to_jsonb(p_drawing_ids),'[]'::jsonb),'phase',v_rfi.phase));

  return jsonb_build_object('rfi_id',v_rfi.id,'surveyor_id',p_surveyor_id,
                            'phase',v_rfi.phase,'drawing_count',coalesce(array_length(p_drawing_ids,1),0),
                            'task_id',v_task.id);
end;
$$;
grant execute on function epas_assign_surveyor_with_drawings(uuid,uuid,date,uuid[],text) to authenticated;

create or replace function epas_surveyor_drawing_package(p_rfi_id uuid)
returns table(
  package_id uuid,
  rfi_id uuid,
  drawing_id uuid,
  drawing_no text,
  title text,
  discipline text,
  revision integer,
  document_id uuid,
  file_name text,
  storage_path text,
  shared_at timestamptz,
  relevance_note text
)
language sql security definer set search_path=public stable as $$
  select s.id,s.rfi_id,d.id,d.drawing_no,d.title,d.discipline,d.revision,
         d.document_id,doc.file_name,doc.storage_path,s.granted_at,s.relevance_note
  from survey_rfi_drawings s
  join rfis r on r.id=s.rfi_id
  join plan_drawings d on d.id=s.drawing_id
  join documents doc on doc.id=d.document_id
  where s.rfi_id=p_rfi_id
    and s.surveyor_id=auth.uid()
    and s.revoked_at is null
    and d.status='approved';
$$;
grant execute on function epas_surveyor_drawing_package(uuid) to authenticated;

-- Surveyors must only see Plan Appraisal drawings that have been explicitly
-- handed to them for an assigned survey. Other internal roles retain project access.
drop policy if exists plan_drawings_select_v23 on plan_drawings;
create policy plan_drawings_select_v23 on plan_drawings
for select to authenticated
using (
  (
    epas_has_role('surveyor')
    and epas_is_project_member(project_id)
    and status='approved'
    and exists(
      select 1 from survey_rfi_drawings s
      join rfis r on r.id=s.rfi_id
      where s.drawing_id=plan_drawings.id
        and s.surveyor_id=auth.uid()
        and s.revoked_at is null
        and r.assigned_surveyor_id=auth.uid()
        and r.status in ('survey_in_progress','observations_logged','pending_gm_approval','sent_back_for_rework','approved_no_observations','approved_with_observations','certificate_issued','closed')
    )
  )
  or (
    epas_is_internal_role()
    and not epas_has_role('surveyor')
    and epas_is_project_member(project_id)
  )
  or (
    epas_has_role('designer') and epas_is_project_member(project_id)
    and exists(select 1 from documents d where d.id=plan_drawings.document_id and d.stakeholder_visible=true and d.release_status='released')
  )
);

-- Explicitly prevent a Surveyor from writing package records directly.
alter table survey_rfi_drawings enable row level security;
drop policy if exists survey_rfi_drawings_select_v23 on survey_rfi_drawings;
create policy survey_rfi_drawings_select_v23 on survey_rfi_drawings
for select to authenticated using (surveyor_id=auth.uid() or epas_has_role('dm') or epas_has_role('gm'));
drop policy if exists survey_rfi_drawings_write_v23 on survey_rfi_drawings;
create policy survey_rfi_drawings_write_v23 on survey_rfi_drawings
for all to authenticated using (false) with check (false);

commit;

-- Tighten inherited v1.5.1 policies so Surveyor cannot browse all project
-- drawings/documents/revisions; only the explicit package is visible.
begin;

drop policy if exists plan_drawings_select_v15 on plan_drawings;
drop policy if exists plan_drawings_select_v14 on plan_drawings;
drop policy if exists plan_drawings_select_prod on plan_drawings;

drop policy if exists documents_select_v15 on documents;
drop policy if exists documents_select_v23 on documents;
create policy documents_select_v23 on documents
for select to authenticated
using (
  (
    epas_has_role('surveyor')
    and epas_is_project_member(project_id)
    and exists(
      select 1 from survey_rfi_drawings s
      join plan_drawings d on d.id=s.drawing_id
      where d.document_id=documents.id
        and s.surveyor_id=auth.uid()
        and s.revoked_at is null
        and d.status='approved'
    )
  )
  or (epas_is_internal_role() and not epas_has_role('surveyor') and epas_is_project_member(project_id))
  or (epas_has_role('designer') and epas_is_project_member(project_id) and (uploaded_by=auth.uid() or (stakeholder_visible=true and release_status='released')))
  or (epas_has_role('owner') and epas_is_project_member(project_id) and stakeholder_visible=true and release_status='released')
  or (epas_has_role('ship_management') and epas_is_project_member(project_id) and stakeholder_visible=true and release_status='released')
  or (epas_has_role('shipyard') and epas_is_project_member(project_id) and stakeholder_visible=true and release_status='released')
);

drop policy if exists revisions_select_v15 on document_revisions;
drop policy if exists revisions_select_v23 on document_revisions;
create policy revisions_select_v23 on document_revisions
for select to authenticated
using (
  exists(
    select 1 from documents d
    where d.id=document_revisions.document_id
      and (
        (epas_has_role('surveyor') and epas_is_project_member(d.project_id) and exists(
          select 1 from survey_rfi_drawings s join plan_drawings pd on pd.id=s.drawing_id
          where pd.document_id=d.id and s.surveyor_id=auth.uid() and s.revoked_at is null and pd.status='approved'
        ))
        or (epas_is_internal_role() and not epas_has_role('surveyor') and epas_is_project_member(d.project_id))
        or (epas_has_role('designer') and epas_is_project_member(d.project_id) and (d.uploaded_by=auth.uid() or d.release_status='released'))
        or (epas_has_role('owner') and epas_is_project_member(d.project_id) and d.release_status='released')
        or (epas_has_role('ship_management') and epas_is_project_member(d.project_id) and d.release_status='released')
        or (epas_has_role('shipyard') and epas_is_project_member(d.project_id) and d.release_status='released')
      )
  )
);

-- Defense in depth: no survey report may be submitted until at least one
-- approved drawing package exists when the project contains approved drawings.
create or replace function epas_require_survey_drawing_package()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_project uuid;
  v_approved integer;
  v_shared integer;
begin
  select project_id into v_project from rfis where id=new.rfi_id;
  select count(*) into v_approved from plan_drawings where project_id=v_project and status='approved';
  select count(*) into v_shared from survey_rfi_drawings where rfi_id=new.rfi_id and surveyor_id=new.surveyor_id and revoked_at is null;
  if v_approved > 0 and v_shared = 0 then
    raise exception 'Survey report cannot be submitted before the relevant approved Plan Appraisal drawings are handed to the assigned Surveyor';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_require_survey_drawing_package on survey_reports;
create trigger trg_require_survey_drawing_package
before insert on survey_reports for each row execute function epas_require_survey_drawing_package();

commit;
