"""Send queued EPAS stakeholder notifications.

Run this as a cron/container worker with:
SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM.
The service-role key must never be placed in Streamlit client secrets.
"""
from __future__ import annotations
import os
import smtplib
from datetime import datetime, timezone
from email.message import EmailMessage
from supabase import create_client


def main() -> int:
    url=os.environ['SUPABASE_URL']; service_key=os.environ['SUPABASE_SERVICE_ROLE_KEY']
    host=os.environ['SMTP_HOST']; port=int(os.getenv('SMTP_PORT','587'))
    username=os.environ['SMTP_USERNAME']; password=os.environ['SMTP_PASSWORD']; sender=os.environ['SMTP_FROM']
    db=create_client(url,service_key)
    rows=db.table('notification_outbox').select('*').eq('status','queued').order('created_at').limit(50).execute().data
    sent=0
    with smtplib.SMTP(host,port,timeout=30) as smtp:
        smtp.starttls(); smtp.login(username,password)
        for row in rows:
            msg=EmailMessage(); msg['From']=sender; msg['To']=row['recipient_email']; msg['Subject']=row['subject']; msg.set_content(row['body'])
            try:
                smtp.send_message(msg)
                db.table('notification_outbox').update({'status':'sent','sent_at':datetime.now(timezone.utc).isoformat()}).eq('id',row['id']).execute()
                sent+=1
            except Exception as exc:
                db.table('notification_outbox').update({'status':'failed','error_message':str(exc)}).eq('id',row['id']).execute()
    print(f"EPAS email worker: {sent} notification(s) sent")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
