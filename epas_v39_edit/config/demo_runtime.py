"""Demo runtime compatibility shim for EPAS.

This module provides the in-memory dataset used by the public preview path when the
workspace snapshot is intentionally run without a live Supabase project.
"""

from __future__ import annotations

from database.seed_data import build_seed_db as _seed_build

_DB = None
_SESSION = {"user": None}


def _db():
    global _DB
    if _DB is None:
        _DB = _seed_build()
    return _DB


def current_user() -> dict | None:
    return _SESSION["user"]


def set_current_user(user: dict | None) -> None:
    _SESSION["user"] = user


def build_seed_db():
    return _seed_build()


__all__ = ["_db", "current_user", "set_current_user", "build_seed_db"]
