"""Settings and constants for EPAS.

This project originally expected a dedicated config package with a settings module.
The workspace snapshot is missing that package, so this compatibility shim provides the
core constants required by the application and test suite to import correctly.
"""

from __future__ import annotations

APP_NAME = "EPAS"
APP_VERSION = "4.0"
APP_TAGLINE = "Classification, Survey & Maritime Safety"
ORG_NAME = "Pakistan Shipping Bureau"

ROLE_GM = "gm"
ROLE_DM = "dm"
ROLE_ENGINEER = "engineer"
ROLE_SURVEYOR = "surveyor"
ROLE_DESIGNER = "designer"
ROLE_SHIP_MANAGEMENT = "ship_management"
ROLE_OWNER = "owner"
ROLE_SHIPYARD = "shipyard"

EXTERNAL_STAKEHOLDER_ROLES = (ROLE_OWNER, ROLE_SHIPYARD)
STAKEHOLDER_EXECUTION_ROLES = (ROLE_SHIP_MANAGEMENT, ROLE_DESIGNER)
STAKEHOLDER_READONLY_ROLES = (ROLE_OWNER, ROLE_SHIPYARD)

ROLE_LABELS = {
    ROLE_GM: "General Manager",
    ROLE_DM: "Department Manager",
    ROLE_ENGINEER: "Engineer",
    ROLE_SURVEYOR: "Surveyor",
    ROLE_DESIGNER: "Designer",
    ROLE_SHIP_MANAGEMENT: "Ship Management",
    ROLE_OWNER: "Owner",
    ROLE_SHIPYARD: "Shipyard",
}

PHASE_PLAN_APPRAISAL = "plan_appraisal"
PHASE_NSC_SURVEY = "nsc_survey"
PHASE_IN_SERVICE = "in_service"

PHASE_ICONS = {
    PHASE_PLAN_APPRAISAL: "📐",
    PHASE_NSC_SURVEY: "🏗️",
    PHASE_IN_SERVICE: "⚓",
}

PHASE_LABELS = {
    PHASE_PLAN_APPRAISAL: "Plan Appraisal",
    PHASE_NSC_SURVEY: "NSC Survey",
    PHASE_IN_SERVICE: "In-Service Survey",
}

PROJECT_STATUS_ACTIVE = "active"
PROJECT_STATUS_ON_HOLD = "on_hold"
PROJECT_STATUS_CLOSED = "closed"

PROJECT_STATUS_LABELS = {
    PROJECT_STATUS_ACTIVE: "Active",
    PROJECT_STATUS_ON_HOLD: "On Hold",
    PROJECT_STATUS_CLOSED: "Closed",
}

DOC_CATEGORY_DRAWING = "drawing"
DOC_CATEGORY_CONTRACT = "contract"
DOC_CATEGORY_RULES = "rules"
DOC_CATEGORY_TIMELINE = "timeline"
DOC_CATEGORY_OTHER = "other"

DOC_CATEGORY_LABELS = {
    DOC_CATEGORY_DRAWING: "Drawing",
    DOC_CATEGORY_CONTRACT: "Contract",
    DOC_CATEGORY_RULES: "Rules",
    DOC_CATEGORY_TIMELINE: "Timeline",
    DOC_CATEGORY_OTHER: "Other",
}

CERT_TYPE_CLASS = "class"
CERT_TYPE_INTERIM = "interim"
CERT_TYPE_NSC = "nsc"

CERT_TYPE_LABELS = {
    CERT_TYPE_CLASS: "Class Certificate",
    CERT_TYPE_INTERIM: "Interim Certificate",
    CERT_TYPE_NSC: "New Build Certificate",
}

CERT_TYPE_PREFIX = {
    CERT_TYPE_CLASS: "CL",
    CERT_TYPE_INTERIM: "IT",
    CERT_TYPE_NSC: "NSC",
}

CERT_STATUS_ACTIVE = "active"
CERT_STATUS_EXPIRED = "expired"
CERT_STATUS_REVOKED = "revoked"

CERT_VALIDITY_DEFAULT_MONTHS = {
    "class": 12,
    CERT_TYPE_INTERIM: 6,
    CERT_TYPE_NSC: 12,
}

INTERIM_VALIDITY_OPTIONS_MONTHS = [3, 6, 12]
CERT_EXPIRING_SOON_DAYS = 45

RFI_PENDING_ALLOCATION = "pending_allocation"
RFI_ALLOCATED = "allocated"
RFI_SURVEY_IN_PROGRESS = "survey_in_progress"
RFI_OBSERVATIONS_LOGGED = "observations_logged"
RFI_PENDING_GM_APPROVAL = "pending_gm_approval"
RFI_SENT_BACK = "sent_back"
RFI_APPROVED_CLEAN = "approved_clean"
RFI_APPROVED_WITH_OBS = "approved_with_obs"
RFI_CERT_ISSUED = "cert_issued"
RFI_CLOSED = "closed"

RFI_GM_ACTIONABLE = (
    RFI_PENDING_GM_APPROVAL,
    RFI_SENT_BACK,
    RFI_OBSERVATIONS_LOGGED,
)

RFI_STAGE_LABELS = {
    RFI_PENDING_ALLOCATION: "Pending Allocation",
    RFI_ALLOCATED: "Allocated",
    RFI_SURVEY_IN_PROGRESS: "Survey In Progress",
    RFI_OBSERVATIONS_LOGGED: "Observations Logged",
    RFI_PENDING_GM_APPROVAL: "Pending GM Approval",
    RFI_SENT_BACK: "Sent Back",
    RFI_APPROVED_CLEAN: "Approved Clean",
    RFI_APPROVED_WITH_OBS: "Approved with Observations",
    RFI_CERT_ISSUED: "Certificate Issued",
    RFI_CLOSED: "Closed",
}

OBS_OPEN = "open"
OBS_CLOSED = "closed"
OBS_SEVERITY = ["Minor", "Major", "Critical"]

DISCIPLINES = ["Hull", "Machinery", "Electrical", "Safety"]

VESSEL_TYPES = [
    "Bulk Carrier",
    "Container Ship",
    "Tanker",
    "Ro-Ro",
    "Passenger Vessel",
    "Offshore Support",
    "Fishing Vessel",
    "Yacht",
]

COMMON_FLAG_STATES = [
    "Pakistan",
    "Singapore",
    "Panama",
    "Liberia",
    "Marshall Islands",
    "Malta",
    "United Kingdom",
    "United Arab Emirates",
]

NAV_ITEMS = [
    ("overview", "Overview", "🏠"),
    ("projects", "Projects", "📁"),
    ("operations", "Operations", "⚙️"),
    ("survey", "Survey", "🧭"),
    ("governance", "Governance", "✅"),
]

__all__ = [
    "APP_NAME", "APP_VERSION", "APP_TAGLINE", "ORG_NAME",
    "ROLE_GM", "ROLE_DM", "ROLE_ENGINEER", "ROLE_SURVEYOR", "ROLE_DESIGNER",
    "ROLE_SHIP_MANAGEMENT", "ROLE_OWNER", "ROLE_SHIPYARD",
    "ROLE_LABELS", "PHASE_PLAN_APPRAISAL", "PHASE_NSC_SURVEY", "PHASE_IN_SERVICE",
    "PHASE_ICONS", "PHASE_LABELS", "PROJECT_STATUS_ACTIVE", "PROJECT_STATUS_ON_HOLD",
    "PROJECT_STATUS_CLOSED", "PROJECT_STATUS_LABELS", "DOC_CATEGORY_DRAWING",
    "DOC_CATEGORY_CONTRACT", "DOC_CATEGORY_RULES", "DOC_CATEGORY_TIMELINE",
    "DOC_CATEGORY_OTHER", "DOC_CATEGORY_LABELS", "CERT_TYPE_CLASS", "CERT_TYPE_INTERIM",
    "CERT_TYPE_NSC", "CERT_TYPE_LABELS", "CERT_TYPE_PREFIX", "CERT_STATUS_ACTIVE",
    "CERT_STATUS_EXPIRED", "CERT_STATUS_REVOKED", "CERT_VALIDITY_DEFAULT_MONTHS",
    "INTERIM_VALIDITY_OPTIONS_MONTHS", "CERT_EXPIRING_SOON_DAYS", "RFI_PENDING_ALLOCATION",
    "RFI_ALLOCATED", "RFI_SURVEY_IN_PROGRESS", "RFI_OBSERVATIONS_LOGGED",
    "RFI_PENDING_GM_APPROVAL", "RFI_SENT_BACK", "RFI_APPROVED_CLEAN",
    "RFI_APPROVED_WITH_OBS", "RFI_CERT_ISSUED", "RFI_CLOSED", "RFI_GM_ACTIONABLE",
    "RFI_STAGE_LABELS", "OBS_OPEN", "OBS_CLOSED", "OBS_SEVERITY", "DISCIPLINES",
    "VESSEL_TYPES", "COMMON_FLAG_STATES", "NAV_ITEMS",
]
