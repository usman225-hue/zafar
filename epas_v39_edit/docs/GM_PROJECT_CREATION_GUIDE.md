# GM Project Creation Guide

## Location: Where to Create Projects

### Navigation Path

1. **Login to EPAS** at `http://localhost:851`
2. **Authenticate** as GM: `gm@classification.com` / `demo123`
3. **Main Dashboard** shows the "GM WORKSPACE" radio button selector
4. **Select: "Create Project"** from the workspace options

### Visual Location

```
EPAS · GM Classification
├── Command Center
├── [Create Project] ← SELECT THIS
├── Projects & Health
├── Plan Appraisal
├── Survey RFIs
├── Escalations
├── Governance
├── Notifications
└── Governance & Closure
```

---

## Project Creation Interface

There are **TWO ways** to create a project in EPAS v3.6:

### Option A: Quick Create (Single Page Form)
- **Section**: "Create Project" in GM WORKSPACE
- **Method**: Single comprehensive form with all fields on one page
- **Use when**: GM wants to fill everything at once
- **Time**: ~5 minutes

### Option B: Project Wizard (5-Step Guided Process)
- **Location**: "Create Project" page (separate link in main menu)
- **Method**: Step-by-step guided wizard with validation
- **Use when**: Systematic, structured data entry preferred
- **Time**: ~10 minutes with explanations

Both options create the same project with identical results. Choose based on preference.

---

## OPTION A: Quick Create Form

### Page Structure

**Title**: "Project Creation & Activation"

**Subtitle**: "The GM creates the project once. PostgreSQL atomically activates it, creates the vessel/team/stakeholder records, milestones and workflow notifications."

### Section 1: Core Project Information

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| **Project / Vessel name** | Text | ✓ Yes | e.g., "ZENITH TRADER Newbuild" |
| **Vessel type** | Text | ✓ Yes | e.g., "Bulk Carrier", "Container Ship", "Tanker" |
| **Flag state** | Text | ✓ Yes | e.g., "Panama", "Marshall Islands", "Singapore" |
| **Project code** | Text | Optional | Auto-generated if blank; e.g., "Y-2996" |
| **Classification number** | Text | Optional | From classification authority |
| **Register number** | Text | Optional | Official register number if applicable |
| **Contract number** | Text | Optional | Shipbuilding contract reference |
| **Classification request** | Text | Optional | Specific request from owner |
| **Classification scope** | Text | Optional | Scope of classification work |

### Section 2: Project Timeline & Build Stage

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| **Project start** | Date | ✓ Yes | Default: Today's date |
| **Target completion** | Date | ✓ Yes | Default: 180 days from start |
| **Build stage** | Dropdown | ✓ Yes | Options: "New Building", "In-Service", "Change of Class", "Class Renewal" |
| **Workflow phases** | Multi-select | ✓ Yes | At least 1 phase required; Options: "plan_appraisal", "nsc_survey", "in_service" |
| **Applicable rules** | Text | Optional | Semicolon-separated list of rules |
| **GM project remarks** | Text Area | Optional | Any additional notes or remarks |

### Section 3: Vessel Particulars

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| **IMO number** | Text | Optional | International Maritime Organization number; or "—" if not yet assigned |
| **LOA (m)** | Number | Optional | Length Overall in meters |
| **Beam (m)** | Number | Optional | Beam/width in meters |
| **Draft (m)** | Number | Optional | Draft/depth in meters |
| **Power (kW)** | Number | Optional | Engine power in kilowatts |
| **Speed (kn)** | Number | Optional | Maximum speed in knots |
| **Build year** | Number | ✓ Yes | Year of construction; range 1900-2100 |
| **Owner company** | Text | Optional | Company name of vessel owner |

### Section 4: Internal Team Assignment

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| **Department Manager** | Dropdown | ✓ Yes | Select from list of DM users; this person will manage design phase |
| **Designer company** | Text | Optional | Name of external designer/shipyard |
| **Linked Designer account** | Dropdown | Optional | If designer is in system, link to their account |
| **Shipyard company** | Text | Optional | Name of shipyard |
| **Ship Management company** | Text | Optional | Name of ship management company |
| **Linked Ship Management account** | Dropdown | Optional | If ship mgmt is in system, link to their account |

### Section 5: Document Uploads

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| **Contract / agreement** | File | Optional | PDF format; upload shipbuilding/repair contract |
| **Applicable class rules** | File | Optional | PDF format; upload relevant classification rules |
| **Approved project timeline** | File | Optional | PDF, XLSX, or CSV format; project schedule |

### Submission Button

**Button Label**: "Create & Activate Project →" (Primary/Blue button)

**Validation Before Submit**:
- ✓ Project/Vessel name must be filled
- ✓ Vessel type must be filled
- ✓ Flag state must be filled
- ✓ At least one workflow phase must be selected

---

## OPTION B: Project Wizard (5-Step Process)

### Visual Indicator: Wizard Rail

```
┌─────────────────────────────────────────────────────────┐
│  ✓ PROJECT    02 VESSEL      03 DOCUMENTS  04 TEAM    05 PHASES
│   INFO        PARTICULARS                                 
└─────────────────────────────────────────────────────────┘
```

Legend:
- **✓** = Completed step
- **02** = Current step
- **03** = Pending step

---

### STEP 1: Project Info

**Fields**:
- **Project / Vessel Name*** (Text input)
  - Placeholder: "e.g. ZENITH TRADER Newbuild"
  - Required for next step
- **Vessel Type*** (Dropdown)
  - Common options from settings: Bulk Carrier, Container Ship, Tanker, General Cargo, Patrol Vessel, etc.
- **Flag State*** (Dropdown)
  - Common options: Panama, Marshall Islands, Singapore, Liberia, Cyprus, Malta, etc.

**Navigation**:
- **Cancel**: Returns to Projects list
- **← Back**: N/A (first step)
- **Next →**: Enabled only when project name is filled

---

### STEP 2: Vessel Particulars

**Fields** (Left Column):
- **IMO / Registration No.** (Text)
  - Placeholder: "Leave blank if not yet assigned"
- **Length Overall (m)** (Number)
  - Min: 0.0, Step: 0.5
- **Beam (m)** (Number)
  - Min: 0.0, Step: 0.1
- **Draft (m)** (Number)
  - Min: 0.0, Step: 0.1

**Fields** (Right Column):
- **Power (kW)** (Number)
  - Min: 0.0, Step: 50.0
- **Speed (knots)** (Number)
  - Min: 0.0, Step: 0.5
- **Build Year** (Number)
  - Min: 1970, Max: 2035, Default: 2027
- **Owner Company** (Text)

**Navigation**:
- **← Back**: Returns to Step 1 (data preserved)
- **Next →**: Always enabled (all fields optional)

---

### STEP 3: Upload Documents

**Section**: Contract Documents
- **File Uploader**: Accept multiple PDFs
- **Stored**: File names in wizard data
- **Note**: "Files stay attached even if uploader looks empty after navigating back"

**Section**: Class Rules
- **File Uploader**: Accept multiple PDFs
- **Stored**: File names preserved in session

**Section**: Project Timeline
- **File Uploader**: Single file
- **Formats**: PDF, XLSX, or CSV
- **Info**: "📎 3 file(s) attached and will be catalogued when the project is created"

**Navigation**:
- **← Back**: Returns to Step 2 (documents preserved)
- **Next →**: Always enabled (all uploads optional)

---

### STEP 4: Assign Internal Team

**Department Manager Section** (Required):
- **Dropdown**: Select from list of DM users
- **Format**: Shows full name of each DM
- **Next step disabled** if not selected

**Engineers Section**:
- **Multi-select**: Pick multiple engineers
- **For each engineer**: Select discipline
  - Examples: Hull & Structure, Machinery, Electrical, Stability, etc.

**Surveyors Section**:
- **Multi-select**: Pick multiple surveyors
- **For each surveyor**: Select discipline
  - Same discipline options as engineers

**Navigation**:
- **← Back**: Returns to Step 3 (team selections preserved)
- **Next →**: Enabled only when Department Manager is selected

---

### STEP 5: Stakeholders & Project Phases (Final Step)

**Project Phases** (Checkboxes):
- ☐ **🔵 Plan Appraisal** — Design review & approval phase
- ☐ **🟡 NSC Survey** — New Ship Certificate survey
- ☐ **🟢 In-Service Surveys** — Ongoing compliance surveys

**Validation**: At least one phase required to finish.

**External Stakeholders Section**:

For each stakeholder type (Owner, Designer, Ship Management, Shipyard):

| Field | Type | Notes |
|-------|------|-------|
| Company name | Text | Leave blank to skip this role |
| Contact name | Text | Person responsible for this stakeholder |
| Contact email | Email | Will receive notifications |

**Example Completed Form**:

```
Owner — Company: "Zenith Bulk Holdings"
        Contact: "Fatima Noor"
        Email: "owner@zenithbulk.com"

Designer — Company: "Damen Shipyards"
          Contact: "Tayyab Qureshi"
          Email: "designer@damen.com"

Ship Management — Company: "Oceanic Ship Management"
                 Contact: "John Smith"
                 Email: "shipmanagement@oceanic.co"

Shipyard — Company: "Damen Shipyards"
          Contact: "Mohammed Ali"
          Email: "shipyard@damen.com"
```

**Navigation**:
- **← Back**: Returns to Step 4 (stakeholder data preserved)
- **✅ Create Project**: Disabled until at least one phase is selected

---

## What Happens When Project is Created

### Instant Actions (Atomic Transaction)

1. ✓ **Project Record Created**
   - Assigned unique UUID
   - Project code generated (if not provided)
   - All metadata stored

2. ✓ **Vessel Record Created**
   - Linked to project
   - Particulars populated
   - Classification tracking initialized

3. ✓ **Team Assignments Created**
   - Department Manager assigned
   - Engineers/Surveyors linked with disciplines
   - Roles and responsibilities established

4. ✓ **Stakeholder Records Created**
   - Owner, Designer, Ship Mgmt, Shipyard contacts stored
   - Email notifications queued

5. ✓ **Workflow Milestones Generated**
   - Phases activated (Plan Appraisal, NSC Survey, In-Service)
   - Phase-specific workflows initialized
   - Initial task queue created

6. ✓ **Notifications Sent**
   - GM: Project created confirmation
   - DM: Project assigned to you
   - Engineers/Surveyors: Project team assignment
   - Stakeholders: Welcome notifications

7. ✓ **Audit Log Entry**
   - Immutable record of project creation
   - Creator, timestamp, all parameters logged

### Result

**Status**: Project is **"Active"** and ready for workflow

**Next Steps Available**:
- If **Plan Appraisal phase** enabled → Upload design drawings
- If **NSC Survey phase** enabled → Create survey RFIs
- If **In-Service phase** enabled → Schedule maintenance surveys

---

## Required vs Optional Fields Summary

### REQUIRED (Project cannot be created without these)

- ✓ Project / Vessel Name
- ✓ Vessel Type
- ✓ Flag State
- ✓ At least ONE workflow phase
- ✓ Build Year
- ✓ Department Manager (assigned at Step 4)

### OPTIONAL (Recommended for completeness)

- ○ Project Code (auto-generated if blank)
- ○ Classification Number
- ○ IMO Number
- ○ All vessel particulars (LOA, Beam, Draft, Power, Speed)
- ○ Owner Company
- ○ All document uploads
- ○ Stakeholder details (company, contact, email)
- ○ Applicable rules
- ○ Remarks

### IMPORTANT BUSINESS LOGIC

- **Build Stage** affects workflow logic (Newbuild vs In-Service vs Class Renewal)
- **Workflow Phases** determine which workspace tabs are shown to team members
- **Department Manager** MUST be assigned (cannot be empty)
- **At least one Stakeholder** recommended for communication
- **Document uploads** are optional but recommended for traceability

---

## Common Workflows

### Workflow A: New Shipbuilding Project

1. **Quick Create** or **Wizard Step 1**:
   - Name: "ZENITH TRADER Newbuild"
   - Type: "Bulk Carrier"
   - Flag: "Marshall Islands"

2. **Build Stage**: Select "New Building"

3. **Phases**: Check ☑ Plan Appraisal + ☑ NSC Survey + ☑ In-Service

4. **Vessel Particulars**: Enter complete specifications

5. **Team**: Assign DM, 2-3 Engineers, 1 Surveyor

6. **Stakeholders**: Add Shipyard, Designer, Owner, Ship Management

7. **Documents**: Upload contract, rules, timeline

8. **Submit**: Project created and Plan Appraisal phase opens

---

### Workflow B: In-Service Class Renewal

1. **Quick Create** or **Wizard**:
   - Name: "GULSHAN EXPRESS Class Renewal"
   - Type: "Container Feeder"
   - Flag: "Panama"

2. **Build Stage**: Select "Class Renewal"

3. **Phases**: Check ☑ In-Service (Plan Appraisal typically not needed)

4. **Vessel Particulars**: IMO, LOA, Beam, Draft (from existing records)

5. **Team**: Assign DM and 1 Surveyor

6. **Stakeholders**: Add Ship Management, Owner

7. **Documents**: Upload current class certificate

8. **Submit**: Project activated for In-Service surveys

---

### Workflow C: Change of Class

1. **Quick Create**:
   - Name: "ABC CARGO Change of Class"
   - Type: "General Cargo"
   - Flag: "Panama"

2. **Build Stage**: Select "Change of Class"

3. **Phases**: ☑ Plan Appraisal + ☑ NSC Survey

4. **Details**: Existing vessel transitioning to new classification society

5. **Team & Stakeholders**: Full complement of internal team + external contacts

6. **Submit**: Dual-phase workflow activates

---

## Error Messages & Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| "Project/Vessel name required" | Name field empty | Fill "Project / Vessel Name" field |
| "Vessel type required" | Type not selected | Choose vessel type from dropdown |
| "Flag state required" | Flag not selected | Select flag state from dropdown |
| "At least one workflow phase required" | No phases checked | Check at least one phase (Plan/NSC/In-Service) |
| "Department Manager required" | DM not assigned | Go to Step 4 and select a DM from list |
| "File upload failed" | Document too large or wrong format | Ensure PDFs < 50MB, XLSX/CSV < 25MB |
| "Form cannot progress" | Session expired | Refresh page and start again |

---

## User Roles & Permissions

### Who can create projects?

- ✓ **General Manager (GM)** — Primary project creator
- ✗ Department Manager (DM) — Cannot create; assigned by GM
- ✗ Engineers — Cannot create; assigned by GM
- ✗ Surveyors — Cannot create; assigned by GM
- ✗ External Stakeholders — Cannot create; read-only access

---

## Data Retention & Archival

- **Active Projects**: Available in all dashboards and reports
- **Completed Projects**: Moved to "Closed" status after closure checklist
- **Archived Projects**: Retained for audit and reference; read-only access
- **Audit Trail**: All creation details logged immutably in audit_log table

---

## Related Documentation

- [GM Production Workflow](./GM_DM_PRODUCTION_V1_5_WORKFLOW.mmd)
- [EPAS Database Schema](./database/schema.sql)
- [User Role Permissions](./ROLE_PERMISSIONS.md)
- [Project Phases & Workflows](./PROJECT_PHASES.md)

---

## Quick Start Checklist

Before creating a project, have this information ready:

- [ ] Project name and vessel type
- [ ] Flag state
- [ ] Build stage (Newbuild/In-Service/Change of Class/Class Renewal)
- [ ] Workflow phases (Plan Appraisal, NSC Survey, In-Service)
- [ ] Department Manager name (from your team)
- [ ] Vessel specifications (IMO, dimensions, power, speed)
- [ ] Owner company and contact
- [ ] Designer/Shipyard company and contact
- [ ] Ship Management company and contact
- [ ] Key documents (contract, rules, timeline)

---

**Last Updated**: 2026-08-15
**EPAS Version**: v3.6
**Status**: Current & Complete
