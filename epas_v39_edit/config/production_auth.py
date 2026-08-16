"""Authentication compatibility shim for demo/standalone EPAS snapshots."""

from __future__ import annotations

import os

from config import demo_runtime

_DEMO_EMAILS = {
    "gm@classification.com": {"id": "demo-gm", "email": "gm@classification.com", "full_name": "Ahmed Al-Maktoum", "role": "gm"},
    "m.hassan@classification.com": {"id": "demo-dm", "email": "m.hassan@classification.com", "full_name": "Muhammad Hassan", "role": "dm"},
    "faruk@classification.com": {"id": "demo-engineer", "email": "faruk@classification.com", "full_name": "Faruk Rahman", "role": "engineer"},
    "park@classification.com": {"id": "demo-surveyor", "email": "park@classification.com", "full_name": "Park Min-seo", "role": "surveyor"},
    "designer@damen.com": {"id": "demo-designer", "email": "designer@damen.com", "full_name": "Nadia Voss", "role": "designer"},
    "shipyard@damen.com": {"id": "demo-shipyard", "email": "shipyard@damen.com", "full_name": "Damen Yard Team", "role": "shipyard"},
    "shipmanagement@oceanic.co": {"id": "demo-ship-management", "email": "shipmanagement@oceanic.co", "full_name": "Oceanic Ship Management", "role": "ship_management"},
    "owner@vesselholdings.com": {"id": "demo-owner", "email": "owner@vesselholdings.com", "full_name": "Vessel Holdings", "role": "owner"},
}

_SESSION = {"user": None}


def _demo_password() -> str:
    return os.getenv("EPAS_DEMO_PASSWORD", "PSB-Demo-2026!")


def current_user() -> dict | None:
    return _SESSION["user"]


def sign_in(email: str, password: str) -> tuple[bool, str]:
    email = (email or "").strip().lower()
    password = password or ""
    demo_mode = os.getenv("EPAS_RUNTIME_MODE", "").strip().lower() == "demo"
    if not demo_mode:
        return (False, "Authentication is not configured in this workspace snapshot.")

    if email not in _DEMO_EMAILS:
        return (False, "Unknown demo account. Use a published demo email from DEMO_CREDENTIALS.md.")
    if password != _demo_password():
        return (False, "Incorrect demo password. Use PSB-Demo-2026! or the configured EPAS_DEMO_PASSWORD.")

    user = dict(_DEMO_EMAILS[email])
    user["company_name"] = "Demo Authority"
    _SESSION["user"] = user
    demo_runtime.set_current_user(user)
    return (True, f"Demo login successful for {user['email']}.")


def sign_out() -> None:
    _SESSION["user"] = None
    demo_runtime.set_current_user(None)


def request_password_reset(email: str) -> tuple[bool, str]:
    if not email or not email.strip():
        return (False, "Enter your account email.")
    if os.getenv("EPAS_RUNTIME_MODE", "").strip().lower() != "demo":
        return (False, "Password reset is not configured in this workspace snapshot.")
    return (True, "Demo password reset is not required in local demo mode. Use the published demo password.")


__all__ = ["current_user", "sign_in", "sign_out", "request_password_reset"]
