from __future__ import annotations
from datetime import date
import streamlit as st
from database import production_queries as pq


def _safe(fn):
    try:
        return fn()
    except Exception as exc:
        ref = abs(hash(f'survey_lifecycle:{type(exc).__name__}')) % 100000
        st.error(f'Workflow control could not be loaded. Reference EPAS-{ref:05d}.')
        return None


def render(project_id: str | None = None):
    role = (pq.profile() or {}).get('role')
    st.markdown('### EPAS v3.6 Survey Lifecycle Control')
    st.caption('Persistent In-Service phase, explicit cycle state, exact package fingerprints, and role-scoped initiation.')

    rows = _safe(lambda: pq.schedule_bundle_v36(project_id)) or []
    if not rows:
        st.info('No survey schedules are currently available for the selected project.')
        return

    for row in rows:
        phase = row.get('phase')
        state = row.get('status')
        color = '🔴' if state == 'OVERDUE' else ('🟠' if state in ('DUE','DUE_SOON') else '🟢')
        st.markdown(f"{color} **{row.get('vessel_name','Vessel')}** · {str(phase).replace('_',' ').title()} · Cycle {row.get('cycle_number',1)}")
        st.caption(f"Due {row.get('next_due_date')} · window {row.get('window_start')} → {row.get('window_end')} · {state} · RFI {row.get('rfi_id') or '—'}")
        st.caption(f"Schedule basis: {row.get('due_basis') or '—'} · reference: {row.get('due_basis_reference') or '—'} · config: {row.get('schedule_config_status') or '—'}")
        if phase == 'in_service' and row.get('rfi_id') and role in ('surveyor','dm','gm'):
            gate = _safe(lambda: pq.survey_start_gate_v36(str(row['rfi_id']))) or {}
            st.markdown('**Survey Start Readiness**')
            checks = [
                ('Assignment accepted', gate.get('assignment_accepted', False)),
                ('Scope acknowledged', gate.get('scope_acknowledged', False)),
                ('Drawing package acknowledged', gate.get('package_acknowledged', False)),
                ('Checklist complete', gate.get('checklist_ready', False)),
                ('Revision impact clear', gate.get('revision_impact_clear', False)),
                ('Execution basis frozen', gate.get('execution_basis_frozen', False)),
            ]
            for label, ok in checks:
                st.write(('✓ ' if ok else '○ ') + label)
            if gate.get('ready'):
                st.success('READY TO START SURVEY')
            else:
                st.warning('Survey execution remains blocked until every readiness gate is satisfied.')

        if phase == 'in_service' and role in ('owner','ship_management') and not row.get('rfi_id'):
            if row.get('schedule_config_status') != 'CONFIGURED':
                st.warning('This cycle cannot be initiated yet. GM/DM must first configure an explicit survey interval and schedule basis.')
                continue
            if state not in ('SCHEDULED','DUE_SOON','DUE','OVERDUE'):
                continue
            with st.expander('Initiate this In-Service survey cycle', expanded=False):
                survey_type = st.text_input('Survey type', value=row.get('survey_type') or 'In-Service Survey', key=f'v36_type_{row["schedule_id"]}')
                requested = st.date_input('Requested survey date', value=row.get('next_due_date') or date.today(), key=f'v36_date_{row["schedule_id"]}')
                priority = st.selectbox('Priority', ['low','medium','high'], index=1, key=f'v36_pri_{row["schedule_id"]}')
                scope = st.text_area('Survey scope / request', key=f'v36_scope_{row["schedule_id"]}')
                if st.button('Create In-Service RFI for this cycle →', key=f'v36_create_{row["schedule_id"]}', type='primary'):
                    if not scope.strip():
                        st.error('Survey scope is required.')
                    elif _safe(lambda: pq.create_scheduled_in_service_rfi(row['schedule_id'], survey_type, requested, priority, scope)):
                        st.success('RFI created and linked to the current In-Service cycle.')
                        st.rerun()

        if phase == 'in_service' and role in ('gm','dm') and row.get('schedule_config_status') in ('REVIEW_REQUIRED','CONFIGURATION_REQUIRED'):
            with st.expander('Configure In-Service schedule basis', expanded=False):
                interval_default = int(row.get('survey_interval_months')) if row.get('survey_interval_months') else None
                interval = st.number_input('Survey interval (months)', min_value=1, max_value=120, value=interval_default or 1, key=f'v36_interval_{row["schedule_id"]}')
                basis_options = ['CERTIFICATE_EXPIRY','CLASS_SURVEY_PROGRAM','REGULATORY_REQUIREMENT','GM_APPROVED_PROGRAM','MANUAL_APPROVED']
                basis = st.selectbox('Schedule basis', basis_options, index=basis_options.index(row.get('due_basis')) if row.get('due_basis') in basis_options else 0, key=f'v36_basis_{row["schedule_id"]}')
                reference = st.text_input('Basis reference', value=row.get('due_basis_reference') or '', key=f'v36_ref_{row["schedule_id"]}')
                basis_default = row.get('due_basis_date')
                basis_date = st.date_input('Schedule basis date', value=date.fromisoformat(basis_default) if basis_default else date.today(), key=f'v36_basis_date_{row["schedule_id"]}')
                before = st.number_input('Window before due (days)', min_value=1, max_value=365, value=90, key=f'v36_before_{row["schedule_id"]}')
                after = st.number_input('Window after due (days)', min_value=1, max_value=365, value=30, key=f'v36_after_{row["schedule_id"]}')
                if st.button('Save schedule basis →', key=f'v36_save_{row["schedule_id"]}', type='primary'):
                    if not reference.strip():
                        st.error('Basis reference is mandatory.')
                    elif _safe(lambda: pq.set_in_service_schedule_basis_v36(str(row['vessel_id']), int(interval), basis, reference, basis_date, int(before), int(after))):
                        st.success('Schedule configured. The next scheduler cycle will recalculate due/window state.')
                        st.rerun()


def render_role_acceptance():
    role = (pq.profile() or {}).get('role')
    if role not in ('gm','dm'):
        return
    cases = _safe(pq.v36_lifecycle_cases) or []
    if not cases:
        return
    with st.expander('v3.6 Workflow Acceptance Matrix', expanded=False):
        for c in cases:
            marker = 'NEGATIVE' if c.get('negative') else 'POSITIVE'
            st.write(f"**{c.get('priority')} · {marker} · {c.get('case_code')}** — {c.get('expected_result')}")
