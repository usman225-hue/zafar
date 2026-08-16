-- EPAS v1.4.1 - External Stakeholder Security & Role Classification
-- Apply AFTER production_v1_4.sql.
--
-- External roles:
--   owner, shipyard       = read-only stakeholder accounts
--   designer              = stakeholder + controlled drawing submission/revision
--   ship_management       = stakeholder + controlled corrective-action execution
--
-- They are NOT internal classification personnel and must not receive the
-- internal project-wide visibility implied by a generic project-member policy.

alter table project_members
  add column if not exists member_category text;

update project_members
set member_category = case
  when role in ('owner','designer','ship_management','shipyard') then 'stakeholder'
  else 'internal'
end
where member_category is null;

alter table project_members
  drop constraint if exists project_members_member_category_check;

alter table project_members
  add constraint project_members_member_category_check
  check (member_category in ('internal','stakeholder'));

create index if not exists idx_project_members_category
  on project_members(project_id, member_category, active);

-- Stakeholder-visible document flag. Existing documents default to internal.
alter table documents
  add column if not exists stakeholder_visible boolean not null default false;

alter table documents
  add column if not exists release_status text not null default 'internal'
  check (release_status in ('internal','stakeholder_review','released','withdrawn'));

create index if not exists idx_documents_stakeholder_release
  on documents(project_id, stakeholder_visible, release_status);

-- Rebuild stakeholder read policy so external users do not see internal
-- appraisal material merely because they belong to the project.
drop policy if exists documents_select_v14 on documents;
create policy documents_select_v14 on documents
for select to authenticated
using (
  epas_is_project_member(project_id)
  and (
    not exists (
      select 1 from profiles p
      where p.id = auth.uid()
        and p.role in ('owner','shipyard','designer','ship_management')
    )
    or (stakeholder_visible = true and release_status = 'released')
    or exists (
      select 1 from project_members pm
      where pm.project_id = documents.project_id
        and pm.user_id = auth.uid()
        and pm.active = true
        and pm.role in ('designer','ship_management')
        and documents.stakeholder_visible = true
    )
  )
);

-- Stakeholder users may only see their own project membership row plus
-- non-confidential stakeholder identities. Internal members remain hidden
-- from external stakeholders.
drop policy if exists project_members_select_v14 on project_members;
create policy project_members_select_v14 on project_members
for select to authenticated
using (
  user_id = auth.uid()
  or (
    epas_has_role('gm')
    or (
      epas_has_role('dm')
      and epas_is_project_member(project_id)
    )
    or (
      exists (
        select 1 from profiles p
        where p.id = auth.uid()
          and p.role in ('designer','ship_management','owner','shipyard')
      )
      and member_category = 'stakeholder'
      and epas_is_project_member(project_id)
    )
  )
);

-- Stakeholders may not create/update/delete project membership, documents,
-- workflow tasks, observations, or notifications directly. The v1.4 RPC-only
-- lockdown remains authoritative.
revoke insert, update, delete on project_members from anon, authenticated;
revoke insert, update, delete on documents from anon, authenticated;

-- Explicitly document the intended role boundary.
create or replace function epas_is_external_stakeholder(p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists (
    select 1 from profiles
    where id = p_user_id
      and role in ('owner','designer','ship_management','shipyard')
  );
$$;

create or replace function epas_stakeholder_can_execute(p_user_id uuid, p_project_id uuid, p_task_type text)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists (
    select 1
    from project_members pm
    join profiles p on p.id = pm.user_id
    where pm.project_id = p_project_id
      and pm.user_id = p_user_id
      and pm.active = true
      and (
        (p.role = 'designer' and p_task_type in ('PLAN_APPRAISAL_DESIGNER_RESPONSE','PLAN_APPRAISAL_INITIAL_DRAWING_SUBMISSION'))
        or
        (p.role = 'ship_management' and p_task_type = 'CORRECTIVE_ACTION_EXECUTION')
      )
  );
$$;

comment on function epas_stakeholder_can_execute is
'External stakeholder task boundary: Designer may execute controlled drawing submission/revision; Ship Management may execute assigned corrective action; Owner and Shipyard are read-only.';
