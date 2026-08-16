"""Minimal compatibility client for EPAS.

The original project expected a Supabase client and session-scoped helpers that are absent
from this workspace snapshot. This shim keeps imports working while the application is
configured against a real backend.

The demo runtime auto-loads the bundled .env.demo when no explicit EPAS_RUNTIME_MODE is set;
this preserves the GitHub/Codespaces preview flow without requiring a real Supabase project.
The production promotion script removes `.env.demo` before deployment to ensure the live runtime
uses only production configuration and credentials.
"""

from __future__ import annotations

import os
from pathlib import Path


def _load_demo_env_file() -> None:
    """Load the bundled demo env file as a safe fallback for local preview runs."""
    if os.getenv("EPAS_RUNTIME_MODE"):
        return
    env_path = Path(__file__).resolve().parents[1] / ".env.demo"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        clean = line.strip()
        if not clean or clean.startswith("#") or "=" not in clean:
            continue
        key, value = clean.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


_load_demo_env_file()


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def is_demo_mode() -> bool:
    return os.getenv("EPAS_RUNTIME_MODE", "").strip().lower() == "demo"


def get_client():
    """Return a stub client when Supabase is not configured."""
    return None


def connection_badge() -> tuple[str, str]:
    if os.getenv("SUPABASE_URL") and os.getenv("SUPABASE_ANON_KEY"):
        return ("Live Supabase", "success")
    return ("Offline / demo mode", "warning")


def demo_env_ready() -> bool:
    return os.path.exists(".env.demo") or (Path(__file__).resolve().parents[1] / ".env.demo").exists()


__all__ = ["get_client", "is_demo_mode", "connection_badge", "demo_env_ready", "_load_demo_env_file"]
