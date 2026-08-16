import uuid
import json
from pathlib import Path
import psycopg2

URL = "postgresql://postgres.ztqedstdufdnjdpixqls:P%40kistan9092909290@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres"


def main():
    conn = psycopg2.connect(URL)
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute('create extension if not exists "uuid-ossp";')
    schema_sql = Path('/workspaces/ERPPSB/EPAS_v3_6/database/schema.sql').read_text()
    statements = []
    buf = []
    for line in schema_sql.splitlines():
        if line.strip().startswith('--'):
            continue
        buf.append(line)
        if ';' in line:
            stmt = '\n'.join(buf).strip()
            if stmt:
                statements.append(stmt)
            buf = []
    for stmt in statements:
        try:
            cur.execute(stmt)
        except Exception as exc:
            msg = str(exc).lower()
            if any(tok in msg for tok in ['already exists', 'duplicate key', 'must be owner', 'permission denied']):
                continue
            raise

    # Auth users are already created; map their emails to ids.
    users = [
        ('gm@classification.com', 'Ahmed Al-Maktoum', 'gm', 'Classification Authority'),
        ('m.hassan@classification.com', 'Muhammad Hassan', 'dm', 'Classification Authority'),
        ('r.alfarsi@classification.com', 'Rania Al-Farsi', 'dm', 'Classification Authority'),
        ('park@classification.com', 'Capt. Park Min-jae', 'surveyor', 'Classification Authority'),
        ('khan@classification.com', 'Capt. Khan', 'surveyor', 'Classification Authority'),
        ('ali@classification.com', 'Eng. Ali Raza', 'surveyor', 'Classification Authority'),
        ('faruk@classification.com', 'Mehmet Faruk', 'engineer', 'Classification Authority'),
        ('designer@damen.com', 'Tayyab Qureshi', 'designer', 'Damen Shipyards'),
        ('shipyard@damen.com', 'Mohammed Ali', 'shipyard', 'Damen Shipyards'),
        ('shipmanagement@oceanic.co', 'John Smith', 'ship_management', 'Oceanic Ship Management'),
        ('owner@vesselholdings.com', 'Fatima Noor', 'owner', 'Vessel Holdings Ltd'),
    ]
    profile_ids = {}
    for email, name, role, company in users:
        cur.execute("select id from auth.users where email=%s", (email,))
        row = cur.fetchone()
        if not row:
            print('missing auth user', email)
            continue
        uid = row[0]
        profile_ids[email] = uid
        cur.execute("""
            insert into public.profiles (id, full_name, email, role, company_name, avatar_url, created_at)
            values (%s, %s, %s, %s, %s, %s, now())
            on conflict (email) do update set
                full_name = excluded.full_name,
                role = excluded.role,
                company_name = excluded.company_name,
                avatar_url = excluded.avatar_url
        """, (uid, name, email, role, company, None))

    # Clean the existing demo data for a known-good seed.
    for table in ['audit_log', 'documents', 'document_remarks', 'certificates', 'observations', 'gm_decisions', 'rfis', 'stakeholders', 'team_assignments', 'vessels', 'projects']:
        cur.execute(f'delete from public.{table} where true')

    project_rows = [
        ('Y-2996', 'KARACHI SB-293 Newbuild', 'Patrol Vessel', 'Pakistan', ['nsc_survey', 'in_service'], 'active', 'gm@classification.com'),
        ('C-5421', 'GULSHAN EXPRESS Change of Class', 'Container Feeder', 'Pakistan', ['in_service'], 'active', 'gm@classification.com'),
        ('M-7834', 'ABC CARGO Class Renewal', 'General Cargo', 'Panama', ['in_service'], 'active', 'gm@classification.com'),
        ('Z-1187', 'ZENITH TRADER Newbuild', 'Bulk Carrier', 'Marshall Islands', ['plan_appraisal', 'nsc_survey'], 'active', 'gm@classification.com'),
    ]
    project_ids = {}
    for code, name, vessel_type, flag_state, phases, status, gm_email in project_rows:
        pid = str(uuid.uuid4())
        project_ids[code] = pid
        cur.execute("""
            insert into public.projects (id, project_code, name, vessel_type, flag_state, phases, status, created_by, created_at, updated_at)
            values (%s, %s, %s, %s, %s, %s, %s, %s, now(), now())
        """, (pid, code, name, vessel_type, flag_state, phases, status, profile_ids[gm_email]))

    vessel_rows = [
        ('Y-2996', 'KARACHI SB-293 "GUN BOAT"', '—', 'Pakistan', 62.0, 9.2, 2.8, 4200, 28, 2026, 'Pakistan Maritime Security Agency', 'Classification Authority'),
        ('C-5421', 'GULSHAN EXPRESS', '9456781', 'Pakistan', 148.0, 23.4, 8.1, 9800, 19, 2014, 'Oceanic Ship Management', 'Classification Authority'),
        ('M-7834', 'ABC CARGO', '9312456', 'Panama', 189.0, 28.4, 10.9, 12400, 16, 2009, 'Vessel Holdings Ltd', 'ABS (transferred)'),
        ('Z-1187', 'ZENITH TRADER', '—', 'Marshall Islands', 225.0, 32.2, 13.5, 15200, 14, 2027, 'Zenith Bulk Holdings', 'Classification Authority (pending)'),
    ]
    vessel_ids = {}
    for code, name, imo, flag, loa, beam, draft, power, speed, year, owner, cur_class in vessel_rows:
        vid = str(uuid.uuid4())
        vessel_ids[(code, name)] = vid
        cur.execute("""
            insert into public.vessels (id, project_id, name, imo_number, flag_state, loa_m, beam_m, draft_m, power_kw, speed_knots, build_year, owner_company, current_class, created_at)
            values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
        """, (vid, project_ids[code], name, imo, flag, loa, beam, draft, power, speed, year, owner, cur_class))

    team_rows = [
        ('Y-2996', 'm.hassan@classification.com', 'dm', 'Hull & Structure'),
        ('Y-2996', 'park@classification.com', 'surveyor', 'Hull & Structure'),
        ('C-5421', 'm.hassan@classification.com', 'dm', 'Machinery'),
        ('C-5421', 'khan@classification.com', 'surveyor', 'Machinery'),
        ('M-7834', 'r.alfarsi@classification.com', 'dm', 'Hull & Structure'),
        ('M-7834', 'ali@classification.com', 'surveyor', 'Hull & Structure'),
        ('Z-1187', 'r.alfarsi@classification.com', 'dm', 'Stability'),
        ('Z-1187', 'faruk@classification.com', 'engineer', 'Stability'),
    ]
    for code, email, role, discipline in team_rows:
        cur.execute("insert into public.team_assignments (id, project_id, user_id, role, discipline, assigned_at) values (%s, %s, %s, %s, %s, now())", (str(uuid.uuid4()), project_ids[code], profile_ids[email], role, discipline))

    stake_rows = [
        ('Y-2996', 'Damen Shipyards', 'Mohammed Ali', 'shipyard@damen.com', 'shipyard'),
        ('C-5421', 'Oceanic Ship Management', 'John Smith', 'shipmanagement@oceanic.co', 'ship_management'),
        ('M-7834', 'Vessel Holdings Ltd', 'Fatima Noor', 'owner@vesselholdings.com', 'owner'),
        ('Z-1187', 'Damen Shipyards', 'Tayyab Qureshi', 'designer@damen.com', 'designer'),
    ]
    for code, company, contact, email, kind in stake_rows:
        cur.execute("insert into public.stakeholders (id, project_id, company_name, contact_name, contact_email, stakeholder_type, added_at) values (%s,%s,%s,%s,%s,%s,now())", (str(uuid.uuid4()), project_ids[code], company, contact, email, kind))

    rfi_rows = [
        ('Y-2996', 'KARACHI SB-293 "GUN BOAT"', 'nsc_survey', 'Final NSC Survey', 'RFI-2027-014', 'pending_allocation', 'shipyard@damen.com', 'm.hassan@classification.com', 'park@classification.com', '2026-08-12', '2026-08-18', 'high'),
        ('C-5421', 'GULSHAN EXPRESS', 'in_service', 'Change of Class', 'RFI-2027-015', 'pending_allocation', 'shipmanagement@oceanic.co', None, None, '2026-08-14', '2026-08-18', 'high'),
        ('M-7834', 'ABC CARGO', 'in_service', 'Class Renewal', 'RFI-2027-011', 'allocated_to_dm', 'owner@vesselholdings.com', 'r.alfarsi@classification.com', 'ali@classification.com', '2026-08-06', '2026-08-18', 'medium'),
        ('Y-2996', 'KARACHI SB-293 "GUN BOAT"', 'in_service', 'Annual Survey', 'RFI-2027-009', 'survey_in_progress', 'shipmanagement@oceanic.co', 'm.hassan@classification.com', 'park@classification.com', '2026-08-09', '2026-08-14', 'medium'),
        ('C-5421', 'GULSHAN EXPRESS', 'in_service', 'Intermediate Survey', 'RFI-2027-006', 'observations_logged', 'shipmanagement@oceanic.co', 'm.hassan@classification.com', 'khan@classification.com', '2026-08-03', '2026-08-10', 'high'),
        ('Y-2996', 'KARACHI SB-293 "GUN BOAT"', 'nsc_survey', 'FTP', 'RFI-2027-001', 'pending_gm_approval', 'shipyard@damen.com', 'm.hassan@classification.com', 'park@classification.com', '2026-07-30', '2026-08-12', 'high'),
        ('M-7834', 'ABC CARGO', 'in_service', 'Annual Survey', 'RFI-2027-002', 'pending_gm_approval', 'owner@vesselholdings.com', 'r.alfarsi@classification.com', 'ali@classification.com', '2026-08-07', '2026-08-16', 'high'),
        ('Z-1187', 'ZENITH TRADER', 'nsc_survey', 'Plan Appraisal', 'RFI-2027-003', 'allocated_to_dm', 'designer@damen.com', 'r.alfarsi@classification.com', 'faruk@classification.com', '2026-08-11', '2026-08-15', 'medium'),
    ]
    for code, vessel_name, phase, survey_type, rfi_code, status, requester_email, dm_email, surveyor_email, requested_date, scheduled_date, priority in rfi_rows:
        vid = vessel_ids[(code, vessel_name)]
        cur.execute("insert into public.rfis (id, project_id, vessel_id, phase, survey_type, rfi_code, status, requested_by, assigned_dm_id, assigned_surveyor_id, requested_date, scheduled_date, priority, created_at, updated_at) values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,now(),now())", (str(uuid.uuid4()), project_ids[code], vid, phase, survey_type, rfi_code, status, profile_ids.get(requester_email), profile_ids.get(dm_email), profile_ids.get(surveyor_email), requested_date, scheduled_date, priority))

    observation_rows = [
        ('RFI-2027-006', 'OBS-006-01', 'Localised coating breakdown, port ballast tank frame 44-48.', 'Minor', 'open', 'khan@classification.com'),
        ('RFI-2027-002', 'OBS-002-01', 'Main engine coolant seepage at auxiliary pump gland.', 'Major', 'open', 'ali@classification.com'),
        ('RFI-2027-002', 'OBS-002-02', 'Corrosion pitting on weather deck plating, frame 60.', 'Minor', 'open', 'ali@classification.com'),
    ]
    for rfi_code, obs_code, desc, sev, status, raised_email in observation_rows:
        cur.execute('select id from public.rfis where rfi_code=%s', (rfi_code,))
        rfi_id = cur.fetchone()[0]
        cur.execute("insert into public.observations (id, rfi_id, obs_code, description, severity, status, raised_by, raised_at, cleared_at) values (%s,%s,%s,%s,%s,%s,%s,now(),null)", (str(uuid.uuid4()), rfi_id, obs_code, desc, sev, status, profile_ids[raised_email]))

    decision_rows = [
        ('RFI-2027-002', 'approved', 'Approved with open observations for controlled interim certification.', 'gm@classification.com'),
        ('RFI-2027-001', 'approved', 'Approved without observations and ready for issuance.', 'gm@classification.com'),
    ]
    for rfi_code, decision, note, email in decision_rows:
        cur.execute('select id from public.rfis where rfi_code=%s', (rfi_code,))
        rfi_id = cur.fetchone()[0]
        cur.execute("insert into public.gm_decisions (id, rfi_id, decided_by, decision, note, decided_at) values (%s,%s,%s,%s,%s,now())", (str(uuid.uuid4()), rfi_id, profile_ids[email], decision, note))

    cert_rows = [
        ('Y-2996', 'NCC-2026-071-Y2996', 'nsc_certificate', '2026-07-01', '2027-01-01', 'gm@classification.com'),
        ('C-5421', 'ICC-2027-001-C5421', 'interim_certificate', '2026-07-02', '2026-09-11', 'gm@classification.com'),
        ('M-7834', 'CC-2023-001-M7834', 'class_certificate', '2026-07-03', '2027-02-01', 'gm@classification.com'),
    ]
    for code, cert_num, cert_type, issue_date, expiry_date, email in cert_rows:
        vid = vessel_ids[(code, next(v[1] for v in vessel_rows if v[0] == code))]
        cur.execute("insert into public.certificates (id, vessel_id, project_id, rfi_id, cert_type, cert_number, issue_date, expiry_date, status, pending_observations, issued_by, pdf_storage_path, created_at) values (%s,%s,%s,null,%s,%s,%s,%s,%s,%s,%s,null,now())", (str(uuid.uuid4()), vid, project_ids[code], cert_type, cert_num, issue_date, expiry_date, 'active', '[]', profile_ids[email]))

    for project_code, file_name, category in [
        ('Z-1187', 'Hydrostatic_Curves_Rev_A.pdf', 'drawing'),
        ('Z-1187', 'General_Arrangement_Rev_B.pdf', 'drawing'),
        ('Z-1187', 'Newbuild_Contract_Zenith.pdf', 'contract'),
    ]:
        cur.execute("insert into public.documents (id, project_id, category, file_name, version, status, storage_path, uploaded_by, uploaded_at) values (%s,%s,%s,%s,1,%s,null,%s,now())", (str(uuid.uuid4()), project_ids[project_code], category, file_name, 'pending_review' if 'Hydro' in file_name else 'approved', profile_ids['designer@damen.com']))

    cur.execute("insert into public.audit_log (id, project_id, actor_id, action, details, created_at) values (%s,%s,%s,%s,%s,now())", (str(uuid.uuid4()), project_ids['Y-2996'], profile_ids['gm@classification.com'], 'CERTIFICATE_ISSUED', json.dumps({'cert_number':'NCC-2026-071-Y2996'})))

    counts = {}
    for table, stmt in {
        'profiles': 'select count(*) from public.profiles',
        'projects': 'select count(*) from public.projects',
        'vessels': 'select count(*) from public.vessels',
        'team_assignments': 'select count(*) from public.team_assignments',
        'stakeholders': 'select count(*) from public.stakeholders',
        'rfis': 'select count(*) from public.rfis',
        'observations': 'select count(*) from public.observations',
        'gm_decisions': 'select count(*) from public.gm_decisions',
        'certificates': 'select count(*) from public.certificates',
        'documents': 'select count(*) from public.documents',
        'audit_log': 'select count(*) from public.audit_log',
    }.items():
        cur.execute(stmt)
        counts[table] = cur.fetchone()[0]
    print(json.dumps(counts, indent=2))
    conn.close()
    print('seeded complete')

if __name__ == '__main__':
    main()