-- EPAS v1.6 Flow Alignment / Critical Workflow Closure
-- Apply AFTER production_v1_5.sql and production_v1_5_1_security_and_release.sql.
--
-- This migration aligns the executable state machine with the supplied GM + DM
-- workflow pictures:
--   Plan Appraisal: GM -> DM -> Engineer -> DM -> GM -> Designer -> DM -> Engineer
--   Survey RFI: GM -> DM -> Surveyor -> DM -> GM -> Corrective Action -> DM ->
--               Follow-up RFI -> DM -> Surveyor/Ship Management -> DM -> GM
--
-- Key controls:
-- 1. DM may review survey observations, but cannot clear them before GM send-back
--    and verified corrective action.
-- 2. Corrective action is linked to the open observations it resolves.
-- 3. Follow-up RFI is linked to the original RFI.
-- 4. Full certificate issuance requires DM acknowledgement of GM final approval.
-- 5. Finalising an Interim Certificate requires the linked follow-up RFI to have
--    completed the same DM -> GM approval gate.
-- 6. Decision notes are persisted on the business record for the professional
--    review package.

begin;

alter table observations
  add column if not exists corrective_action_id uuid references corrective_actions(id);

create index if not exists idx_observations_corrective_action
  on observations(corrective_action_id);

alter table rfis
  add column if not exists follow_up_of_rfi_id uuid references rfis(id);

alter table rfis
  add column if not exists dm_review_note text;

alter table rfis
  add column if not exists gm_decision_note text;

create index if not exists idx_rfis_follow_up
  on rfis(follow_up_of_rfi_id);

-- ------------------------------------------------------------
-- A. DM survey review: review and forward only. Do NOT clear
--    observations at this stage.
-- ------------------------------------------------------------
create or replace function epas_dm_forward_survey(
  p_rfi_id uuid,
  p_remarks text
) returns rfis
language plpgsql
security definer
set search_path=public
as $$
declare
  v_rfi rfis;
  v_gm uuid;
  v_old text;
begin
  if not epas_has_role('dm') then
    raise exception 'Only Department Manager may review survey report';
  end if;

  select * into v_rfi
  from rfis
  where id=p_rfi_id
  for update;

  if v_rfi.id is null then
    raise exception 'RFI not found';
  end if;

  if v_rfi.assigned_dm_id <> auth.uid() then
    raise exception 'RFI is assigned to another DM';
  end if;

  if v_rfi.status not in ('observations_logged','survey_in_progress') then
    raise exception 'RFI is not awaiting DM survey review';
  end if;

  if coalesce(trim(p_remarks),'')='' then
    raise exception 'DM review remarks are required';
  end if;

  v_old := v_rfi.status;

  update rfis
  set status='pending_gm_approval',
      dm_review_note=p_remarks,
      updated_at=now()
  where id=p_rfi_id
  returning * into v_rfi;

  update workflow_tasks
  set status='completed',
      completed_at=now(),
      completed_by=auth.uid(),
      completed_note=p_remarks
  where entity_type='rfi'
    and entity_id=p_rfi_id
    and to_user_id=auth.uid()
    and task_type='SURVEY_DM_REVIEW'
    and status in ('pending','accepted','in_progress');

  select id into v_gm
  from profiles
  where role='gm'
  order by created_at
  limit 1;

  perform epas_create_task(
    v_rfi.project_id,
    'GM_SURVEY_FINAL_APPROVAL',
    v_gm,
    p_remarks,
    'rfi',
    p_rfi_id,
    null,
    'high'
  );

  insert into workflow_events(
    project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note
  )
  values(
    v_rfi.project_id,'rfi',p_rfi_id,'DM_FORWARDED_TO_GM',
    v_old,'pending_gm_approval',auth.uid(),p_remarks
  );

  perform epas_audit(
    v_rfi.project_id,'DM_SURVEY_REVIEW_COMPLETED','rfi',p_rfi_id,
    v_old,'pending_gm_approval',p_remarks,
    jsonb_build_object(
      'open_observation_count',
      (select count(*) from observations where rfi_id=p_rfi_id and status='open')
    )
  );

  return v_rfi;
end;
$$;

grant execute on function epas_dm_forward_survey(uuid,text) to authenticated;

-- ------------------------------------------------------------
-- B. Corrective action assignment must bind the action to the
--    exact survey observations that it resolves.
-- ------------------------------------------------------------
create or replace function epas_dm_issue_corrective_action(
  p_action_id uuid,
  p_assignee_id uuid,
  p_instruction text,
  p_due_date date
) returns corrective_actions
language plpgsql
security definer
set search_path=public
as $$
declare
  v_action corrective_actions;
  v_open_obs integer;
begin
  if not epas_has_role('dm') then
    raise exception 'Only DM may issue corrective action';
  end if;

  select * into v_action
  from corrective_actions
  where id=p_action_id
  for update;

  if v_action.id is null then
    raise exception 'Corrective action not found';
  end if;

  if v_action.assigned_to <> auth.uid() or v_action.status <> 'open' then
    raise exception 'Corrective action is not awaiting this DM';
  end if;

  if coalesce(trim(p_instruction),'')='' then
    raise exception 'Corrective instruction is required';
  end if;

  if p_due_date < current_date then
    raise exception 'Corrective action due date cannot be in the past';
  end if;

  if not exists(
    select 1
    from project_members pm
    where pm.project_id=v_action.project_id
      and pm.user_id=p_assignee_id
      and pm.active
      and pm.role in ('surveyor','ship_management')
  ) then
    raise exception 'Corrective action assignee must be an active Surveyor or Ship Management project member';
  end if;

  select count(*) into v_open_obs
  from observations
  where rfi_id=v_action.rfi_id
    and status='open';

  if v_open_obs=0 then
    raise exception 'No open survey observations remain; a corrective-action task is not required';
  end if;

  update corrective_actions
  set assigned_to=p_assignee_id,
      assigned_by=auth.uid(),
      instruction=p_instruction,
      due_at=p_due_date::timestamptz,
      status='in_progress'
  where id=p_action_id
  returning * into v_action;

  update observations
  set corrective_action_id=v_action.id
  where rfi_id=v_action.rfi_id
    and status='open'
    and corrective_action_id is null;

  perform epas_create_task(
    v_action.project_id,
    'CORRECTIVE_ACTION_EXECUTION',
    p_assignee_id,
    p_instruction,
    'corrective_action',
    v_action.id,
    p_due_date::timestamptz,
    'high'
  );

  perform epas_audit(
    v_action.project_id,
    'CORRECTIVE_ACTION_ASSIGNED',
    'corrective_action',
    v_action.id,
    'open',
    'in_progress',
    p_instruction,
    jsonb_build_object(
      'assignee',p_assignee_id,
      'linked_open_observations',
      (select count(*) from observations where corrective_action_id=v_action.id and status='open')
    )
  );

  return v_action;
end;
$$;

grant execute on function epas_dm_issue_corrective_action(uuid,uuid,text,date) to authenticated;

-- ------------------------------------------------------------
-- C. Only DM may verify the corrective action and only after the
--    evidence submission. Verification closes the linked survey
--    observations and creates the follow-up RFI.
-- ------------------------------------------------------------
create or replace function epas_dm_create_followup_rfi(
  p_action_id uuid
) returns rfis
language plpgsql
security definer
set search_path=public
as $$
declare
  v_action corrective_actions;
  v_old rfis;
  v_new rfis;
  v_open integer;
  v_task uuid;
begin
  if not epas_has_role('dm') then
    raise exception 'Only DM may verify corrective action and create follow-up RFI';
  end if;

  select * into v_action
  from corrective_actions
  where id=p_action_id
  for update;

  if v_action.id is null then
    raise exception 'Corrective action not found';
  end if;

  if v_action.assigned_by <> auth.uid() then
    raise exception 'Corrective action verification belongs to another DM';
  end if;

  if v_action.status <> 'submitted' then
    raise exception 'Corrective action must have submitted evidence before DM verification';
  end if;

  if coalesce(v_action.evidence_path,'')='' or coalesce(v_action.evidence_sha256,'')='' then
    raise exception 'Controlled corrective evidence integrity metadata is required';
  end if;

  select count(*) into v_open
  from observations
  where corrective_action_id=v_action.id
    and status='open';

  if v_open=0 then
    raise exception 'No open observations are linked to this corrective action';
  end if;

  select * into v_old
  from rfis
  where id=v_action.rfi_id
  for update;

  -- Complete the DM verification task.
  update workflow_tasks
  set status='completed',
      completed_at=now(),
      completed_by=auth.uid(),
      completed_note='Corrective action verified; linked observations cleared; follow-up RFI created.'
  where entity_type='corrective_action'
    and entity_id=p_action_id
    and to_user_id=auth.uid()
    and task_type='DM_CORRECTIVE_ACTION_VERIFY'
    and status in ('accepted','in_progress','pending')
  returning id into v_task;

  if v_task is null then
    raise exception 'No active corrective-action verification task exists for this DM';
  end if;

  -- Verification closes the exact observations linked to the action.
  update observations
  set status='cleared',
      cleared_at=now(),
      cleared_by=auth.uid(),
      verified_at=now(),
      clearance_note='Verified through corrective action '||v_action.id::text
  where corrective_action_id=v_action.id
    and status='open';

  update corrective_actions
  set status='verified',
      verified_by=auth.uid(),
      verified_at=now()
  where id=v_action.id
  returning * into v_action;

  -- Follow-up RFI returns to the DM scope-review stage.
  -- Legacy traceability marker: follow_up_of_rfi_id=v_old.id
  insert into rfis(
    project_id,vessel_id,phase,survey_type,rfi_code,status,
    requested_by,assigned_dm_id,requested_date,priority,follow_up_of_rfi_id
  )
  values(
    v_old.project_id,v_old.vessel_id,v_old.phase,v_old.survey_type,
    v_old.rfi_code||'-FU-'||upper(substr(gen_random_uuid()::text,1,4)),
    'allocated_to_dm',auth.uid(),auth.uid(),current_date,'high',v_old.id
  )
  returning * into v_new;

  update corrective_actions
  set status='closed'
  where id=v_action.id;

  perform epas_create_task(
    v_new.project_id,
    'FOLLOW_UP_RFI_DM_SCOPE_REVIEW',
    auth.uid(),
    'Follow-up RFI created after verified corrective action. Review scope and continue the survey loop.',
    'rfi',
    v_new.id,
    null,
    'high'
  );

  perform epas_audit(
    v_new.project_id,
    'CORRECTIVE_ACTION_VERIFIED_FOLLOW_UP_CREATED',
    'rfi',
    v_new.id,
    v_old.status,
    'allocated_to_dm',
    'Corrective action verified and follow-up RFI returned to DM.',
    jsonb_build_object(
      'source_rfi_id',v_old.id,
      'corrective_action_id',v_action.id,
      'cleared_observations',v_open
    )
  );

  return v_new;
end;
$$;

grant execute on function epas_dm_create_followup_rfi(uuid) to authenticated;

-- ------------------------------------------------------------
-- D. Observation clearance is now a controlled verification action.
--    No DM/GM clearing is permitted during the pre-GM review stage.
-- ------------------------------------------------------------
create or replace function epas_clear_survey_observation(
  p_observation_id uuid,
  p_note text
) returns observations
language plpgsql
security definer
set search_path=public
as $$
declare
  v observations;
  v_project uuid;
  v_rfi rfis;
begin
  if not epas_has_role('dm') then
    raise exception 'Only the Department Manager may verify survey observation closure';
  end if;

  select o.* into v
  from observations o
  where o.id=p_observation_id
  for update;

  if v.id is null then
    raise exception 'Survey observation not found';
  end if;

  select r.* into v_rfi
  from rfis r
  where r.id=v.rfi_id;

  v_project := v_rfi.project_id;

  if not epas_is_project_member(v_project) then
    raise exception 'Not authorized for project';
  end if;

  if v.status <> 'open' then
    raise exception 'Observation is already closed';
  end if;

  if v_rfi.status not in ('sent_back_for_rework','certificate_issued') then
    raise exception 'Observation cannot be cleared before GM send-back / corrective-action stage';
  end if;

  if v.corrective_action_id is null then
    raise exception 'Observation is not linked to a verified corrective action';
  end if;

  if not exists(
    select 1
    from corrective_actions ca
    where ca.id=v.corrective_action_id
      and ca.rfi_id=v.rfi_id
      and ca.status in ('submitted','verified','closed')
  ) then
    raise exception 'Linked corrective action has not reached verification';
  end if;

  if coalesce(trim(p_note),'')='' then
    raise exception 'Closure verification note is required';
  end if;

  update observations
  set status='cleared',
      cleared_at=now(),
      cleared_by=auth.uid(),
      clearance_note=p_note,
      verified_at=now()
  where id=v.id
  returning * into v;

  perform epas_audit(
    v_project,'SURVEY_OBSERVATION_CLEARED','observation',v.id,
    'open','cleared',p_note,
    jsonb_build_object('obs_code',v.obs_code,'corrective_action_id',v.corrective_action_id)
  );

  return v;
end;
$$;

grant execute on function epas_clear_survey_observation(uuid,text) to authenticated;

-- ------------------------------------------------------------
-- E. GM final decision persists note and explicitly gates certificate
--    issuance on the DM final-approval acknowledgement task.
-- ------------------------------------------------------------
create or replace function epas_gm_decide_rfi(
  p_rfi_id uuid,
  p_decision text,
  p_note text
) returns rfis
language plpgsql
security definer
set search_path=public
as $$
declare
  v_rfi rfis;
  v_obs integer;
  v_dm uuid;
  v_action corrective_actions;
  v_gm uuid:=auth.uid();
begin
  if not epas_has_role('gm') then
    raise exception 'Only GM may decide Survey RFI';
  end if;

  select * into v_rfi
  from rfis
  where id=p_rfi_id
  for update;

  if v_rfi.status <> 'pending_gm_approval' then
    raise exception 'RFI is not awaiting GM approval';
  end if;

  if p_decision not in ('approved','sent_back') then
    raise exception 'Invalid GM decision';
  end if;

  if coalesce(trim(p_note),'')='' then
    raise exception 'GM decision note is required';
  end if;

  update workflow_tasks
  set status='completed',
      completed_at=now(),
      completed_by=auth.uid(),
      completed_note=p_note
  where entity_type='rfi'
    and entity_id=p_rfi_id
    and to_user_id=auth.uid()
    and task_type='GM_SURVEY_FINAL_APPROVAL'
    and status in ('pending','accepted','in_progress');

  insert into gm_decisions(rfi_id,decided_by,decision,note)
  values(p_rfi_id,v_gm,p_decision,p_note);

  update rfis
  set gm_decision_note=p_note,
      updated_at=now()
  where id=p_rfi_id
  returning * into v_rfi;

  v_dm:=v_rfi.assigned_dm_id;

  if p_decision='sent_back' then
    update rfis
    set status='sent_back_for_rework',
        updated_at=now()
    where id=p_rfi_id
    returning * into v_rfi;

    insert into corrective_actions(
      project_id,rfi_id,assigned_to,assigned_by,instruction,status,due_at
    )
    values(
      v_rfi.project_id,p_rfi_id,v_dm,v_gm,p_note,'open',now()+interval '3 days'
    )
    returning * into v_action;

    perform epas_create_task(
      v_rfi.project_id,'DM_CORRECTIVE_ACTION',v_dm,
      p_note,'corrective_action',v_action.id,v_action.due_at,'high'
    );
  else
    select count(*) into v_obs
    from observations
    where rfi_id=p_rfi_id
      and status='open';

    update rfis
    set status=case when v_obs>0 then 'approved_with_observations' else 'approved_no_observations' end,
        updated_at=now()
    where id=p_rfi_id
    returning * into v_rfi;

    perform epas_create_task(
      v_rfi.project_id,
      'DM_GM_FINAL_APPROVAL_ACK',
      v_dm,
      'GM approved the survey RFI. DM acknowledgement is required before certificate issuance.',
      'rfi',
      p_rfi_id,
      null,
      'normal'
    );
  end if;

  insert into workflow_events(
    project_id,entity_type,entity_id,event_type,from_status,to_status,actor_id,note
  )
  values(
    v_rfi.project_id,'rfi',p_rfi_id,'GM_DECISION',
    'pending_gm_approval',v_rfi.status,v_gm,p_note
  );

  perform epas_audit(
    v_rfi.project_id,'GM_SURVEY_DECISION','rfi',p_rfi_id,
    'pending_gm_approval',v_rfi.status,p_note,
    jsonb_build_object('decision',p_decision,'open_observations',v_obs)
  );

  return v_rfi;
end;
$$;

grant execute on function epas_gm_decide_rfi(uuid,text,text) to authenticated;

-- ------------------------------------------------------------
-- F. Certificate issuance is gated on the DM acknowledgement
--    required by the supplied DM diagram.
-- ------------------------------------------------------------
create or replace function epas_issue_certificate(
  p_rfi_id uuid,
  p_cert_type text,
  p_validity_months integer
) returns certificates
language plpgsql
security definer
set search_path=public
as $$
declare
  v_rfi rfis;
  v_vessel vessels;
  v_cert certificates;
  v_open integer;
  v_ack_exists boolean;
  v_prefix text;
  v_number text;
begin
  if not epas_has_role('gm') then
    raise exception 'Only GM may issue certificates';
  end if;

  select * into v_rfi
  from rfis
  where id=p_rfi_id
  for update;

  if v_rfi.status not in ('approved_no_observations','approved_with_observations') then
    raise exception 'RFI is not eligible for certificate issuance';
  end if;

  select exists(
    select 1
    from workflow_tasks
    where entity_type='rfi'
      and entity_id=p_rfi_id
      and task_type='DM_GM_FINAL_APPROVAL_ACK'
      and status='completed'
  ) into v_ack_exists;

  if not v_ack_exists then
    raise exception 'DM final-approval acknowledgement is required before certificate issuance';
  end if;

  select * into v_vessel
  from vessels
  where id=v_rfi.vessel_id;

  select count(*) into v_open
  from observations
  where rfi_id=p_rfi_id
    and status='open';

  if v_open > 0 and p_cert_type <> 'interim_certificate' then
    raise exception 'Open observations require an Interim Certificate';
  end if;

  if v_open = 0 and p_cert_type='interim_certificate' then
    raise exception 'No open observations; issue the full certificate';
  end if;

  if p_validity_months <= 0 then
    raise exception 'Validity must be positive';
  end if;

  v_prefix := case p_cert_type
    when 'class_certificate' then 'CC'
    when 'interim_certificate' then 'ICC'
    when 'nsc_certificate' then 'NCC'
    else null
  end;

  if v_prefix is null then
    raise exception 'Invalid certificate type';
  end if;

  v_number := v_prefix||'-'||to_char(current_date,'YYYY')||'-'||
              upper(replace(coalesce(v_rfi.rfi_code,'RFI'),' ','-'));

  if exists(select 1 from certificates where cert_number=v_number) then
    v_number := v_number||'-'||substr(gen_random_uuid()::text,1,6);
  end if;

  insert into certificates(
    vessel_id,project_id,rfi_id,cert_type,cert_number,issue_date,expiry_date,
    status,pending_observations,issued_by
  )
  values(
    v_vessel.id,v_rfi.project_id,v_rfi.id,p_cert_type,v_number,current_date,
    (current_date+make_interval(months=>p_validity_months))::date,'active',
    coalesce((select jsonb_agg(description) from observations where rfi_id=p_rfi_id and status='open'),'[]'::jsonb),
    auth.uid()
  )
  returning * into v_cert;

  update rfis
  set status='certificate_issued',
      updated_at=now()
  where id=p_rfi_id;

  insert into certificate_lifecycle_events(
    certificate_id,event_type,from_status,to_status,actor_id,note
  )
  values(
    v_cert.id,'ISSUED','none','active',auth.uid(),
    'Certificate issued after GM approval and DM final-approval acknowledgement.'
  );

  perform epas_audit(
    v_rfi.project_id,'CERTIFICATE_ISSUED','certificate',v_cert.id,
    null,'active',v_cert.cert_number,
    jsonb_build_object('rfi_id',p_rfi_id,'cert_type',p_cert_type,'dm_ack_required',true)
  );

  insert into notifications(
    user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id
  )
  select pm.user_id,'Certificate issued',v_number||' has been issued for project '||v_rfi.project_id::text,
         v_rfi.project_id,'certificates','certificate','success','certificate',v_cert.id
  from project_members pm
  where pm.project_id=v_rfi.project_id
    and pm.active
    and pm.user_id<>auth.uid();

  return v_cert;
end;
$$;

grant execute on function epas_issue_certificate(uuid,text,integer) to authenticated;

-- ------------------------------------------------------------
-- G. Interim -> Full requires a completed linked follow-up RFI
--    that has itself passed the GM approval + DM acknowledgement gate.
-- ------------------------------------------------------------
create or replace function epas_finalize_interim_certificate(
  p_certificate_id uuid,
  p_validity_months integer,
  p_note text
) returns certificates
language plpgsql
security definer
set search_path=public
as $$
declare
  v_old certificates;
  v_new certificates;
  v_followup rfis;
  v_project uuid;
  v_number text;
  v_open integer;
  v_followup_obs integer;
  v_followup_ack boolean;
begin
  if not epas_has_role('gm') then
    raise exception 'Only GM may finalize an Interim Certificate';
  end if;

  select * into v_old
  from certificates
  where id=p_certificate_id
  for update;

  if v_old.id is null then
    raise exception 'Certificate not found';
  end if;

  if v_old.cert_type<>'interim_certificate' or v_old.status<>'active' then
    raise exception 'Certificate is not an active Interim Certificate';
  end if;

  select count(*) into v_open
  from observations
  where rfi_id=v_old.rfi_id
    and status='open';

  if v_open>0 then
    raise exception 'All original survey observations must be verified closed before final certificate issuance';
  end if;

  -- There must be a follow-up RFI linked to the original.
  select r.*
  into v_followup
  from rfis r
  where r.follow_up_of_rfi_id=v_old.rfi_id
  order by r.requested_date desc, r.created_at desc
  limit 1
  for update;

  if v_followup.id is null then
    raise exception 'A verified Follow-up RFI is required before finalising the Interim Certificate';
  end if;

  if v_followup.status<>'approved_no_observations' then
    raise exception 'Follow-up RFI must be approved by GM with no open observations before final certificate issuance';
  end if;

  select count(*) into v_followup_obs
  from observations
  where rfi_id=v_followup.id
    and status='open';

  if v_followup_obs>0 then
    raise exception 'Follow-up RFI still contains open observations';
  end if;

  select exists(
    select 1
    from workflow_tasks
    where entity_type='rfi'
      and entity_id=v_followup.id
      and task_type='DM_GM_FINAL_APPROVAL_ACK'
      and status='completed'
  ) into v_followup_ack;

  if not v_followup_ack then
    raise exception 'DM final-approval acknowledgement is required for the Follow-up RFI';
  end if;

  v_project:=v_old.project_id;
  v_number:='CC-'||to_char(current_date,'YYYY')||'-'||
            upper(replace(coalesce((select rfi_code from rfis where id=v_followup.id),'RFI'),' ','-'))||
            '-FINAL';

  if exists(select 1 from certificates where cert_number=v_number) then
    v_number:=v_number||'-'||substr(gen_random_uuid()::text,1,6);
  end if;

  insert into certificates(
    vessel_id,project_id,rfi_id,cert_type,cert_number,issue_date,expiry_date,
    status,pending_observations,issued_by,parent_certificate_id
  )
  values(
    v_old.vessel_id,v_project,v_followup.id,'class_certificate',v_number,current_date,
    (current_date+make_interval(months=>p_validity_months))::date,'active',
    '[]'::jsonb,auth.uid(),v_old.id
  )
  returning * into v_new;

  update certificates
  set status='superseded',
      superseded_by=v_new.id,
      finalized_at=now(),
      finalization_note=p_note
  where id=v_old.id;

  insert into certificate_lifecycle_events(
    certificate_id,event_type,from_status,to_status,actor_id,note
  )
  values
    (v_old.id,'FINALIZED','active','superseded',auth.uid(),p_note),
    (v_new.id,'ISSUED_FROM_INTERIM','none','active',auth.uid(),p_note);

  perform epas_audit(
    v_project,'INTERIM_FINALIZED','certificate',v_old.id,
    'active','superseded',p_note,
    jsonb_build_object('final_certificate_id',v_new.id,'follow_up_rfi_id',v_followup.id)
  );

  insert into notifications(user_id,title,body,project_id,link_page,notification_type,severity,entity_type,entity_id)
  select pm.user_id,'Final Class Certificate issued',
         v_new.cert_number||' replaces Interim Certificate '||v_old.cert_number,
         v_project,'certificates','certificate','success','certificate',v_new.id
  from project_members pm
  where pm.project_id=v_project
    and pm.active
    and pm.user_id<>auth.uid();

  return v_new;
end;
$$;

grant execute on function epas_finalize_interim_certificate(uuid,integer,text) to authenticated;

commit;
