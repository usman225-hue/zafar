# EPAS v2.8 Final Gap Closure Matrix

| Gap | v2.8 closure | Evidence |
|---|---|---|
| In-Service closes after cycle 1 | Closed | Persistent phase gate + `survey_cycle_instances` |
| Cycle 2+ RFI blocked | Closed | persistent phase + guided schedule RFI RPC |
| Service schedule sync security | Closed | service-role-only sync |
| Vessel status mutation security | Closed | service/service-manager separation |
| Cycle completion security | Closed | GM/DM + project membership |
| Live scheduler implementation | Implemented | `epas_scheduler_tick_v28` + cron deployment |
| Silent 12-month fallback | Closed for new configuration | explicit basis interval/date required |
| Survey due vs certificate expiry | Closed | `due_basis_date` + explicit schedule basis |
| Schedule basis traceability | Closed | snapshot + history + basis fingerprint |
| Package fingerprint ack | Closed | package version/fingerprint/scope version/status |
| Scope amendment cascade | Closed | invalidates scope ack/package/checklist/execution basis |
| Checklist fingerprint | Closed | versioned definition + instance fingerprint |
| Assignment acceptance fingerprint | Closed | `survey_assignment_acknowledgements` |
| Revision impact evidence | Closed | shared/current rev + SHA comparison fingerprint |
| Execution basis anchoring | Closed | versioned frozen basis |
| Survey report hash | Closed | report SHA + completion + execution basis version |
| Certificate report/declaration freeze | Closed | package snapshot and hashes |
| Certificate ACK invalidation by package change | Closed by package superseding/sha match gate | active package + exact acknowledgement matching |
| Evidence exact observation binding | Closed | corrective-action/observation relationship required |
| Notification phase boundary | Closed | phase/role policy |
| Project-scoped schedule reads | Closed | `epas_survey_schedule_queue_v28` |
| Streamlit actor-free role routing | Implemented | authenticated role router |
| Live RLS/Storage acceptance | Deployment acceptance item | readiness matrix tracks live proof |
| Live Cron acceptance | Deployment acceptance item | readiness matrix + cron deployment |

## Remaining distinction

v2.8 treats the remaining live-environment checks as **acceptance evidence**, not missing product features. The ZIP contains the production mechanisms, the scheduler deployment SQL, the Streamlit runtime surface, and the role acceptance metadata required to complete those checks in the real Supabase environment.
