"""Reusable controlled document revision panel."""
from __future__ import annotations
import streamlit as st
from database import production_queries as q
from database import upgrade_queries as uq


def render(document_id: str, actor_id: str, allow_upload: bool = False) -> None:
    st.markdown("**Controlled revision history**")
    rows = uq.list_document_revisions(document_id)
    for r in rows:
        st.markdown(f'**Rev {r["revision"]}** · {r["status"]} · {r["file_name"]} · {r["created_at"]}')
    if allow_upload:
        f = st.file_uploader("Upload next revision (PDF)", type=["pdf"], key=f"doc_rev_upload_{document_id}")
        if f and st.button("Create controlled revision", key=f"doc_rev_create_{document_id}"):
            uq.create_revision_from_upload(document_id, f, actor_id)
            st.success("Revision recorded.")
            st.rerun()
