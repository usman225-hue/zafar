"""UI helpers used by the app."""

from __future__ import annotations

import streamlit as st


def show_safe_error(context: str, exc: Exception) -> None:
    st.error(f"{context}: {exc}")


__all__ = ["show_safe_error"]
