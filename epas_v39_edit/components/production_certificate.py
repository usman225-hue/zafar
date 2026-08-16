"""Controlled certificate PDF generation/upload for the production GM workflow."""
from __future__ import annotations
from io import BytesIO
from reportlab.lib.pagesizes import A4
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.enums import TA_CENTER
import hashlib
from database import production_queries as pq


def build_pdf(cert: dict, project: dict | None, vessel: dict | None) -> bytes:
    buf=BytesIO()
    doc=SimpleDocTemplate(buf,pagesize=A4,rightMargin=42,leftMargin=42,topMargin=42,bottomMargin=42)
    styles=getSampleStyleSheet()
    title=styles['Title']; title.alignment=TA_CENTER
    story=[Paragraph('CLASSIFICATION AUTHORITY',title),Spacer(1,14),Paragraph(cert['cert_type'].replace('_',' ').upper(),styles['Heading2']),Spacer(1,12)]
    data=[
        ['Certificate No.',cert['cert_number']],
        ['Project',(project or {}).get('project_code','—')],
        ['Vessel',(vessel or {}).get('name','—')],
        ['IMO No.',(vessel or {}).get('imo_number','—')],
        ['Flag',(vessel or {}).get('flag_state','—')],
        ['Issue Date',str(cert.get('issue_date',''))],
        ['Expiry Date',str(cert.get('expiry_date',''))],
    ]
    t=Table(data,colWidths=[145,330]); t.setStyle(TableStyle([('GRID',(0,0),(-1,-1),0.5,colors.grey),('FONTNAME',(0,0),(0,-1),'Helvetica-Bold'),('VALIGN',(0,0),(-1,-1),'TOP'),('PADDING',(0,0),(-1,-1),7)]))
    story += [t,Spacer(1,20),Paragraph('This controlled certificate was issued through the authenticated EPAS GM workflow and is subject to the Classification Authority rules and conditions.',styles['BodyText'])]
    doc.build(story)
    return buf.getvalue()


def upload_certificate_pdf(cert: dict, project: dict | None, vessel: dict | None) -> str:
    pdf=build_pdf(cert,project,vessel)
    project_id=cert['project_id']
    path=f"projects/{project_id}/certificates/{cert['cert_number']}.pdf"
    sha256=hashlib.sha256(pdf).hexdigest()
    # upload_with_cleanup / register_certificate_pdf_v33 are encapsulated by pq.upload_certificate_pdf_v36 (canonical transactional helper).
    pq.upload_certificate_pdf_v36(cert['id'], project_id, cert['cert_number'], pdf)
    return path
