-- EPAS v1.8 Role-Complete Hardening Patch
-- Apply AFTER the deployed v1.7 stakeholder-RFI patch.
-- If v1.7 is not installed, apply the v1.6 migration first, then the v1.7
-- stakeholder-RFI patch, then this migration.
--
-- Scope requested in the v1.8 hardening pass:
--   5. Exact corrective-action -> observation binding
--   6. One controlled observation-closure path
--   7. Shipyard/Owner/Ship Management stakeholder RFI permissions
--   8. Explicit certificate lifecycle state machine
--   9. Controlled document lifecycle + revision lineage/policy
--  10. Live-acceptance test harness and security preflight artifacts

begin;

create extension if not exists pgcrypto;

-- ================================================================
-- 5. EXACT CORRECTIVE-ACTION / OBSERVATION BINDING
-- ================================================================
create table if not exists corrective_action_observations (
  id uuid primary key default gen_random_uuid(),
  corrective_action_id uuid not null references corrective_actions(id) on delete cascade,
  observation_id uuid not null references observations(id) on delete cascade,
  linked_by uuid not null references profiles(id),
  linked_at timestamptz not null default now(),
  unique(corrective_action_id, observation_id),
  unique(observation_id)
);
create index if not exists idx_ca_obs_action on corrective_action_observations(corrective_action_id);
create index if not exists idx_ca_obs_observation on corrective_action_observations(observation_id);

-- Keep the legacy FK column for compatibility, but make the normalized join
-- table the authoritative relationship.
insert into corrective_action_observations(corrective_action_id,observation_id,linked_by)
select o.corrective_action_id,o.id,coalesce(o.cleared_by,o.raised_by,auth.uid())
from observations o
where o.corrective_action_id is not null
on conflict (observation_id) do nothing;

-- Verification history gives every closure a durable business record.
create table if not exists observation_verifications (
  id uuid primary key default gen_random_uuid(),
  observation_id uuid not null references observations(id) on delete cascade,
  corrective_action_id uuid not null references corrective_actions(id) on delete cascade,
  verifier_id uuid not null references profiles(id),
  result text not null check (result in ('cleared','rejected')),
  note text not null,
  verified_at timestamptz not null default now(),
  evidence_sha256 text,
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists idx_obs_verification_observation on observation_verifications(observation_id,verified_at desc);

-- Replace the previous 4-argument assignment function with an explicit
-- observation-selection API. The server refuses implicit "all open observations".
drop function if exists epas_dm_issue_corrective_action(uuid,uuid,text,date);
create or replace function epas_dm_issue_corrective_action(
  p_action_id uuid,
  p_assignee_id uuid,
  p_instruction text,
  p_due_date date,
  p_observation_ids uuid[]
) returns corrective_actions
language plpgsql
security definer
set search_path=public
as $$
declare
  v_action corrective_actions;
  v_count integer;
  v_selected integer;
begin
  if not epas_has_role('dm') then
    raise exception 'Only DM may issue corrective action';
  end if;

  if coalesce(array_length(p_observation_ids,1),0)=0 then
    raise exception 'Select at least one exact survey observation for this corrective action';
  end if;

  select * into v_action from corrective_actions where id=p_action_id for update;
  if v_action.id is null then raise exception 'Corrective action not found'; end if;
  if v_action.assigned_to <> auth.uid() or v_action.status <> 'open' then
    raise exception 'Corrective action is not awaiting this DM';
  end if;
  if coalesce(trim(p_instruction),'')='' then raise exception 'Corrective instruction is required'; end if;
  if p_due_date < current_date then raise exception 'Corrective action due date cannot be in the past'; end if;

  if not exists(
    select 1 from project_members pm
    where pm.project_id=v_action.project_id and pm.user_id=p_assignee_id and pm.active
      and pm.role in ('surveyor','ship_management')
  ) then
    raise exception 'Corrective action assignee must be an active Surveyor or Ship Management project member';
  end if;

  select count(*) into v_count
  from observations o
  where o.rfi_id=v_action.rfi_id
    and o.status='open';

  select count(*) into v_selected
  from observations o
  where o.id = any(p_observation_ids)
    and o.rfi_id=v_action.rfi_id
    and o.status='open';

  if v_selected <> coalesce(array_length(p_observation_ids,1),0) then
    raise exception 'Every selected observation must belong to this RFI and remain open';
  end if;

  if exists(
    select 1
    from corrective_action_observations cao
    join observations o on o.id=cao.observation_id
    where cao.observation_id = any(p_observation_ids)
  ) then
    raise exception 'One or more selected observations are already assigned to another corrective action';
  end if;

  if v_count=0 then raise exception 'No open survey observations remain'; end if;

  update corrective_actions
  set assigned_to=p_assignee_id,
      assigned_by=auth.uid(),
      instruction=p_instruction,
      due_at=p_due_date::timestamptz,
      status='in_progress'
  where id=p_action_id
  returning * into v_action;

  insert into corrective_action_observations(corrective_action_id,observation_id,linked_by)
  select v_action.id,unnest(p_observation_ids),auth.uid();

  update observations o
  set corrective_action_id=v_action.id
  where o.id=any(p_observation_ids);

  perform epas_create_task(
    v_action.project_id,'CORRECTIVE_ACTION_EXECUTION',p_assignee_id,
    p_instruction,'corrective_action',v_action.id,p_due_date::timestamptz,'high'
  );

  perform epas_audit(
    v_action.project_id,'CORRECTIVE_ACTION_ASSIGNED','corrective_action',v_action.id,
    'open','in_progress',p_instruction,
    jsonb_build_object('assignee',p_assignee_id,'observation_ids',p_observation_ids)
  );

  return v_action;
end;
$$;
grant execute on function epas_dm_issue_corrective_action(uuid,uuid,text,date,uuid[]) to authenticated;

-- Read-only helper for DM UI; security definer prevents direct table exposure.
create or replace function epas_dm_action_observations(p_action_id uuid)
returns table(
  observation_id uuid,
  obs_code text,
  description text,
  severity text,
  status text,
  linked boolean
)
language sql
security definer
set search_path=public
stable
as $$
  select o.id,o.obs_code,o.description,o.severity,o.status,
         exists(select 1 from corrective_action_observations cao
                where cao.corrective_action_id=p_action_id and cao.observation_id=o.id)
  from observations o
  join corrective_actions ca on ca.rfi_id=o.rfi_id
  where ca.id=p_action_id
    and o.status='open'
  order by o.raised_at;
$$;
grant execute on function epas_dm_action_observations(uuid) to authenticated;

-- ================================================================
-- 6. SINGLE CONTROLLED OBSERVATION-CLOSURE PATH
-- ================================================================
-- The old generic clear function is no longer callable by authenticated users.
revoke execute on function epas_clear_survey_observation(uuid,text) from authenticated,anon,public;

-- Verification is a separate, explicit business transaction. It can only be
-- executed by the DM assigned to the corrective-action verification task.
create or replace function epas_dm_verify_corrective_action(
  p_action_id uuid,
  p_verification_note text
) returns corrective_actions
language plpgsql
security definer
set search_path=public
as $$
declare
  v_action corrective_actions;
  v_open integer;
  v_task uuid;
  v_project uuid;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may verify corrective action'; end if;
  if coalesce(trim(p_verification_note),'')='' then raise exception 'Verification note is required'; end if;

  select * into v_action from corrective_actions where id=p_action_id for update;
  if v_action.id is null then raise exception 'Corrective action not found'; end if;
  if v_action.assigned_by<>auth.uid() then raise exception 'Corrective action verification belongs to another DM'; end if;
  if v_action.status<>'submitted' then raise exception 'Corrective action must have submitted evidence'; end if;
  if coalesce(v_action.evidence_path,'')='' or coalesce(v_action.evidence_sha256,'')='' then
    raise exception 'Controlled corrective evidence integrity metadata is required';
  end if;

  select id into v_task
  from workflow_tasks
  where entity_type='corrective_action' and entity_id=p_action_id
    and to_user_id=auth.uid() and task_type='DM_CORRECTIVE_ACTION_VERIFY'
    and status in ('pending','accepted','in_progress')
  order by created_at desc limit 1;
  if v_task is null then raise exception 'No active corrective-action verification task exists for this DM'; end if;

  select count(*) into v_open
  from observations o
  join corrective_action_observations cao on cao.observation_id=o.id
  where cao.corrective_action_id=p_action_id and o.status='open';
  if v_open=0 then raise exception 'No open observations are linked to this corrective action'; end if;

  insert into observation_verifications(observation_id,corrective_action_id,verifier_id,result,note,evidence_sha256,metadata)
  select o.id,p_action_id,auth.uid(),'cleared',p_verification_note,v_action.evidence_sha256,
         jsonb_build_object('controlled_evidence_path',v_action.evidence_path)
  from observations o
  join corrective_action_observations cao on cao.observation_id=o.id
  where cao.corrective_action_id=p_action_id and o.status='open';

  update observations o
  set status='cleared',cleared_at=now(),cleared_by=auth.uid(),verified_at=now(),
      clearance_note=p_verification_note
  from corrective_action_observations cao
  where cao.observation_id=o.id and cao.corrective_action_id=p_action_id and o.status='open';

  update corrective_actions
  set status='verified',verified_by=auth.uid(),verified_at=now(),verified_note=p_verification_note
  where id=p_action_id
  returning * into v_action;

  update workflow_tasks set status='completed',completed_at=now(),completed_by=auth.uid(),completed_note=p_verification_note
  where id=v_task;

  v_project:=v_action.project_id;
  perform epas_audit(v_project,'CORRECTIVE_ACTION_VERIFIED','corrective_action',p_action_id,
    'submitted','verified',p_verification_note,
    jsonb_build_object('observation_count',v_open,'controlled_closure',true));

  -- The same controlled transaction creates the required follow-up RFI after
  -- closure; the follow-up function never performs observation clearing.
  perform epas_dm_create_followup_rfi(p_action_id);

  return v_action;
end;
$$;
grant execute on function epas_dm_verify_corrective_action(uuid,text) to authenticated;

-- Follow-up creation now requires prior controlled verification. It never clears
-- observations itself.
create or replace function epas_dm_create_followup_rfi(p_action_id uuid)
returns rfis
language plpgsql
security definer
set search_path=public
as $$
declare
  v_action corrective_actions;
  v_old rfis;
  v_new rfis;
  v_task uuid;
  v_type text;
begin
  if not epas_has_role('dm') then raise exception 'Only DM may create follow-up RFI'; end if;
  select * into v_action from corrective_actions where id=p_action_id for update;
  if v_action.id is null then raise exception 'Corrective action not found'; end if;
  if v_action.assigned_by<>auth.uid() then raise exception 'Follow-up creation belongs to another DM'; end if;
  if v_action.status<>'verified' then raise exception 'Corrective action must be verified before follow-up creation'; end if;

  select * into v_old from rfis where id=v_action.rfi_id for update;
  if v_old.id is null then raise exception 'Original RFI not found'; end if;
  if exists(select 1 from observations where rfi_id=v_old.id and status='open') then
    raise exception 'All observations must be controlled through verification before follow-up creation';
  end if;

  v_type:=case
    when v_old.phase='nsc_survey' then 'NSC_REWORK_VERIFICATION'
    when v_old.phase='in_service' then 'IN_SERVICE_OBSERVATION_CLEARANCE'
    else 'GENERAL_FOLLOW_UP'
  end;

  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,assigned_dm_id,requested_date,priority,follow_up_of_rfi_id,scope_note)
  values(v_old.project_id,v_old.vessel_id,v_old.phase,v_old.survey_type,
         v_old.rfi_code||'-FU', 'pending_allocation',auth.uid(),auth.uid(),current_date,v_old.priority,v_old.id,
         'Follow-up type: '||v_type)
  returning * into v_new;

  perform epas_create_task(v_new.project_id,'FOLLOW_UP_RFI_DM_SCOPE_REVIEW',auth.uid(),
    'Follow-up scope review: '||v_type,'rfi',v_new.id,null,'high');

  perform epas_audit(v_new.project_id,'FOLLOW_UP_RFI_CREATED','rfi',v_new.id,
    null,'pending_allocation','Controlled follow-up RFI created',
    jsonb_build_object('follow_up_of_rfi_id',v_old.id,'follow_up_type',v_type,'corrective_action_id',p_action_id));
  return v_new;
end;
$$;
grant execute on function epas_dm_create_followup_rfi(uuid) to authenticated;

-- ================================================================
-- 7. STAKEHOLDER RFI PERMISSIONS: ROLE-SPECIFIC INITIATION
--    Shipyard: NSC Survey RFI only
--    Owner / Ship Management: In-Service Survey RFI only
-- ================================================================
alter table rfis add column if not exists scope_note text;
alter table rfis add column if not exists requester_role text;
alter table rfis add column if not exists follow_up_type text;

-- Direct writes are forbidden. All external initiation goes through the RPC.
revoke insert,update,delete on rfis from authenticated,anon;

create or replace function epas_stakeholder_create_rfi(
  p_project_id uuid,
  p_vessel_id uuid,
  p_phase text,
  p_survey_type text,
  p_requested_date date,
  p_priority text,
  p_scope_note text
) returns rfis
language plpgsql
security definer
set search_path=public
as $$
declare
  v_role text;
  v_rfi rfis;
  v_gm uuid;
  v_code text;
begin
  select role into v_role from profiles where id=auth.uid();
  if v_role not in ('owner','ship_management','shipyard') then
    raise exception 'Only Owner, Ship Management, or Shipyard may initiate stakeholder RFIs';
  end if;

  -- Business rule: NSC survey requests originate from the Shipyard;
  -- In-Service survey requests originate from Owner or Ship Management.
  if v_role='shipyard' and p_phase<>'nsc_survey' then
    raise exception 'Shipyard may initiate NSC Survey RFIs only';
  end if;
  if v_role in ('owner','ship_management') and p_phase<>'in_service' then
    raise exception 'Owner and Ship Management may initiate In-Service Survey RFIs only';
  end if;
  if p_phase not in ('nsc_survey','in_service') then raise exception 'Invalid survey phase'; end if;
  if p_priority not in ('low','medium','high') then raise exception 'Invalid priority'; end if;
  if coalesce(trim(p_survey_type),'')='' then raise exception 'Survey type is required'; end if;
  if coalesce(trim(p_scope_note),'')='' then raise exception 'Survey scope is required'; end if;
  if not exists(select 1 from project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid() and pm.active and pm.role=v_role) then
    raise exception 'You are not an active stakeholder member of this project';
  end if;
  if not exists(select 1 from vessels where id=p_vessel_id) then raise exception 'Vessel not found'; end if;

  v_code:='RFI-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(p_project_id,p_vessel_id,p_phase,p_survey_type,v_code,'pending_allocation',auth.uid(),coalesce(p_requested_date,current_date),p_priority,p_scope_note,v_role)
  returning * into v_rfi;

  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  if v_gm is not null then
    perform epas_create_task(v_rfi.project_id,'GM_SURVEY_RFI_INTAKE',v_gm,
      'Stakeholder RFI submitted by '||v_role||': '||v_code,'rfi',v_rfi.id,null,p_priority);
  end if;
  perform epas_audit(v_rfi.project_id,'STAKEHOLDER_RFI_CREATED','rfi',v_rfi.id,
    null,'pending_allocation',p_scope_note,jsonb_build_object('requester_role',v_role,'survey_phase',p_phase));
  return v_rfi;
end;
$$;
grant execute on function epas_stakeholder_create_rfi(uuid,uuid,text,text,date,text,text) to authenticated;

create or replace function epas_stakeholder_rfi_status(p_rfi_id uuid)
returns rfis
language plpgsql
security definer
set search_path=public
stable
as $$
declare v_rfi rfis; v_role text;
begin
  select role into v_role from profiles where id=auth.uid();
  select * into v_rfi from rfis where id=p_rfi_id;
  if v_rfi.id is null then raise exception 'RFI not found'; end if;
  if not exists(
    select 1 from project_members pm where pm.project_id=v_rfi.project_id and pm.user_id=auth.uid() and pm.active
      and pm.role in ('owner','ship_management','shipyard')
  ) then raise exception 'Stakeholder is not a member of this project'; end if;
  if v_rfi.requested_by<>auth.uid() and v_role not in ('gm','dm') then
    raise exception 'Stakeholders may only view their own initiated RFI status';
  end if;
  -- Return the row but suppress internal notes for external roles.
  if v_role in ('owner','ship_management','shipyard') then
    v_rfi.dm_review_note:=null; v_rfi.gm_decision_note:=null;
  end if;
  return v_rfi;
end;
$$;
grant execute on function epas_stakeholder_rfi_status(uuid) to authenticated;

-- ================================================================
-- 8. EXPLICIT CERTIFICATE LIFECYCLE STATE MACHINE
-- ================================================================
alter table certificates add column if not exists lifecycle_state text not null default 'ACTIVE';
alter table certificates add column if not exists parent_certificate_id uuid references certificates(id);
alter table certificates add column if not exists superseded_at timestamptz;
alter table certificates add column if not exists lifecycle_note text;
alter table certificates add column if not exists last_lifecycle_at timestamptz;

alter table certificates drop constraint if exists certificates_lifecycle_state_check;
alter table certificates add constraint certificates_lifecycle_state_check check (lifecycle_state in (
  'DRAFT','PENDING_GM_APPROVAL','GM_APPROVED','PENDING_DM_ACK','READY_FOR_ISSUANCE',
  'ISSUED','ACTIVE','EXPIRING','EXPIRED','SUPERSEDED'
));

update certificates set lifecycle_state=case
  when status='superseded' then 'SUPERSEDED'
  when status='expired' then 'EXPIRED'
  else 'ACTIVE'
end,
last_lifecycle_at=coalesce(last_lifecycle_at,created_at);

create or replace function epas_refresh_certificate_lifecycle()
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_count integer;
begin
  update certificates
  set lifecycle_state=case
      when status='superseded' then 'SUPERSEDED'
      when expiry_date < current_date then 'EXPIRED'
      when expiry_date <= current_date + 60 then 'EXPIRING'
      when status='active' then 'ACTIVE'
      else lifecycle_state end,
      last_lifecycle_at=now()
  where status in ('active','expired','superseded');
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
grant execute on function epas_refresh_certificate_lifecycle() to authenticated;

create or replace function epas_transition_certificate_state(
  p_certificate_id uuid,
  p_to_state text,
  p_note text
) returns certificates
language plpgsql
security definer
set search_path=public
as $$
declare v_cert certificates; v_from text; v_role text;
begin
  select role into v_role from profiles where id=auth.uid();
  select * into v_cert from certificates where id=p_certificate_id for update;
  if v_cert.id is null then raise exception 'Certificate not found'; end if;
  v_from:=v_cert.lifecycle_state;
  if p_to_state not in ('DRAFT','PENDING_GM_APPROVAL','GM_APPROVED','PENDING_DM_ACK','READY_FOR_ISSUANCE','ISSUED','ACTIVE','EXPIRING','EXPIRED','SUPERSEDED') then
    raise exception 'Invalid certificate lifecycle state';
  end if;
  if p_to_state in ('GM_APPROVED','ISSUED','ACTIVE','SUPERSEDED') and v_role<>'gm' then
    raise exception 'Only GM may perform this certificate lifecycle transition';
  end if;
  if p_to_state in ('READY_FOR_ISSUANCE','PENDING_DM_ACK') and v_role<>'dm' then
    raise exception 'Only DM may perform this certificate lifecycle transition';
  end if;
  if not (
    (v_from='DRAFT' and p_to_state='PENDING_GM_APPROVAL') or
    (v_from='PENDING_GM_APPROVAL' and p_to_state='GM_APPROVED') or
    (v_from='GM_APPROVED' and p_to_state='PENDING_DM_ACK') or
    (v_from='PENDING_DM_ACK' and p_to_state='READY_FOR_ISSUANCE') or
    (v_from='READY_FOR_ISSUANCE' and p_to_state in ('ISSUED','ACTIVE')) or
    (v_from='ISSUED' and p_to_state in ('ACTIVE','EXPIRING')) or
    (v_from='ACTIVE' and p_to_state in ('EXPIRING','EXPIRED','SUPERSEDED')) or
    (v_from='EXPIRING' and p_to_state in ('ACTIVE','EXPIRED','SUPERSEDED')) or
    (v_from='EXPIRED' and p_to_state='SUPERSEDED')
  ) then raise exception 'Invalid certificate lifecycle transition: % -> %',v_from,p_to_state; end if;

  update certificates set lifecycle_state=p_to_state,
      status=case when p_to_state in ('SUPERSEDED','EXPIRED') then lower(p_to_state) else status end,
      superseded_at=case when p_to_state='SUPERSEDED' then now() else superseded_at end,
      lifecycle_note=p_note,last_lifecycle_at=now()
  where id=p_certificate_id returning * into v_cert;

  insert into certificate_lifecycle_events(certificate_id,event_type,from_status,to_status,actor_id,note)
  values(v_cert.id,'STATE_TRANSITION',v_from,p_to_state,auth.uid(),p_note);
  return v_cert;
end;
$$;
grant execute on function epas_transition_certificate_state(uuid,text,text) to authenticated;

-- Ensure existing issuance functions stamp the explicit lifecycle state.
update certificates set lifecycle_state='ACTIVE' where status='active';

-- ================================================================
-- 9. CONTROLLED DOCUMENT LIFECYCLE + REVISION LINEAGE / POLICY
-- ================================================================
alter table documents add column if not exists document_number text;
alter table documents add column if not exists revision_no integer not null default 1;
alter table documents add column if not exists lifecycle_state text not null default 'DRAFT';
alter table documents add column if not exists parent_document_id uuid references documents(id);
alter table documents add column if not exists supersedes_document_id uuid references documents(id);
alter table documents add column if not exists approved_by uuid references profiles(id);
alter table documents add column if not exists approved_at timestamptz;
alter table documents add column if not exists released_by uuid references profiles(id);
alter table documents add column if not exists released_at timestamptz;

alter table documents drop constraint if exists documents_lifecycle_state_check;
alter table documents add constraint documents_lifecycle_state_check check (lifecycle_state in (
  'DRAFT','VALIDATION','UNDER_REVIEW','AMENDMENT_REQUIRED','REJECTED','APPROVED','RELEASED','SUPERSEDED','WITHDRAWN'
));

create table if not exists document_policies (
  document_type text primary key,
  allowed_mime_types text[] not null,
  max_size_bytes bigint not null check (max_size_bytes>0),
  requires_hash boolean not null default true,
  requires_revision boolean not null default true,
  requires_release boolean not null default true,
  active boolean not null default true
);
insert into document_policies(document_type,allowed_mime_types,max_size_bytes) values
('PLAN_DRAWING',array['application/pdf'],26214400),
('SURVEY_REPORT',array['application/pdf'],52428800),
('CORRECTIVE_EVIDENCE',array['application/pdf','image/jpeg','image/png'],26214400),
('CERTIFICATE',array['application/pdf'],52428800),
('GENERAL_PROJECT_DOCUMENT',array['application/pdf'],52428800)
on conflict(document_type) do update set allowed_mime_types=excluded.allowed_mime_types,max_size_bytes=excluded.max_size_bytes;

create table if not exists document_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id) on delete cascade,
  event_type text not null,
  from_state text,
  to_state text,
  actor_id uuid references profiles(id),
  note text,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists idx_document_lifecycle_doc on document_lifecycle_events(document_id,created_at desc);

create or replace function epas_document_transition(
  p_document_id uuid,
  p_to_state text,
  p_note text
) returns documents
language plpgsql
security definer
set search_path=public
as $$
declare v_doc documents; v_from text; v_role text;
begin
  select role into v_role from profiles where id=auth.uid();
  select * into v_doc from documents where id=p_document_id for update;
  if v_doc.id is null then raise exception 'Document not found'; end if;
  v_from:=v_doc.lifecycle_state;
  if p_to_state not in ('DRAFT','VALIDATION','UNDER_REVIEW','AMENDMENT_REQUIRED','REJECTED','APPROVED','RELEASED','SUPERSEDED','WITHDRAWN') then raise exception 'Invalid document lifecycle state'; end if;
  if p_to_state in ('APPROVED','RELEASED','WITHDRAWN','SUPERSEDED') and v_role not in ('gm','dm') then
    raise exception 'Only GM or DM may perform controlled document lifecycle decisions';
  end if;
  if p_to_state='RELEASED' and (coalesce(v_doc.sha256,'')='' or coalesce(v_doc.storage_path,'')='') then
    raise exception 'Document hash and storage path are required before release';
  end if;
  if not (
    (v_from='DRAFT' and p_to_state='VALIDATION') or
    (v_from='VALIDATION' and p_to_state in ('UNDER_REVIEW','REJECTED')) or
    (v_from='UNDER_REVIEW' and p_to_state in ('APPROVED','AMENDMENT_REQUIRED','REJECTED')) or
    (v_from='AMENDMENT_REQUIRED' and p_to_state in ('VALIDATION','UNDER_REVIEW')) or
    (v_from='APPROVED' and p_to_state='RELEASED') or
    (v_from='RELEASED' and p_to_state='SUPERSEDED') or
    (v_from='RELEASED' and p_to_state='WITHDRAWN')
  ) then raise exception 'Invalid document lifecycle transition: % -> %',v_from,p_to_state; end if;

  update documents set lifecycle_state=p_to_state,
    status=case
      when p_to_state='APPROVED' then 'approved'
      when p_to_state='AMENDMENT_REQUIRED' then 'amendments_required'
      when p_to_state='REJECTED' then 'rejected'
      else status end,
    approved_by=case when p_to_state='APPROVED' then auth.uid() else approved_by end,
    approved_at=case when p_to_state='APPROVED' then now() else approved_at end,
    released_by=case when p_to_state='RELEASED' then auth.uid() else released_by end,
    released_at=case when p_to_state='RELEASED' then now() else released_at end,
    release_status=case when p_to_state='RELEASED' then 'released' when p_to_state='WITHDRAWN' then 'withdrawn' else release_status end,
    stakeholder_visible=case when p_to_state='RELEASED' then true when p_to_state in ('WITHDRAWN','SUPERSEDED') then false else stakeholder_visible end
  where id=p_document_id returning * into v_doc;

  if p_to_state='RELEASED' and v_doc.document_number is not null then
    update documents
    set lifecycle_state='SUPERSEDED', release_status='withdrawn', stakeholder_visible=false
    where project_id=v_doc.project_id
      and document_number=v_doc.document_number
      and id<>v_doc.id
      and revision_no < v_doc.revision_no
      and lifecycle_state='RELEASED';
  end if;

  insert into document_lifecycle_events(document_id,event_type,from_state,to_state,actor_id,note)
  values(v_doc.id,'STATE_TRANSITION',v_from,p_to_state,auth.uid(),p_note);
  return v_doc;
end;
$$;
grant execute on function epas_document_transition(uuid,text,text) to authenticated;

drop function if exists epas_register_document_revision(uuid,text,text,text,text,bigint,text,text);
create or replace function epas_register_document_revision(
  p_parent_document_id uuid,p_file_name text,p_storage_path text,p_sha256 text,
  p_mime_type text,p_file_size_bytes bigint,p_document_number text,p_note text
) returns documents
language plpgsql security definer set search_path=public as $$
declare v_parent documents; v_doc documents; v_rev integer; v_policy document_policies;
begin
  select * into v_parent from documents where id=p_parent_document_id for update;
  if v_parent.id is null then raise exception 'Parent document not found'; end if;
  select * into v_policy from document_policies where document_type=case when v_parent.category='drawing' then 'PLAN_DRAWING' else 'GENERAL_PROJECT_DOCUMENT' end and active;
  if v_policy.id is null then raise exception 'No active document policy exists'; end if;
  if not (p_mime_type=any(v_policy.allowed_mime_types)) then raise exception 'File MIME type is not allowed by document policy'; end if;
  if p_file_size_bytes>v_policy.max_size_bytes then raise exception 'File exceeds document policy size limit'; end if;
  if v_policy.requires_hash and coalesce(p_sha256,'')='' then raise exception 'SHA-256 is required'; end if;
  select coalesce(max(revision_no),0)+1 into v_rev from documents where project_id=v_parent.project_id and coalesce(document_number,p_document_number)=coalesce(p_document_number,v_parent.document_number);
  insert into documents(project_id,category,file_name,version,status,storage_path,uploaded_by,uploaded_at,sha256,mime_type,file_size_bytes,release_status,stakeholder_visible,document_number,revision_no,lifecycle_state,parent_document_id,supersedes_document_id)
  values(v_parent.project_id,v_parent.category,p_file_name,v_rev,'pending_review',p_storage_path,auth.uid(),now(),p_sha256,p_mime_type,p_file_size_bytes,'internal',false,coalesce(p_document_number,v_parent.document_number),v_rev,'DRAFT',v_parent.id,v_parent.id)
  returning * into v_doc;
  insert into document_lifecycle_events(document_id,event_type,to_state,actor_id,note,metadata)
  values(v_doc.id,'REVISION_CREATED','DRAFT',auth.uid(),p_note,jsonb_build_object('parent_document_id',v_parent.id,'revision_no',v_rev));
  return v_doc;
end;
$$;
grant execute on function epas_register_document_revision(uuid,text,text,text,text,bigint,text,text) to authenticated;

-- ================================================================
-- 10. SECURITY / LIVE-ACCEPTANCE PREPARATION
-- ================================================================
create table if not exists security_acceptance_runs (
  id uuid primary key default gen_random_uuid(),
  environment text not null,
  run_by uuid references profiles(id),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'planned' check(status in ('planned','running','passed','failed')),
  notes text
);

create table if not exists security_acceptance_results (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references security_acceptance_runs(id) on delete cascade,
  test_code text not null,
  role_name text,
  expected_result text not null,
  actual_result text,
  passed boolean,
  executed_at timestamptz,
  details jsonb not null default '{}'::jsonb
);
create index if not exists idx_security_acceptance_run on security_acceptance_results(run_id,test_code);

-- A database-level preflight function catches the most important deployment
-- hazards before users are allowed into a production environment.
create or replace function epas_security_preflight()
returns table(check_code text,passed boolean,details text)
language sql
security definer
set search_path=public
stable
as $$
  select 'RFI_WRITE_LOCK',has_table_privilege('authenticated','public.rfis','INSERT')=false,
         'Authenticated direct INSERT on rfis must be revoked; stakeholder initiation uses RPC.'
  union all
  select 'OBSERVATION_GENERIC_CLEAR_REVOKED',has_function_privilege('authenticated','public.epas_clear_survey_observation(uuid,text)','EXECUTE')=false,
         'Generic survey observation clearing must not be callable by authenticated users.'
  union all
  select 'CA_EXACT_BINDING_TABLE',to_regclass('public.corrective_action_observations') is not null,
         'Exact corrective-action observation binding table exists.'
  union all
  select 'OBS_VERIFICATION_HISTORY',to_regclass('public.observation_verifications') is not null,
         'Controlled observation verification history exists.'
  union all
  select 'CERTIFICATE_STATE_MACHINE',to_regclass('public.certificate_lifecycle_events') is not null,
         'Certificate lifecycle events exist.'
  union all
  select 'DOCUMENT_POLICY',to_regclass('public.document_policies') is not null,
         'Document policy registry exists.'
  union all
  select 'DOCUMENT_LIFECYCLE',to_regclass('public.document_lifecycle_events') is not null,
         'Document lifecycle events exist.';
$$;
grant execute on function epas_security_preflight() to authenticated;

commit;
