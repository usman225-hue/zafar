# EPAS v1.4 Deployment Notes

## Supabase migration order

Run in Supabase SQL Editor:

```text
01 database/schema.sql
02 database/upgrade_schema.sql
03 database/production_schema.sql
04 database/production_v1_4.sql
```

The v1.4 file is a migration, not a replacement for the base schema.

## Environment

Configure Streamlit secrets:

```toml
SUPABASE_URL = "https://YOUR-PROJECT.supabase.co"
SUPABASE_ANON_KEY = "YOUR-ANON-KEY"
```

Do not put the Supabase service-role key in the browser application.

## Required user setup

Create Auth users and matching `profiles` records for:

- GM
- DM
- Engineer
- Surveyor
- Designer
- Ship Management

For each project, create active `project_members` records for every user who is allowed to receive work.

## Resource governance

Populate:

- `resource_authorizations`
- `resource_competencies`
- `resource_availability_calendar`

before assigning Engineers or Surveyors.

## Storage

The production schema creates the private `project-documents` bucket. Keep it private.

Controlled paths used by v1.4 include:

```text
projects/<project_id>/documents/<category>/<file>
projects/<project_id>/plan-appraisal/intake/<file>
projects/<project_id>/plan-appraisal/<drawing_id>/<file>
projects/<project_id>/corrective-actions/<action_id>/<file>
```

## Important

The migration intentionally removes direct browser write policies from critical workflow tables. Do not add broad `authenticated` INSERT/UPDATE/DELETE policies back to those tables. Extend the RPC layer instead.
