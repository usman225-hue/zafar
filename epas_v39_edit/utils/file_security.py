"""File security scan compatibility shim."""

from __future__ import annotations


def scan_bytes(content: bytes):
    return True, "No malware scan configured in this workspace snapshot."


__all__ = ["scan_bytes"]
