-- EPAS Multi-user Upgrade Schema
-- Run AFTER database/schema.sql.
-- Designed for Supabase/PostgreSQL.

create extension if not exists pgcrypto;

create table if not exists authorization_matrix (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  discipline text not null,
  authorization_level text not null,
  active boolean not null default true,
  valid_until date not null,
  created_at timestamptz not null default now(),
  unique(user_id, discipline)
);

create table if not exists competency_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  discipline text not null,
  status text not null check (status in ('competent','restricted','expired','suspended')),
  valid_until date not null,
  last_assessed date,
  assessor_id uuid references profiles(id),
  remarks text,
  created_at timestamptz not null default now(),
  unique(user_id, discipline)
);

create table if not exists resource_availability (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  work_date date not null,
  status text not null check (status in ('available','busy','leave','unavailable')),
  workload_pct numeric(5,2) not null default 0 check (workload_pct between 0 and 100),
  notes text,
  unique(user_id, work_date)
);

create table if not exists document_revisions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id) on delete cascade,
  revision integer not null,
  file_name text not null,
  storage_path text,
  status text not null default 'pending_review',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique(document_id, revision)
);

create table if not exists plan_drawings (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  document_id uuid not null references documents(id) on delete restrict,
  drawing_no text not null,
  title text not null,
  discipline text not null,
  revision integer not null default 1,
  status text not null default 'submitted',
  manager_id uuid references profiles(id),
  engineer_id uuid references profiles(id),
  designer_id uuid references profiles(id),
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  current_file_name text
);

create table if not exists plan_appraisal_observations (
  id uuid primary key default gen_random_uuid(),
  drawing_id uuid not null references plan_drawings(id) on delete cascade,
  obs_code text not null unique,
  description text not null,
  severity text not null check (severity in ('Minor','Major','Critical')),
  status text not null default 'open' check (status in ('open','cleared','rejected')),
  raised_by uuid references profiles(id),
  raised_at timestamptz not null default now(),
  response text,
  responded_at timestamptz
);

create table if not exists plan_appraisal_events (
  id uuid primary key default gen_random_uuid(),
  drawing_id uuid not null references plan_drawings(id) on delete cascade,
  event_type text not null,
  actor_id uuid references profiles(id),
  note text,
  created_at timestamptz not null default now()
);

create table if not exists workflow_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  task_type text not null,
  from_user_id uuid references profiles(id),
  to_user_id uuid not null references profiles(id),
  rfi_id uuid references rfis(id) on delete cascade,
  drawing_id uuid references plan_drawings(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','in_progress','completed','returned')),
  note text,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  completed_at timestamptz
);

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  title text not null,
  body text not null,
  project_id uuid references projects(id) on delete cascade,
  link_page text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists idx_auth_user_disc on authorization_matrix(user_id, discipline);
create index if not exists idx_comp_user_disc on competency_records(user_id, discipline);
create index if not exists idx_avail_user_date on resource_availability(user_id, work_date);
create index if not exists idx_plan_drawings_project_status on plan_drawings(project_id, status);
create index if not exists idx_plan_obs_drawing on plan_appraisal_observations(drawing_id, status);
create index if not exists idx_tasks_to_user_status on workflow_tasks(to_user_id, status);
create index if not exists idx_notifications_user_read on notifications(user_id, read_at);

-- Enable RLS. Production policies should be tightened to project membership.
alter table authorization_matrix enable row level security;
alter table competency_records enable row level security;
alter table resource_availability enable row level security;
alter table document_revisions enable row level security;
alter table plan_drawings enable row level security;
alter table plan_appraisal_observations enable row level security;
alter table plan_appraisal_events enable row level security;
alter table workflow_tasks enable row level security;
alter table notifications enable row level security;

-- Basic authenticated policies. Replace/extend with organization-specific
-- project membership policies before production deployment.
do $$ begin
  create policy auth_read_authenticated on authorization_matrix for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy comp_read_authenticated on competency_records for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy availability_read_authenticated on resource_availability for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy revisions_project_users on document_revisions for select to authenticated using (
    exists (select 1 from documents d where d.id = document_revisions.document_id)
  );
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_drawings_authenticated on plan_drawings for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_obs_authenticated on plan_appraisal_observations for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_events_authenticated on plan_appraisal_events for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy tasks_own on workflow_tasks for select to authenticated using (to_user_id = auth.uid() or from_user_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy notifications_own on notifications for select to authenticated using (user_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy notifications_update_own on notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
exception when duplicate_object then null; end $$;

-- Write policies for workflow actions. These are intentionally explicit about
-- the acting user; refine role/project-membership predicates for production.
do $$ begin
  create policy tasks_insert_actor on workflow_tasks for insert to authenticated with check (from_user_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy tasks_update_recipient on workflow_tasks for update to authenticated using (to_user_id = auth.uid()) with check (to_user_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_drawings_write_assigned on plan_drawings for update to authenticated using (manager_id = auth.uid() or engineer_id = auth.uid() or designer_id = auth.uid()) with check (manager_id = auth.uid() or engineer_id = auth.uid() or designer_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_obs_insert_actor on plan_appraisal_observations for insert to authenticated with check (raised_by = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_obs_update_participants on plan_appraisal_observations for update to authenticated using (raised_by = auth.uid() or exists (select 1 from plan_drawings d where d.id = plan_appraisal_observations.drawing_id and (d.engineer_id = auth.uid() or d.designer_id = auth.uid()))) with check (raised_by = auth.uid() or exists (select 1 from plan_drawings d where d.id = plan_appraisal_observations.drawing_id and (d.engineer_id = auth.uid() or d.designer_id = auth.uid())));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy plan_events_insert_actor on plan_appraisal_events for insert to authenticated with check (actor_id = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy revisions_insert_actor on document_revisions for insert to authenticated with check (created_by = auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy notifications_insert_authenticated on notifications for insert to authenticated with check (true);
exception when duplicate_object then null; end $$;

comment on table authorization_matrix is 'Authorization by discipline; assignment engine requires active and non-expired authorization.';
comment on table competency_records is 'Competency evidence used with authorization and availability checks.';
comment on table resource_availability is 'Daily resource status/workload used by allocation engine.';
comment on table document_revisions is 'Immutable document revision history for plan appraisal and controlled documents.';
comment on table workflow_tasks is 'Real role-to-role handover; replaces demo-only stage advancement.';
comment on table notifications is 'In-app workflow notifications generated by state transitions.';

-- ---------------------------------------------------------------------------
-- Survey reports — DM review gate between survey execution and GM approval
-- ---------------------------------------------------------------------------
create table if not exists survey_reports (
  id uuid primary key default gen_random_uuid(),
  rfi_id uuid not null references rfis(id) on delete cascade,
  surveyor_id uuid references profiles(id),
  report_note text not null,
  submitted_at timestamptz not null default now()
);
create index if not exists idx_survey_reports_rfi on survey_reports(rfi_id, submitted_at desc);
alter table survey_reports enable row level security;
DO $$ BEGIN
  create policy survey_reports_participants on survey_reports for select to authenticated using (
    surveyor_id = auth.uid() or exists (
      select 1 from rfis r where r.id = survey_reports.rfi_id and (r.assigned_dm_id = auth.uid() or r.assigned_surveyor_id = auth.uid())
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  create policy survey_reports_insert_surveyor on survey_reports for insert to authenticated with check (surveyor_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
