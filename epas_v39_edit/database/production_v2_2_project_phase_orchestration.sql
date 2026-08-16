-- EPAS v2.2 — Project Phase Orchestration, Ship Register & Survey Status
-- Cumulative migration after v2.1.
-- Business rule: a project executes only the phases selected at creation.
-- Execution order is Plan Appraisal -> NSC -> In-Service where those phases exist.
-- If a preceding phase is not selected, the next selected phase may start.

alter table projects add column if not exists current_phase text;
alter table projects add column if not exists current_phase_status text;
alter table projects add column if not exists phase_started_at timestamptz;
alter table projects add column if not exists phase_completed_at timestamptz;

alter table vessels add column if not exists survey_status text not null default 'NOT_STARTED';
alter table vessels add column if not exists survey_status_updated_at timestamptz;
alter table vessels add column if not exists next_survey_due date;
alter table vessels add column if not exists last_survey_date date;
alter table vessels add column if not exists last_survey_phase text;
alter table vessels add column if not exists class_status text not null default 'PENDING_CLASSIFICATION';

create table if not exists project_phase_control (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  phase text not null check (phase in ('plan_appraisal','nsc_survey','in_service')),
  sequence_no integer not null,
  status text not null default 'NOT_APPLICABLE' check (status in ('NOT_APPLICABLE','LOCKED','READY','IN_PROGRESS','COMPLETED','BLOCKED')),
  gate_passed boolean not null default false,
  gate_note text,
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(project_id,phase)
);
create index if not exists idx_phase_control_project on project_phase_control(project_id,sequence_no);

create table if not exists vessel_survey_status_history (
  id uuid primary key default gen_random_uuid(),
  vessel_id uuid not null references vessels(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  status text not null,
  phase text,
  source_type text,
  source_id uuid,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists idx_vessel_survey_status_history_vessel on vessel_survey_status_history(vessel_id,created_at desc);

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
  v_in_ready boolean := true;
begin
  select phases into v_phases from projects where id=p_project_id;
  if v_phases is null then raise exception 'Project not found'; end if;

  select count(*), count(*) filter(where d.status='approved')
    into v_plan_drawings,v_plan_approved
  from plan_drawings d where d.project_id=p_project_id;
  select count(*) into v_plan_open_obs
  from plan_appraisal_observations o join plan_drawings d on d.id=o.drawing_id
  where d.project_id=p_project_id and o.status='open';
  v_plan_ready := (v_plan_drawings > 0 and v_plan_drawings=v_plan_approved and v_plan_open_obs=0);

  select count(*), count(*) filter(where r.status in ('certificate_issued','closed'))
    into v_nsc_total,v_nsc_done
  from rfis r where r.project_id=p_project_id and r.phase='nsc_survey' and coalesce(r.follow_up_type,'') not in ('IN_SERVICE_OBSERVATION_CLEARANCE','CHANGE_OF_CLASS_FOLLOW_UP');
  select count(*) into v_nsc_open_obs from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id and r.phase='nsc_survey' and o.status='open';
  v_nsc_ready := (v_nsc_total > 0 and v_nsc_total=v_nsc_done and v_nsc_open_obs=0);

  select count(*), count(*) filter(where r.status in ('certificate_issued','closed'))
    into v_in_total,v_in_done
  from rfis r where r.project_id=p_project_id and r.phase='in_service';
  select count(*) into v_in_open_obs from observations o join rfis r on r.id=o.rfi_id where r.project_id=p_project_id and r.phase='in_service' and o.status='open';
  v_in_ready := (v_in_total > 0 and v_in_total=v_in_done and v_in_open_obs=0);

  if p_phase='plan_appraisal' then
    if not ('plan_appraisal'=any(v_phases)) then return query select 'NOT_APPLICABLE',false,'Plan Appraisal is not part of this project'; return; end if;
    if v_plan_ready then return query select 'COMPLETED',true,'All plan appraisal drawings are approved and no open plan observations remain';
    else return query select 'IN_PROGRESS',false,format('Approved drawings %s/%s; open observations: %s',v_plan_approved,v_plan_drawings,v_plan_open_obs); end if;
  elsif p_phase='nsc_survey' then
    if not ('nsc_survey'=any(v_phases)) then return query select 'NOT_APPLICABLE',false,'NSC Survey is not part of this project'; return; end if;
    if 'plan_appraisal'=any(v_phases) and not v_plan_ready then return query select 'LOCKED',false,'NSC is locked until Plan Appraisal is complete'; return; end if;
    if v_nsc_ready then return query select 'COMPLETED',true,'NSC survey cycle is closed with no open observations';
    elsif v_nsc_total=0 then return query select 'READY',true,'NSC phase is eligible to start; waiting for Shipyard NSC RFI';
    else return query select 'IN_PROGRESS',false,format('NSC RFIs completed %s/%s; open observations: %s',v_nsc_done,v_nsc_total,v_nsc_open_obs); end if;
  elsif p_phase='in_service' then
    if not ('in_service'=any(v_phases)) then return query select 'NOT_APPLICABLE',false,'In-Service is not part of this project'; return; end if;
    if 'nsc_survey'=any(v_phases) and not v_nsc_ready then return query select 'LOCKED',false,'In-Service is locked until the NSC phase is closed'; return; end if;
    if not ('nsc_survey'=any(v_phases)) and 'plan_appraisal'=any(v_phases) and not v_plan_ready then return query select 'LOCKED',false,'In-Service is locked until Plan Appraisal is complete'; return; end if;
    if v_in_ready then return query select 'COMPLETED',true,'Current In-Service survey cycle is closed with no open observations';
    elsif v_in_total=0 then return query select 'READY',true,'In-Service phase is eligible to start; waiting for Owner / Ship Management RFI';
    else return query select 'IN_PROGRESS',false,format('In-Service RFIs completed %s/%s; open observations: %s',v_in_done,v_in_total,v_in_open_obs); end if;
  else raise exception 'Invalid phase'; end if;
end;$$;

create or replace function epas_refresh_project_phase_state(p_project_id uuid)
returns setof project_phase_control
language plpgsql security definer set search_path=public as $$
declare
  p text; s text; g boolean; n text; phases text[]; seq integer; prev_phase text; prev_status text;
  old_started timestamptz; old_completed timestamptz;
begin
  select phases into phases from projects where id=p_project_id;
  if phases is null then raise exception 'Project not found'; end if;
  foreach p in array array['plan_appraisal','nsc_survey','in_service'] loop
    seq:=case p when 'plan_appraisal' then 1 when 'nsc_survey' then 2 else 3 end;
    if not (p=any(phases)) then
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note)
      values(p_project_id,p,seq,'NOT_APPLICABLE',false,p||' not selected')
      on conflict(project_id,phase) do update set sequence_no=excluded.sequence_no,status='NOT_APPLICABLE',gate_passed=false,gate_note=excluded.gate_note,updated_at=now();
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
      end if;
      select started_at,completed_at into old_started,old_completed from project_phase_control where project_id=p_project_id and phase=p;
      insert into project_phase_control(project_id,phase,sequence_no,status,gate_passed,gate_note,started_at,completed_at)
      values(p_project_id,p,seq,s,g,n,case when s in ('IN_PROGRESS','COMPLETED') then coalesce(old_started,now()) end,case when s='COMPLETED' then coalesce(old_completed,now()) end)
      on conflict(project_id,phase) do update set
        sequence_no=excluded.sequence_no,status=excluded.status,gate_passed=excluded.gate_passed,gate_note=excluded.gate_note,
        started_at=excluded.started_at,completed_at=excluded.completed_at,updated_at=now();
    end if;
  end loop;
  update projects p set
    current_phase=(select pc.phase from project_phase_control pc where pc.project_id=p_project_id and pc.status in ('IN_PROGRESS','READY') order by pc.sequence_no limit 1),
    current_phase_status=(select pc.status from project_phase_control pc where pc.project_id=p_project_id and pc.status in ('IN_PROGRESS','READY') order by pc.sequence_no limit 1),
    updated_at=now()
  where p.id=p_project_id;
  return query select * from project_phase_control where project_id=p_project_id order by sequence_no;
end;$$;

create or replace function epas_refresh_vessel_survey_status(p_vessel_id uuid)
returns vessels
language plpgsql security definer set search_path=public as $$
declare
  v vessels;
  p projects;
  s text := 'NOT_STARTED';
  ph text := null;
  source_id uuid := null;
  note text := null;
  next_due date := null;
  last_date date := null;
  last_phase text := null;
  has_nsc boolean := false;
  nsc_active boolean := false;
  nsc_done boolean := false;
  has_in boolean := false;
  in_active boolean := false;
  in_done boolean := false;
  open_obs integer := 0;
begin
  select * into v from vessels where id=p_vessel_id for update;
  if v.id is null then raise exception 'Vessel not found'; end if;
  select * into p from projects where id=v.project_id;
  has_nsc := 'nsc_survey'=any(p.phases); has_in := 'in_service'=any(p.phases);
  select exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey'),
         exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey' and r.status not in ('certificate_issued','closed')),
         exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='nsc_survey' and r.status in ('certificate_issued','closed'))
    into has_nsc,nsc_active,nsc_done;
  select exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='in_service'),
         exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='in_service' and r.status not in ('certificate_issued','closed')),
         exists(select 1 from rfis r where r.vessel_id=v.id and r.phase='in_service' and r.status in ('certificate_issued','closed'))
    into has_in,in_active,in_done;
  select count(*) into open_obs from observations o join rfis r on r.id=o.rfi_id where r.vessel_id=v.id and o.status='open';
  select max(c.expiry_date) into next_due from certificates c where c.vessel_id=v.id and c.status in ('active','expiring');
  select max(coalesce(r.scheduled_date,r.requested_date)), (array_agg(r.phase order by coalesce(r.scheduled_date,r.requested_date) desc))[1]
    into last_date,last_phase from rfis r where r.vessel_id=v.id and r.status in ('certificate_issued','closed');

  if p.status='closed' then s:='PROJECT_CLOSED'; note:='Project closed';
  elsif has_in and in_active then s:='IN_SERVICE_IN_PROGRESS'; ph:='in_service'; note:='In-Service survey cycle active';
  elsif has_in and in_done and open_obs>0 then s:='OBSERVATIONS_OPEN'; ph:='in_service'; note:='Open In-Service observations require action';
  elsif has_in and in_done then s:='IN_SERVICE_COMPLETE'; ph:='in_service'; note:='Latest In-Service cycle completed';
  elsif has_in and not in_done then s:='IN_SERVICE_DUE'; ph:='in_service'; note:='In-Service survey is due / awaiting RFI';
  elsif has_nsc and nsc_active then s:='NSC_IN_PROGRESS'; ph:='nsc_survey'; note:='NSC survey cycle active';
  elsif has_nsc and nsc_done then s:='CLASS_ACTIVE'; ph:='nsc_survey'; note:='NSC completed; vessel class active';
  elsif 'plan_appraisal'=any(p.phases) then s:='PLAN_APPRAISAL'; ph:='plan_appraisal'; note:='Plan Appraisal phase active';
  end if;

  update vessels set survey_status=s,survey_status_updated_at=now(),next_survey_due=next_due,last_survey_date=last_date,last_survey_phase=last_phase,class_status=case when nsc_done or exists(select 1 from certificates c where c.vessel_id=v.id and c.status in ('active','expiring')) then 'CLASS_ACTIVE' else class_status end where id=v.id returning * into v;
  if v.survey_status is distinct from s then
    insert into vessel_survey_status_history(vessel_id,project_id,status,phase,source_type,source_id,note) values(v.id,v.project_id,s,ph,'SYSTEM',source_id,note);
  end if;
  return v;
end;$$;

create or replace function epas_refresh_project_and_vessel_state(p_project_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_vessel_id uuid;
begin
  perform epas_refresh_project_phase_state(p_project_id);
  select id into v_vessel_id from vessels where project_id=p_project_id limit 1;
  if v_vessel_id is not null then perform epas_refresh_vessel_survey_status(v_vessel_id); end if;
end;$$;

-- Trigger refresh after survey/certificate changes. The trigger is deliberately
-- lightweight and only recalculates the affected project's state.
create or replace function epas_state_refresh_trigger() returns trigger
language plpgsql security definer set search_path=public as $$
declare pid uuid; vid uuid;
begin
  if tg_table_name='rfis' then
    pid:=coalesce(new.project_id,old.project_id);
    vid:=coalesce(new.vessel_id,old.vessel_id);
  elsif tg_table_name='certificates' then
    pid:=coalesce(new.project_id,old.project_id);
    vid:=coalesce(new.vessel_id,old.vessel_id);
  elsif tg_table_name='observations' then
    select r.vessel_id,r.project_id into vid,pid from rfis r where r.id=coalesce(new.rfi_id,old.rfi_id);
  elsif tg_table_name='plan_drawings' then
    pid:=coalesce(new.project_id,old.project_id);
  elsif tg_table_name='plan_appraisal_observations' then
    select d.project_id into pid from plan_drawings d where d.id=coalesce(new.drawing_id,old.drawing_id);
  end if;
  if pid is not null then perform epas_refresh_project_phase_state(pid); end if;
  if vid is not null then perform epas_refresh_vessel_survey_status(vid); end if;
  return coalesce(new,old);
end;$$;

drop trigger if exists trg_epas_state_refresh_rfis on rfis;
create trigger trg_epas_state_refresh_rfis after insert or update of status,scheduled_date on rfis for each row execute function epas_state_refresh_trigger();
drop trigger if exists trg_epas_state_refresh_observations on observations;
create trigger trg_epas_state_refresh_observations after insert or update of status on observations for each row execute function epas_state_refresh_trigger();
drop trigger if exists trg_epas_state_refresh_certificates on certificates;
create trigger trg_epas_state_refresh_certificates after insert or update of status,expiry_date on certificates for each row execute function epas_state_refresh_trigger();
drop trigger if exists trg_epas_state_refresh_plan_drawings on plan_drawings;
create trigger trg_epas_state_refresh_plan_drawings after insert or update of status on plan_drawings for each row execute function epas_state_refresh_trigger();
drop trigger if exists trg_epas_state_refresh_plan_observations on plan_appraisal_observations;
create trigger trg_epas_state_refresh_plan_observations after insert or update of status on plan_appraisal_observations for each row execute function epas_state_refresh_trigger();

create or replace view epas_ship_register as
select v.id as vessel_id,v.project_id,v.name,v.imo_number,v.flag_state,v.owner_company,v.current_class,
       v.class_status,v.survey_status,v.next_survey_due,v.last_survey_date,v.last_survey_phase,
       p.project_code,p.name as project_name,p.phases,p.current_phase,p.current_phase_status,
       (select c.cert_number from certificates c where c.vessel_id=v.id and c.status in ('active','expiring') order by c.expiry_date desc limit 1) as latest_certificate,
       (select c.cert_type from certificates c where c.vessel_id=v.id and c.status in ('active','expiring') order by c.expiry_date desc limit 1) as latest_certificate_type
from vessels v join projects p on p.id=v.project_id;

create or replace function epas_project_phase_status(p_project_id uuid)
returns setof project_phase_control language sql security definer set search_path=public stable as $$
  select * from project_phase_control where project_id=p_project_id order by sequence_no;
$$;

-- Initial synchronization for existing projects.
do $$ declare x record; begin for x in select id from projects loop perform epas_refresh_project_phase_state(x.id); perform epas_refresh_vessel_survey_status(v.id) from vessels v where v.project_id=x.id; end loop; end $$;

revoke all on function epas_phase_gate_status(uuid,text) from public;
revoke all on function epas_refresh_project_phase_state(uuid) from public;
revoke all on function epas_refresh_vessel_survey_status(uuid) from public;
revoke all on function epas_refresh_project_and_vessel_state(uuid) from public;
grant execute on function epas_phase_gate_status(uuid,text) to authenticated;
grant execute on function epas_project_phase_status(uuid) to authenticated;

-- Phase gate is also enforced at stakeholder RFI creation: UI visibility is
-- never the authorization boundary.
create or replace function epas_stakeholder_create_rfi(
  p_project_id uuid,p_vessel_id uuid,p_phase text,p_survey_type text,p_requested_date date,p_priority text,p_scope_note text
) returns rfis language plpgsql security definer set search_path=public as $$
declare v_role text; v_rfi rfis; v_gm uuid; v_code text; v_gate text;
begin
  select role into v_role from profiles where id=auth.uid();
  if v_role not in ('owner','ship_management','shipyard') then raise exception 'Stakeholder role not permitted'; end if;
  if v_role='shipyard' and p_phase<>'nsc_survey' then raise exception 'Shipyard may initiate NSC Survey RFIs only'; end if;
  if v_role in ('owner','ship_management') and p_phase<>'in_service' then raise exception 'Owner and Ship Management may initiate In-Service Survey RFIs only'; end if;
  if p_phase not in ('nsc_survey','in_service') then raise exception 'Invalid survey phase'; end if;
  if not exists(select 1 from project_members where project_id=p_project_id and user_id=auth.uid() and active and role=v_role) then raise exception 'Not an active stakeholder member of this project'; end if;
  if not exists(select 1 from vessels where id=p_vessel_id and project_id=p_project_id) then raise exception 'Vessel does not belong to project'; end if;
  select status into v_gate from epas_phase_gate_status(p_project_id,p_phase) limit 1;
  if p_phase='nsc_survey' and v_gate<>'READY' then raise exception 'NSC Survey cannot start in phase state %; complete the prerequisite phase or current NSC cycle first',v_gate; end if;
  if p_phase='in_service' and v_gate not in ('READY','COMPLETED') then raise exception 'In-Service Survey is not currently eligible; phase state is %',v_gate; end if;
  v_code:='RFI-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into rfis(project_id,vessel_id,phase,survey_type,rfi_code,status,requested_by,requested_date,priority,scope_note,requester_role)
  values(p_project_id,p_vessel_id,p_phase,p_survey_type,v_code,'pending_allocation',auth.uid(),coalesce(p_requested_date,current_date),p_priority,p_scope_note,v_role) returning * into v_rfi;
  insert into survey_checklist_items(rfi_id,item_code,category,requirement,mandatory) values
    (v_rfi.id,'ACCESS_001','Access','Vessel/site access and survey attendance confirmed',true),
    (v_rfi.id,'DOC_001','Documents','Approved/current drawings and applicable documents available',true),
    (v_rfi.id,'DOC_002','Documents','Previous survey reports reviewed',case when p_phase='in_service' then true else false end),
    (v_rfi.id,'DOC_003','Documents','Maintenance/repair records reviewed',case when p_phase='in_service' then true else false end),
    (v_rfi.id,'CLASS_001','Class','Current class/certificate status reviewed',true),
    (v_rfi.id,'SAFETY_001','Safety','Required safety arrangements confirmed',true),
    (v_rfi.id,'SCOPE_001','Scope','Survey scope and requested survey type confirmed',true),
    (v_rfi.id,'CHANGE_001','Change of Class','Change-of-class requirement assessed',case when p_phase='in_service' then true else false end);
  select id into v_gm from profiles where role='gm' order by created_at limit 1;
  if v_gm is not null then perform epas_create_task(v_rfi.project_id,'GM_SURVEY_RFI_INTAKE',v_gm,'Stakeholder RFI submitted: '||v_code,'rfi',v_rfi.id,null,p_priority); end if;
  perform epas_audit(v_rfi.project_id,'STAKEHOLDER_RFI_CREATED','rfi',v_rfi.id,null,'pending_allocation',p_scope_note,jsonb_build_object('requester_role',v_role,'survey_phase',p_phase,'phase_gate',v_gate));
  return v_rfi;
end;$$;
grant execute on function epas_stakeholder_create_rfi(uuid,uuid,text,text,date,text,text) to authenticated;
