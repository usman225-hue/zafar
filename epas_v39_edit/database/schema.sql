-- =============================================================================
-- EPAS — Supabase / PostgreSQL Schema
-- Generated to match the GM workflow chart 1:1 — every table maps to a node
-- or decision box; every status column's CHECK constraint mirrors an enum in
-- config/settings.py so the frontend and database can never drift apart.
-- =============================================================================

create extension if not exists "uuid-ossp";

-- -----------------------------------------------------------------------------
-- PROFILES  (mirrors auth.users; role drives dashboard routing app-wide)
-- -----------------------------------------------------------------------------
create table if not exists profiles (
    id              uuid primary key references auth.users (id) on delete cascade,
    full_name       text not null,
    email           text not null unique,
    role            text not null check (role in
                        ('gm','dm','engineer','surveyor','designer',
                         'owner','ship_management','shipyard')),
    company_name    text,
    avatar_url      text,
    created_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- PROJECTS  (created via the 5-step wizard on the GM dashboard)
-- -----------------------------------------------------------------------------
create table if not exists projects (
    id              uuid primary key default uuid_generate_v4(),
    project_code    text not null unique,               -- e.g. "Y-2996"
    name            text not null,
    vessel_type     text not null,
    flag_state      text not null,
    phases          text[] not null default '{}',        -- subset of plan_appraisal / nsc_survey / in_service
    status          text not null default 'active'
                        check (status in ('active','on_hold','closed')),
    created_by      uuid references profiles (id),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- VESSELS  (Step 2 particulars; one vessel per project in this schema)
-- -----------------------------------------------------------------------------
create table if not exists vessels (
    id              uuid primary key default uuid_generate_v4(),
    project_id      uuid not null references projects (id) on delete cascade,
    name            text not null,
    imo_number      text,
    flag_state      text not null,
    loa_m           numeric(8,2),                         -- length overall
    beam_m          numeric(8,2),
    draft_m         numeric(8,2),
    power_kw        numeric(10,2),
    speed_knots     numeric(6,2),
    build_year      int,
    owner_company   text,
    current_class   text,
    created_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- TEAM ASSIGNMENTS  (Step 4 — internal team: DM / Engineer / Surveyor)
-- -----------------------------------------------------------------------------
create table if not exists team_assignments (
    id              uuid primary key default uuid_generate_v4(),
    project_id      uuid not null references projects (id) on delete cascade,
    user_id         uuid references profiles (id),
    role            text not null check (role in ('dm','engineer','surveyor')),
    discipline      text,                                  -- e.g. "Hull & Structure"
    assigned_at     timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- STAKEHOLDERS  (Step 5 — external: Owner / Designer / Ship Mgmt / Shipyard)
-- -----------------------------------------------------------------------------
create table if not exists stakeholders (
    id              uuid primary key default uuid_generate_v4(),
    project_id      uuid not null references projects (id) on delete cascade,
    company_name    text not null,
    contact_name    text,
    contact_email   text,
    stakeholder_type text not null check (stakeholder_type in
                        ('owner','designer','ship_management','shipyard')),
    added_at        timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- DOCUMENTS  (Step 3 uploads + drawing submissions; Document Detail Panel)
-- -----------------------------------------------------------------------------
create table if not exists documents (
    id              uuid primary key default uuid_generate_v4(),
    project_id      uuid not null references projects (id) on delete cascade,
    category        text not null check (category in
                        ('contract','class_rules','timeline','drawing')),
    file_name       text not null,
    version         int not null default 1,
    status          text not null default 'pending_review'
                        check (status in
                            ('pending_review','approved','amendments_required','rejected')),
    storage_path    text,                                  -- Supabase Storage key
    uploaded_by     uuid references profiles (id),
    uploaded_at     timestamptz not null default now()
);

create table if not exists document_remarks (
    id              uuid primary key default uuid_generate_v4(),
    document_id     uuid not null references documents (id) on delete cascade,
    author_id       uuid references profiles (id),
    body            text not null,
    created_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- RFIs — the spine of the flowchart:
--   pending_allocation → allocated_to_dm → survey_in_progress →
--   observations_logged → pending_gm_approval → (sent_back_for_rework |
--   approved_no_observations | approved_with_observations) → certificate_issued
-- -----------------------------------------------------------------------------
create table if not exists rfis (
    id              uuid primary key default uuid_generate_v4(),
    project_id      uuid not null references projects (id) on delete cascade,
    vessel_id       uuid not null references vessels (id) on delete cascade,
    phase           text not null check (phase in ('nsc_survey','in_service')),
    survey_type     text not null,                          -- e.g. "Annual Survey", "HATS"
    rfi_code        text not null unique,                    -- e.g. "RFI-2027-014"
    status          text not null default 'pending_allocation' check (status in (
                        'pending_allocation','allocated_to_dm','survey_in_progress',
                        'observations_logged','pending_gm_approval','sent_back_for_rework',
                        'approved_no_observations','approved_with_observations',
                        'certificate_issued','closed'
                    )),
    requested_by    uuid references profiles (id),           -- shipyard / ship mgmt contact
    assigned_dm_id  uuid references profiles (id),
    assigned_surveyor_id uuid references profiles (id),
    requested_date  date not null default current_date,
    scheduled_date  date,
    priority        text not null default 'medium' check (priority in ('low','medium','high')),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- OBSERVATIONS  (logged during survey execution; gate certificate type)
-- -----------------------------------------------------------------------------
create table if not exists observations (
    id              uuid primary key default uuid_generate_v4(),
    rfi_id          uuid not null references rfis (id) on delete cascade,
    obs_code        text not null,                           -- e.g. "OBS-014-01"
    description     text not null,
    severity        text not null default 'Minor' check (severity in ('Minor','Major','Critical')),
    status          text not null default 'open' check (status in ('open','cleared')),
    raised_by       uuid references profiles (id),
    raised_at       timestamptz not null default now(),
    cleared_at      timestamptz
);

-- -----------------------------------------------------------------------------
-- GM APPROVAL DECISIONS  (audit trail of every Send Back / Approve decision)
-- -----------------------------------------------------------------------------
create table if not exists gm_decisions (
    id              uuid primary key default uuid_generate_v4(),
    rfi_id          uuid not null references rfis (id) on delete cascade,
    decided_by      uuid references profiles (id),
    decision        text not null check (decision in ('sent_back','approved')),
    note            text,
    decided_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- CERTIFICATES
-- -----------------------------------------------------------------------------
create table if not exists certificates (
    id                  uuid primary key default uuid_generate_v4(),
    vessel_id           uuid not null references vessels (id) on delete cascade,
    project_id          uuid not null references projects (id) on delete cascade,
    rfi_id              uuid references rfis (id),
    cert_type           text not null check (cert_type in
                            ('class_certificate','interim_certificate','nsc_certificate')),
    cert_number         text not null unique,                 -- e.g. "CC-2027-014-Y2996"
    issue_date          date not null default current_date,
    expiry_date         date not null,
    status              text not null default 'active'
                            check (status in ('active','expired','superseded')),
    pending_observations jsonb default '[]'::jsonb,            -- snapshot at issue time
    issued_by           uuid references profiles (id),
    pdf_storage_path    text,
    created_at          timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- AUDIT LOG  (Survey Logs & Reports → Audit Trail)
-- -----------------------------------------------------------------------------
create table if not exists audit_log (
    id              uuid primary key default uuid_generate_v4(),
    project_id      uuid references projects (id) on delete cascade,
    actor_id        uuid references profiles (id),
    action          text not null,                            -- e.g. "RFI_ASSIGNED"
    details         jsonb default '{}'::jsonb,
    created_at      timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- CONVENIENCE VIEW — Global Ship Register
-- (Vessel Bio + latest certificate + auto-calculated next due date)
-- -----------------------------------------------------------------------------
create or replace view ship_register as
select
    v.id                as vessel_id,
    v.name              as vessel_name,
    v.imo_number,
    v.flag_state,
    v.current_class,
    v.owner_company,
    c.cert_number        as latest_cert_number,
    c.cert_type          as latest_cert_type,
    c.issue_date          as latest_cert_issue_date,
    c.expiry_date         as next_due_date,
    (c.expiry_date - current_date) as days_until_due,
    c.status              as latest_cert_status
from vessels v
left join lateral (
    select * from certificates
    where certificates.vessel_id = v.id
    order by issue_date desc
    limit 1
) c on true;

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
create index if not exists idx_rfis_project on rfis (project_id);
create index if not exists idx_rfis_status on rfis (status);
create index if not exists idx_observations_rfi on observations (rfi_id);
create index if not exists idx_certificates_vessel on certificates (vessel_id);
create index if not exists idx_documents_project on documents (project_id);
create index if not exists idx_audit_project on audit_log (project_id);

-- -----------------------------------------------------------------------------
-- ROW LEVEL SECURITY (scaffolding — tighten per-role before production)
-- -----------------------------------------------------------------------------
alter table projects enable row level security;
alter table rfis enable row level security;
alter table certificates enable row level security;
alter table vessels enable row level security;

-- Example: GM sees everything. Replace with your real auth.uid() -> profiles.role
-- lookup once auth is wired up.
create policy "gm_full_access_projects" on projects
    for all using (
        exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'gm')
    );

create policy "gm_full_access_rfis" on rfis
    for all using (
        exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'gm')
    );

create policy "gm_full_access_certificates" on certificates
    for all using (
        exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'gm')
    );

create policy "gm_full_access_vessels" on vessels
    for all using (
        exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'gm')
    );
