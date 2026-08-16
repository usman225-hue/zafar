"""
EPAS · Document Detail Panel
------------------------------
The flowchart's "Document Detail Panel — slide-over, no page reload"
node. Streamlit has no true slide-over primitive, so `st.dialog` (a
centred modal overlay that also never triggers a full page reload) is
the closest faithful equivalent — content updates in place, the page
behind it is untouched.
"""

from __future__ import annotations

import streamlit as st

from config import settings as cfg
from database import production_queries as q
from utils import helpers as h


@h.modal("Document Detail", width="large")
def open_document_dialog(document_id: str) -> None:
    doc = q.get_document(document_id)
    if not doc:
        st.error("Document not found.")
        return

    uploader = q.get_user(doc.get("uploaded_by"))
    st.markdown(
        f'<div class="eyebrow">{cfg.DOC_CATEGORY_LABELS.get(doc["category"], doc["category"])}</div>'
        f'<div class="section-title">{doc["file_name"]}</div>'
        f'<div class="section-caption">v{doc["version"]} · uploaded by '
        f'{uploader["full_name"] if uploader else "—"} · {h.relative_age(doc["uploaded_at"])}</div>',
        unsafe_allow_html=True,
    )
    st.markdown(h.doc_status_badge(doc["status"]), unsafe_allow_html=True)
    st.write("")

    tab_files, tab_remarks, tab_history = st.tabs(["📁 Files & Versions", "💬 Remarks", "🕐 Approval History"])

    with tab_files:
        st.markdown(
            f"""
            <div class="card card--soft">
                <div style="display:flex; justify-content:space-between; align-items:center;">
                    <div>
                        <b>{doc['file_name']}</b><br>
                        <span class="section-caption">Version {doc['version']} · current</span>
                    </div>
                    {h.doc_status_badge(doc['status'])}
                </div>
            </div>
            """,
            unsafe_allow_html=True,
        )
        st.caption("Earlier versions appear here once a revision is uploaded to replace this file.")

    with tab_remarks:
        remarks = q.list_document_remarks(document_id)
        if not remarks:
            st.caption("No remarks yet.")
        for r in remarks:
            author = r.get("_author")
            st.markdown(
                f'<div style="padding:8px 0; border-bottom:1px solid var(--hairline);">'
                f'<b>{author["full_name"] if author else "—"}</b> '
                f'<span class="section-caption">· {h.relative_age(r["created_at"])}</span>'
                f'<div style="margin-top:3px; font-size:13.5px;">{r["body"]}</div></div>',
                unsafe_allow_html=True,
            )
        st.write("")
        new_remark = st.text_area("Add a remark", key=f"remark_{document_id}", height=70,
                                   placeholder="Note a required correction or leave context for the team…")
        if st.button("Post remark", key=f"post_remark_{document_id}"):
            if new_remark.strip():
                q.add_document_remark(document_id, q.current_gm()["id"], new_remark.strip())
                st.rerun()
            else:
                st.warning("Write something before posting.")

    with tab_history:
        st.caption("GM sign-off decision for this document.")
        if doc["status"] == "pending_review":
            c1, c2, c3 = st.columns(3)
            with c1:
                if st.button("✅ Approve", key=f"doc_approve_{document_id}", type="primary", use_container_width=True):
                    q.update_document_status(document_id, "approved")
                    st.rerun()
            with c2:
                if st.button("📝 Request Amendments", key=f"doc_amend_{document_id}", use_container_width=True):
                    q.update_document_status(document_id, "amendments_required")
                    st.rerun()
            with c3:
                if st.button("❌ Reject", key=f"doc_reject_{document_id}", use_container_width=True):
                    q.update_document_status(document_id, "rejected")
                    st.rerun()
        else:
            st.markdown(f"Current status: {h.doc_status_badge(doc['status'])}", unsafe_allow_html=True)
            if st.button("↺ Reopen for review", key=f"doc_reopen_{document_id}"):
                q.update_document_status(document_id, "pending_review")
                st.rerun()
