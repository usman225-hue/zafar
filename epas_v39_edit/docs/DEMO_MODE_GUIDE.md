# How to See Demo Data in EPAS

## You're in Demo Mode! 🎯

The app is now showing a **yellow demo mode banner** at the top with your logged-in role and demo projects list.

---

## Where to Find Demo Projects

### Step 1: After Login, You'll See a Banner
```
🎯 DEMO MODE — Logged in as [Your Name] (GM)
Demo projects: KARACHI SB-293 • GULSHAN EXPRESS • ABC CARGO • ZENITH TRADER
```

### Step 2: Based on Your Role, Select the Right Section

#### IF YOU'RE A GM (General Manager)
1. Look for the **workspace radio buttons** at top
2. Select: **"Projects & Health"** or **"Command Center"**
3. You should see:
   - 4 active projects
   - 8 RFIs (Survey tasks)
   - Metrics showing pending decisions
   - Project health dashboard

#### IF YOU'RE A DM (Department Manager)  
1. Select: **"Operations Center"**
2. You should see:
   - Projects assigned to you
   - Plan appraisal work
   - Team assignments
   - Survey allocations

#### IF YOU'RE A SURVEYOR
1. Select: **"Field Cockpit"** or **"Survey Lifecycle"**
2. You should see:
   - RFIs assigned to you
   - Survey schedules
   - Observation records
   - Corrective actions

#### IF YOU'RE A DESIGNER
1. Select: **"Submission Cockpit"**
2. You should see:
   - Design drawings waiting for review
   - Observations from reviews

#### IF YOU'RE SHIP MANAGEMENT / OWNER
1. Select: **"Operations Cockpit"**
2. You should see:
   - Your assigned surveys
   - Project schedules
   - In-service maintenance

---

## Demo Projects & Sample Data

You have these 4 demo projects ready:

### 1. **KARACHI SB-293 Newbuild** (Project Code: Y-2996)
- **Type**: Patrol Vessel
- **Flag**: Pakistan
- **Status**: Active, NSC Survey phase
- **RFIs**: 
  - RFI-2027-014: Final NSC Survey (pending allocation to DM)
  - RFI-2027-009: Annual Survey (survey in progress)
  - RFI-2027-001: FTP (pending GM approval)
- **Team**: 
  - DM: Muhammad Hassan
  - Surveyor: Capt. Park Min-jae
- **Certificates**: NCC-2026-071-Y2996 (NSC Certificate)

### 2. **GULSHAN EXPRESS Change of Class** (Project Code: C-5421)
- **Type**: Container Feeder
- **Flag**: Pakistan
- **Status**: Active, In-Service phase
- **RFIs**:
  - RFI-2027-015: Change of Class (pending allocation)
  - RFI-2027-006: Intermediate Survey (observations logged)
- **Team**:
  - DM: Muhammad Hassan
  - Surveyor: Capt. Khan
- **Observations**: 1 minor issue (coating breakdown)
- **Certificates**: ICC-2027-001-C5421 (Interim Certificate)

### 3. **ABC CARGO Class Renewal** (Project Code: M-7834)
- **Type**: General Cargo
- **Flag**: Panama
- **Status**: Active, In-Service phase
- **RFIs**:
  - RFI-2027-011: Class Renewal (allocated to DM)
  - RFI-2027-002: Annual Survey (pending GM approval)
- **Team**:
  - DM: Rania Al-Farsi
  - Surveyor: Eng. Ali Raza
- **Observations**: 2 issues (coolant seepage, pitting)
- **Certificates**: CC-2023-001-M7834 (Class Certificate)

### 4. **ZENITH TRADER Newbuild** (Project Code: Z-1187)
- **Type**: Bulk Carrier
- **Flag**: Marshall Islands
- **Status**: Active, Plan Appraisal + NSC Survey phases
- **RFIs**:
  - RFI-2027-003: Plan Appraisal (allocated to DM)
- **Team**:
  - DM: Rania Al-Farsi
  - Engineer: Mehmet Faruk
- **Documents**: 3 files (hydrostatic curves, GA plan, contract)

---

## Demo User Accounts

All use password: **demo123**

### GM Role
- **gm@classification.com** — General Manager (Ahmed Al-Maktoum)

### Internal Team
- **m.hassan@classification.com** — Department Manager (Muhammad Hassan)
- **r.alfarsi@classification.com** — Department Manager (Rania Al-Farsi)
- **park@classification.com** — Surveyor (Capt. Park Min-jae)
- **khan@classification.com** — Surveyor (Capt. Khan)
- **ali@classification.com** — Surveyor (Eng. Ali Raza)
- **faruk@classification.com** — Engineer (Mehmet Faruk)

### External Stakeholders
- **designer@damen.com** — Designer (Tayyab Qureshi)
- **shipyard@damen.com** — Shipyard (Mohammed Ali)
- **shipmanagement@oceanic.co** — Ship Management (John Smith)
- **owner@vesselholdings.com** — Owner (Fatima Noor)

---

## Troubleshooting: "I Don't See Any Projects"

### Check 1: Are you logged in?
- Look for the **yellow demo banner** at top with your name and role
- If not visible, you're not logged in yet

### Check 2: Wrong workspace selected?
- The main navigation shows workspace options (Command Center, Projects, Survey, etc.)
- Select the **correct section for your role** (see table above)
- Different roles see different data

### Check 3: Still empty?
Run this quick check:

```bash
# Verify demo projects exist in database
cd /workspaces/ERPPSB/EPAS_v3_6
python3 -c "
import psycopg2
conn = psycopg2.connect('postgresql://postgres.ztqedstdufdnjdpixqls:P%40kistan9092909290@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres')
cur = conn.cursor()
cur.execute('SELECT COUNT(*) FROM public.projects')
print(f'Projects in DB: {cur.fetchone()[0]}')
conn.close()
"
```

### Check 3: Browser cache?
- Hard refresh: **Ctrl+Shift+R** (Windows) or **Cmd+Shift+R** (Mac)
- Clear Streamlit cache: Delete `.streamlit/cache` folder
- Restart app: `docker restart <container_id>`

### Check 4: RLS Permissions?
The app might be silently blocked by RLS policies. If you see a blank dashboard:
- Try logging in as **gm@classification.com** (has full access)
- Other roles might see filtered data based on project assignments

---

## What You Should See As Each Role

### GM Dashboard (Command Center)
```
┌─────────────────────────────────────────┐
│ Decisions Awaiting Me                   │
│ ├─ Plan approvals: 0                    │
│ ├─ Survey decisions: 2                  │
│ ├─ Overdue: 0                           │
│ └─ Open escalations: 0                  │
├─────────────────────────────────────────┤
│ METRICS                                 │
│ ├─ Active Projects: 4                   │
│ ├─ My Workflow Inbox: [tasks]           │
│ ├─ Plan Decisions: [pending]            │
│ ├─ Survey Decisions: 2                  │
│ └─ Open Escalations: 0                  │
└─────────────────────────────────────────┘
```

### DM Dashboard (Operations Center)
```
┌─────────────────────────────────────────┐
│ Allocated RFIs & Surveys                │
│ ├─ Plan Appraisal: [drawings review]    │
│ ├─ NSC Survey: [survey allocation]      │
│ ├─ In-Service: [maintenance survey]     │
├─────────────────────────────────────────┤
│ My Team Performance                     │
│ ├─ Engineers assigned: 2                │
│ ├─ Surveyors assigned: 3                │
│ └─ Pending approvals: 4                 │
└─────────────────────────────────────────┘
```

### Surveyor Dashboard (Field Cockpit)
```
┌─────────────────────────────────────────┐
│ My Survey Schedule                      │
│ ├─ RFI-2027-001: Survey in progress     │
│ ├─ RFI-2027-006: Observations logged    │
│ ├─ RFI-2027-009: Allocated to me        │
├─────────────────────────────────────────┤
│ Open Observations                       │
│ ├─ OBS-006-01: Coating breakdown        │
│ └─ OBS-002-02: Corrosion pitting        │
└─────────────────────────────────────────┘
```

---

## Next Steps After Seeing Demo

1. **Explore Each Role**: Log in as different demo users to see the workflow from each perspective
2. **Create Your Own Project**: Use the "Create Project" button (GM only) to make a real project
3. **Test the Workflow**: Assign a survey RFI, log observations, make GM decisions
4. **Configure Supabase**: Later, switch to your real Supabase credentials for production

---

## Still Not Seeing Anything?

Try the **quick reset**:

```bash
# Restart the Docker container
docker restart $(docker ps -q --filter "ancestor=epas-app")

# Or rebuild and restart
docker build -t epas-app .
docker run -p 851:851 -e SUPABASE_URL=... -e SUPABASE_ANON_KEY=... epas-app
```

Then refresh browser at http://localhost:851

---

**If demo still doesn't show up**, create an issue with:
- Your logged-in email/role
- Which workspace section you're in
- What you see on screen
- Browser console errors (F12 → Console tab)

**Demo is confirmed working!** ✓ 4 projects ✓ 11 users ✓ 8 RFIs loaded
