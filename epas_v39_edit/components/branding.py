"""Pakistan Shipping Bureau visual identity helpers for EPAS v3.6.1."""
from __future__ import annotations

from pathlib import Path
import base64
import html
import streamlit as st

from config import settings as cfg

ROOT = Path(__file__).resolve().parents[1]
LOGO = ROOT / "assets" / "psb_logo_master.png"
DARK_LOGO = ROOT / "assets" / "psb_logo_dark.jpg"

ROLE_META = {
    "gm": ("GM Classification", "Command & Governance", "gm"),
    "dm": ("Department Manager", "Allocation & Workflow Control", "dm"),
    "engineer": ("Authorized Engineer", "Plan Appraisal & Technical Review", "engineer"),
    "surveyor": ("Authorized Surveyor", "Field Survey & Verification", "surveyor"),
    "designer": ("Designer", "Design Submission & Revision", "designer"),
    "ship_management": ("Ship Management", "Corrective Action & Evidence", "shipmanagement"),
    "owner": ("Owner", "Fleet & Certificate Visibility", "stakeholder"),
    "shipyard": ("Shipyard", "New Construction Visibility", "stakeholder"),
}

def _data_uri(path: Path) -> str:
    if not path.exists():
        return ""
    mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"

def render_login_hero() -> None:
    logo = _data_uri(DARK_LOGO if DARK_LOGO.exists() else LOGO)
    st.markdown(
        f"""
        <section class="psb-login-hero">
          <div class="psb-login-hero__grid"></div>
          <div class="psb-login-hero__content">
            <div class="psb-login-logo-wrap">
              <img src="{logo}" class="psb-login-logo" alt="Pakistan Shipping Bureau logo">
            </div>
            <div class="psb-login-kicker">AUTHENTICATED MARITIME OPERATIONS</div>
            <h1>Pakistan Shipping Bureau</h1>
            <p class="psb-login-title">Classification, Safety &amp; Maritime Excellence</p>
            <div class="psb-login-divider"></div>
            <div class="psb-login-points">
              <span>Secure role-based access</span>
              <span>Controlled workflow execution</span>
              <span>Auditable decisions &amp; certificates</span>
            </div>
            <div class="psb-login-footer">Protecting lives, assets &amp; the marine environment.</div>
          </div>
        </section>
        """,
        unsafe_allow_html=True,
    )

def render_topbar(user: dict, view: str | None = None) -> None:
    role = user.get("role", "")
    role_label, role_subtitle, role_class = ROLE_META.get(
        role, ("EPAS User", "Authenticated workflow workspace", "default")
    )
    full_name = html.escape(user.get("full_name") or "Authenticated User")
    email = html.escape(user.get("email") or "")
    page_label = html.escape(view or role_subtitle)
    logo = _data_uri(LOGO)
    st.markdown(
        f"""
        <div class="psb-topbar">
          <div class="psb-topbar__brand">
            <img src="{logo}" alt="PSB" class="psb-topbar__logo">
            <div>
              <div class="psb-topbar__org">PAKISTAN SHIPPING BUREAU</div>
              <div class="psb-topbar__product">Classification &amp; Survey Management System</div>
            </div>
          </div>
          <div class="psb-topbar__context">
            <span class="psb-role-pill psb-role-pill--{role_class}">{html.escape(role_label)}</span>
            <div class="psb-user-block">
              <strong>{full_name}</strong>
              <span>{email}</span>
            </div>
          </div>
        </div>
        <div class="psb-context-row">
          <div><span class="psb-context-label">WORKSPACE</span><span class="psb-context-value">{page_label}</span></div>
          <div class="psb-secure-badge">● Authenticated · RLS Protected · Audit Enabled</div>
        </div>
        """,
        unsafe_allow_html=True,
    )
