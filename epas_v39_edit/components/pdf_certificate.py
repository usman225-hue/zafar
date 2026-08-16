"""
EPAS · Certificate PDF Generator
---------------------------------
Renders the exact node the flowchart calls "PDF Generated & Archived"
into a real, downloadable file — a navy-bordered certificate with the
same two-ring seal motif used in the app's own UI, so the artifact a
shipowner receives looks like it came from the same institution as
the dashboard that issued it.
"""

from __future__ import annotations

import io

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

from config import settings as cfg

NAVY = colors.HexColor("#0E2340")
SIGNAL_BLUE = colors.HexColor("#1B4B91")
GREEN = colors.HexColor("#1E6E4C")
AMBER = colors.HexColor("#B9791E")
INK = colors.HexColor("#161F2C")
SLATE = colors.HexColor("#55607A")
HAIRLINE = colors.HexColor("#E3E7EE")
PARCHMENT = colors.HexColor("#FBFAF6")

_SEAL_COLOR = {
    cfg.CERT_TYPE_CLASS: GREEN,
    cfg.CERT_TYPE_INTERIM: AMBER,
    cfg.CERT_TYPE_NSC: SIGNAL_BLUE,
}


def _wrap_centred(c: canvas.Canvas, text: str, font: str, size: float, max_width: float,
                   cx: float, y: float, leading: float, color) -> float:
    """Draws `text` word-wrapped and centred on `cx`, returning the new y
    cursor after the last line."""
    c.setFont(font, size)
    c.setFillColor(color)
    words = text.split()
    line = ""
    for word in words:
        trial = f"{line} {word}".strip()
        if c.stringWidth(trial, font, size) > max_width and line:
            c.drawCentredString(cx, y, line)
            y -= leading
            line = word
        else:
            line = trial
    if line:
        c.drawCentredString(cx, y, line)
        y -= leading
    return y


def generate_certificate_pdf(cert: dict, vessel: dict, issuer_name: str) -> bytes:
    buf = io.BytesIO()
    page_w, page_h = A4
    c = canvas.Canvas(buf, pagesize=A4)

    # ---- background & border -------------------------------------------------
    c.setFillColor(PARCHMENT)
    c.rect(0, 0, page_w, page_h, fill=1, stroke=0)

    margin = 16 * mm
    c.setStrokeColor(NAVY)
    c.setLineWidth(1.6)
    c.rect(margin, margin, page_w - 2 * margin, page_h - 2 * margin, fill=0, stroke=1)
    c.setStrokeColor(HAIRLINE)
    c.setLineWidth(0.6)
    c.rect(margin + 4 * mm, margin + 4 * mm, page_w - 2 * (margin + 4 * mm),
           page_h - 2 * (margin + 4 * mm), fill=0, stroke=1)

    y = page_h - margin - 16 * mm

    # ---- header ---------------------------------------------------------------
    c.setFillColor(NAVY)
    c.setFont("Helvetica-Bold", 10)
    c.drawCentredString(page_w / 2, y, cfg.ORG_NAME.upper())
    y -= 5 * mm
    c.setFont("Helvetica", 8.5)
    c.setFillColor(SLATE)
    c.drawCentredString(page_w / 2, y, cfg.APP_TAGLINE)
    y -= 12 * mm

    seal_color = _SEAL_COLOR.get(cert["cert_type"], SIGNAL_BLUE)
    title = cfg.CERT_TYPE_LABELS[cert["cert_type"]].upper()
    c.setFillColor(seal_color)
    c.setFont("Times-Bold", 22)
    c.drawCentredString(page_w / 2, y, title)
    y -= 6 * mm
    c.setStrokeColor(seal_color)
    c.setLineWidth(1)
    c.line(page_w / 2 - 45 * mm, y, page_w / 2 + 45 * mm, y)
    y -= 12 * mm

    # ---- certificate meta -------------------------------------------------
    c.setFont("Courier-Bold", 11)
    c.setFillColor(INK)
    c.drawCentredString(page_w / 2, y, cert["cert_number"])
    y -= 6 * mm
    c.setFont("Helvetica", 9.5)
    c.setFillColor(SLATE)
    c.drawCentredString(
        page_w / 2, y,
        f"Issued {cert['issue_date'].strftime('%d %B %Y')}   ·   "
        f"Valid until {cert['expiry_date'].strftime('%d %B %Y')}"
    )
    y -= 16 * mm

    # ---- vessel block -------------------------------------------------------
    c.setFont("Times-Bold", 15)
    c.setFillColor(INK)
    c.drawCentredString(page_w / 2, y, vessel["name"])
    y -= 10 * mm

    rows = [
        ("IMO / Reg. No.", vessel.get("imo_number") or "—"),
        ("Flag State", vessel.get("flag_state") or "—"),
        ("Owner", vessel.get("owner_company") or "—"),
        ("Class Notation", vessel.get("current_class") or cfg.ORG_NAME),
    ]
    label_x = page_w / 2 - 55 * mm
    value_x = page_w / 2 - 5 * mm
    c.setFont("Helvetica", 9.5)
    for label, value in rows:
        c.setFillColor(SLATE)
        c.drawString(label_x, y, label)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 9.5)
        c.drawString(value_x, y, str(value))
        c.setFont("Helvetica", 9.5)
        y -= 6.4 * mm

    y -= 10 * mm

    # ---- formal certifying statement ------------------------------------------
    c.setStrokeColor(seal_color)
    c.setLineWidth(0.6)
    c.line(page_w / 2 - 30 * mm, y, page_w / 2 + 30 * mm, y)
    y -= 9 * mm

    statement = (
        f"This is to certify that the vessel named above has been surveyed in "
        f"accordance with the applicable Rules and Regulations of {cfg.ORG_NAME} and "
        f"found to comply with the requirements for the class notation and character "
        f"of classification shown, subject to any conditions stated on this certificate."
    )
    y = _wrap_centred(c, statement, "Times-Italic", 10, page_w - 2 * margin - 50 * mm,
                       page_w / 2, y, 5.6 * mm, INK)
    y -= 8 * mm

    # ---- pending observations (interim only) ---------------------------------
    pending = cert.get("pending_observations") or []
    if pending:
        c.setFont("Helvetica-Bold", 9.5)
        c.setFillColor(AMBER)
        c.drawString(label_x, y, f"OUTSTANDING OBSERVATIONS ({len(pending)})")
        y -= 6 * mm
        c.setFont("Helvetica", 8.8)
        c.setFillColor(INK)
        for item in pending:
            text = f"–  {item}"
            c.drawString(label_x, y, text[:96])
            y -= 5.2 * mm
        y -= 4 * mm
        c.setFont("Helvetica-Oblique", 8.3)
        c.setFillColor(SLATE)
        c.drawString(label_x, y,
                      "This certificate remains valid only until the outstanding items above are cleared")
        y -= 4.6 * mm
        c.drawString(label_x, y, "and a follow-up survey confirms closure, or until the expiry date shown above.")
        y -= 10 * mm
    else:
        c.setFont("Helvetica-Oblique", 8.8)
        c.setFillColor(SLATE)
        c.drawCentredString(page_w / 2, y, "No outstanding observations recorded against this vessel at time of issue.")
        y -= 10 * mm

    # ---- decorative rule above the signature block ----------------------------
    c.setStrokeColor(HAIRLINE)
    c.setLineWidth(0.6)
    c.line(margin + 10 * mm, y, page_w - margin - 10 * mm, y)

    # ---- seal ------------------------------------------------------------------
    seal_cx, seal_cy, seal_r = page_w - margin - 30 * mm, margin + 30 * mm, 15 * mm
    c.setStrokeColor(seal_color)
    c.setLineWidth(1.6)
    c.circle(seal_cx, seal_cy, seal_r, fill=0, stroke=1)
    c.setDash(2, 2)
    c.setLineWidth(0.8)
    c.circle(seal_cx, seal_cy, seal_r - 3 * mm, fill=0, stroke=1)
    c.setDash()
    c.setFont("Times-Bold", 8)
    c.setFillColor(seal_color)
    notation = {cfg.CERT_TYPE_CLASS: "CLASS", cfg.CERT_TYPE_INTERIM: "INTERIM",
                cfg.CERT_TYPE_NSC: "NEW BUILD"}.get(cert["cert_type"], "CLASS")
    c.drawCentredString(seal_cx, seal_cy + 2, notation)
    c.setFont("Helvetica", 6.5)
    c.drawCentredString(seal_cx, seal_cy - 6, cert["issue_date"].strftime("%Y"))

    # ---- signature block -----------------------------------------------------
    sig_y = margin + 22 * mm
    c.setStrokeColor(HAIRLINE)
    c.setLineWidth(0.8)
    c.line(margin + 14 * mm, sig_y, margin + 74 * mm, sig_y)
    c.setFont("Helvetica-Bold", 9)
    c.setFillColor(INK)
    c.drawString(margin + 14 * mm, sig_y - 5 * mm, issuer_name)
    c.setFont("Helvetica", 8)
    c.setFillColor(SLATE)
    c.drawString(margin + 14 * mm, sig_y - 9.5 * mm, "GM Classification · Authorised Representative")

    c.setFont("Helvetica", 7)
    c.setFillColor(SLATE)
    c.drawString(margin + 14 * mm, margin + 8 * mm,
                 f"Digitally issued via {cfg.APP_NAME} — verify at registry lookup with certificate number above.")

    c.showPage()
    c.save()
    buf.seek(0)
    return buf.getvalue()
