"""Minimal session cache helper for EPAS.

This compatibility shim provides the interface expected by the codebase without requiring
an external caching layer.
"""

from __future__ import annotations

_cache: dict[str, tuple[float, object]] = {}


def make_key(*parts) -> str:
    return "::".join(str(p) for p in parts)


def cached_call(key: str, fn, ttl: float = 8.0):
    import time

    now = time.time()
    if key in _cache:
        expiry, value = _cache[key]
        if now < expiry:
            return value
    value = fn()
    _cache[key] = (now + ttl, value)
    return value


def clear() -> None:
    _cache.clear()


def clear_prefixes(prefixes):
    if not prefixes:
        return
    for key in list(_cache):
        if any(key.startswith(prefix) for prefix in prefixes):
            del _cache[key]


__all__ = ["make_key", "cached_call", "clear", "clear_prefixes"]
