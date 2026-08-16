"""Small HTML and formatting helpers used across EPAS components."""

from __future__ import annotations

from datetime import datetime


def initials(name: str | None) -> str:
    if not name:
        return "EP"
    parts = [p for p in str(name).split() if p]
    if not parts:
        return "EP"
    if len(parts) == 1:
        return parts[0][:2].upper()
    return (parts[0][0] + parts[-1][0]).upper()


def badge(label: str, kind: str = "neutral") -> str:
    return f'<span class="badge badge--{kind}">{label}</span>'


def relative_age(value):
    if not value:
        return "—"
    try:
        if isinstance(value, str):
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        delta = datetime.now(value.tzinfo or value.astimezone().tzinfo or None) - value
    except Exception:
        return str(value)
    total_seconds = max(int(delta.total_seconds()), 0)
    if total_seconds < 60:
        return "just now"
    minutes = total_seconds // 60
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    if days < 30:
        return f"{days}d ago"
    months = days // 30
    return f"{months}mo ago"


def fmt_date(value):
    if not value:
        return "—"
    try:
        if isinstance(value, str):
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value.strftime("%Y-%m-%d")
    except Exception:
        return str(value)


def rfi_status_badge(status: str) -> str:
    return badge(str(status).replace("_", " ").title(), "info")


def priority_badge(priority: str) -> str:
    return badge(str(priority).replace("_", " ").title(), "warning" if str(priority).lower() in {"high", "urgent"} else "neutral")


def severity_badge(severity: str) -> str:
    return badge(str(severity).replace("_", " ").title(), "danger" if str(severity).lower() in {"critical", "major"} else "warning")


def doc_status_badge(status: str) -> str:
    return badge(str(status).replace("_", " ").title(), "success" if "approved" in str(status).lower() else "neutral")


def days_remaining_badge(expiry_date):
    try:
        if not expiry_date:
            return badge("No expiry", "neutral")
        if isinstance(expiry_date, str):
            expiry_date = datetime.fromisoformat(expiry_date.replace("Z", "+00:00"))
        delta = (expiry_date.date() - datetime.now().date()).days
        if delta < 0:
            return badge(f"Expired {abs(delta)}d ago", "danger")
        if delta <= 45:
            return badge(f"{delta}d left", "warning")
        return badge(f"{delta}d left", "success")
    except Exception:
        return badge("Check date", "neutral")


def phase_icon_label(phase: str) -> str:
    mapping = {
        "plan_appraisal": "📐 Plan Appraisal",
        "nsc_survey": "🏗️ NSC Survey",
        "in_service": "⚓ In-Service",
    }
    return mapping.get(phase, str(phase).replace("_", " ").title())


def modal(title: str, width: str | None = None):
    """Compatibility wrapper for Streamlit modal dialogs.

    Newer Streamlit versions expose st.dialog(), while older versions do not. Returning the
    undecorated function keeps the application importable when the dialog API is absent.
    """
    def decorator(fn):
        dialog_factory = getattr(__import__('streamlit', fromlist=['dialog']), 'dialog', None)
        if dialog_factory is not None:
            return dialog_factory(title)(fn)
        return fn
    return decorator


__all__ = [
    "initials", "badge", "relative_age", "fmt_date", "rfi_status_badge",
    "priority_badge", "severity_badge", "doc_status_badge", "days_remaining_badge",
    "phase_icon_label", "modal",
]
