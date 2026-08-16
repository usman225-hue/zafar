"""EPAS in-app notification center."""
from __future__ import annotations
import streamlit as st
from database import production_queries as q
from database import upgrade_queries as uq


def render(user_id: str | None = None) -> None:
    user_id = user_id or q.current_gm()["id"]
    st.markdown('<div class="eyebrow">Workflow</div><div class="page-title">Notifications</div>', unsafe_allow_html=True)
    items = uq.list_notifications(user_id)
    if not items:
        st.info("No notifications.")
        return
    unread = [n for n in items if not n.get("read_at")]
    st.caption(f"{len(unread)} unread · {len(items)} total")
    if unread and st.button("Mark all as read"):
        for n in unread:
            uq.mark_notification_read(n["id"], user_id)
        st.rerun()
    for n in items:
        with st.container(border=True):
            c1, c2 = st.columns([5, 1])
            with c1:
                badge = "🔵" if not n.get("read_at") else "⚪"
                st.markdown(f'{badge} **{n["title"]}**')
                st.write(n["body"])
                st.caption(str(n["created_at"]))
            with c2:
                if not n.get("read_at") and st.button("Read", key=f"read_{n['id']}"):
                    uq.mark_notification_read(n["id"], user_id)
                    st.rerun()
