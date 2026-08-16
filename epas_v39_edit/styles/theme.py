"""
EPAS · Design System
---------------------
DESIGN PLAN (kept here deliberately, next to the CSS it governs)

Subject: a classification-society back office — the software equivalent
of a ship's registry ledger. The audience is a General Manager who signs
things: allocations, approvals, certificates. The page's one job is to
make "what needs my signature right now" unmissable, and everything else
calmly legible.

Colour (6 named hexes):
    #0E2340  navy      — authority, the sidebar's spine, headers
    #1B4B91  signal     — primary actions, the colour of "go do this"
    #F5F2EA  parchment  — the paper the whole app sits on
    #1E6E4C  starboard  — success / class certificate issued
    #B23A2E  port       — danger / rejected / expired
    #A6461B  rust       — reserved ONLY for "needs the GM's signature" —
                          no other state in the app uses this hue, so it
                          reads as a single unmistakable signal colour.
Amber (#B9791E) and teal (#146B72) round out warning/info but are
deliberately less saturated than rust, so the GM's actionable queue
never competes visually with routine "in progress" chatter.

Type: 'Fraunces' (a registry serif with ink-trap detailing) carries
vessel names, page titles and certificate numbers — anywhere the text
itself is the record of something official. 'Inter' runs the UI and
dense tables. 'IBM Plex Mono' sets every reference code (RFI-2027-014,
CC-2027-...) — mono numerals make codes scannable the way a ledger
column of serial numbers is scannable.

Signature element: the certificate "seal" — a two-ring circular badge
with the class notation set in Fraunces at its centre — used ONLY on
issued certificates, never decoratively elsewhere. Everything else
(cards, tables, the stage-track stepper) stays flat, hairline-bordered
and quiet, so the seal is the one moment of ceremony in the app —
appropriate, since issuing a certificate is the one ceremonial act a
classification authority performs.
"""

from __future__ import annotations

import streamlit as st

CSS = """

:root {
    --navy-950: #03131F;
    --navy-900: #04263A;
    --navy-800: #063C4F;
    --navy-700: #0B5568;
    --blue-600: #0A5B7A;
    --blue-500: #167FA3;
    --blue-100: #E6F4F7;

    --parchment: #F4F7F8;
    --paper: #FFFFFF;
    --paper-soft: #F7FAFB;

    --ink-900: #161F2C;
    --ink-700: #33404F;
    --ink-600: #4B5768;
    --ink-400: #8891A0;

    --hairline: #E3E7EE;
    --hairline-warm: #E7E2D3;

    --green-700: #0B8F62;
    --green-100: #E6F6F0;
    --red-700: #B23A2E;
    --red-100: #F8E5E2;
    --amber-700: #B9791E;
    --amber-100: #FBF0DD;
    --teal-700: #0A7485;
    --teal-100: #E1F0F1;
    --rust-700: #A6461B;
    --rust-100: #F7E1D2;
    --neutral-700: #55607A;
    --neutral-100: #ECEEF2;

    --radius-sm: 6px;
    --radius-md: 10px;
    --radius-lg: 16px;
    --shadow-card: 0 1px 2px rgba(14, 35, 64, 0.04), 0 1px 12px rgba(14, 35, 64, 0.05);
    --font-display: Georgia, 'Times New Roman', serif;
    --font-body: Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
    --font-mono: 'SFMono-Regular', Consolas, 'Liberation Mono', monospace;
}

/* ============================= BASE ============================= */
html, body, [class*="css"] { font-family: var(--font-body); color: var(--ink-900); }
[data-testid="stAppViewContainer"] { background: var(--parchment); }
[data-testid="stHeader"] { background: transparent; height: 0; }
[data-testid="stToolbar"] { display: none; }
.block-container { padding-top: 1.6rem; padding-bottom: 3rem; max-width: 1320px; }
#MainMenu, footer { visibility: hidden; }

::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: #C9CFD9; border-radius: 8px; }
::-webkit-scrollbar-thumb:hover { background: #AFB7C4; }

*:focus-visible { outline: 2px solid var(--blue-500); outline-offset: 2px; }

/* ============================= SIDEBAR ============================= */
[data-testid="stSidebar"] {
    background: linear-gradient(180deg, var(--navy-900) 0%, var(--navy-950) 100%);
    border-right: 1px solid var(--navy-950);
    min-width: 290px !important;
}
[data-testid="stSidebar"] > div:first-child { padding: 1.4rem 1.1rem 1.2rem; }
[data-testid="stSidebar"] * { color: #E8EDF6; }
[data-testid="stSidebar"] hr { border-color: rgba(255,255,255,0.10); margin: 1rem 0; }

.brand-row { display: flex; align-items: center; gap: 10px; margin-bottom: 2px; }
.brand-mark {
    width: 34px; height: 34px; border-radius: 9px;
    background: radial-gradient(circle at 30% 25%, var(--blue-500), var(--blue-600) 65%);
    display: flex; align-items: center; justify-content: center;
    font-family: var(--font-display); font-weight: 600; font-size: 15px; color: white;
    box-shadow: 0 2px 6px rgba(0,0,0,0.35);
    flex-shrink: 0;
}
.brand-name { font-family: var(--font-display); font-size: 20px; font-weight: 600; letter-spacing: 0.2px; line-height: 1.1; }
.brand-tagline { font-size: 10.5px; color: #97A5BC; letter-spacing: 0.5px; text-transform: uppercase; margin-top: 2px; }

.gm-card {
    display: flex; align-items: center; gap: 10px;
    background: rgba(255,255,255,0.045);
    border: 1px solid rgba(255,255,255,0.09);
    border-radius: var(--radius-md);
    padding: 10px 12px; margin: 16px 0 6px;
}
.gm-avatar {
    width: 34px; height: 34px; border-radius: 50%;
    background: var(--blue-600); color: white; font-weight: 700; font-size: 12.5px;
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
    font-family: var(--font-body);
}
.gm-name { font-size: 13.5px; font-weight: 600; line-height: 1.25; }
.gm-role { font-size: 11px; color: #9AA8BE; }

.conn-pill {
    display: inline-flex; align-items: center; gap: 6px;
    font-size: 10.5px; font-weight: 500; letter-spacing: 0.2px;
    padding: 4px 9px; border-radius: 999px; margin: 8px 0 4px;
}
.conn-pill::before { content: ""; width: 6px; height: 6px; border-radius: 50%; }
.conn-pill--demo { background: rgba(185,121,30,0.18); color: #F2C588; }
.conn-pill--demo::before { background: #F2C588; }
.conn-pill--live { background: rgba(30,110,76,0.20); color: #7FE0B4; }
.conn-pill--live::before { background: #7FE0B4; }

.nav-section-label {
    font-size: 10.5px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;
    color: #6F7F9C; margin: 18px 4px 6px;
}
.nav-item-active {
    display: flex; align-items: center; gap: 10px;
    background: rgba(43,99,179,0.28);
    border: 1px solid rgba(88,140,214,0.4);
    border-radius: var(--radius-sm);
    padding: 8px 10px; margin-bottom: 3px;
    font-size: 13.5px; font-weight: 600; color: #FFFFFF !important;
}
.nav-item-active .nav-icon { font-size: 15px; }
.nav-badge {
    margin-left: auto; background: var(--rust-700); color: white;
    font-size: 10px; font-weight: 700; border-radius: 999px;
    padding: 1px 7px; font-family: var(--font-mono);
}

[data-testid="stSidebar"] div[data-testid="stVerticalBlock"] .stButton > button {
    background: transparent; border: 1px solid transparent; color: #C6D1E3 !important;
    text-align: left; justify-content: flex-start; font-weight: 500; font-size: 13.5px;
    padding: 8px 10px; border-radius: var(--radius-sm); width: 100%; margin-bottom: 3px;
    box-shadow: none; transition: background 0.15s ease, border-color 0.15s ease;
}
[data-testid="stSidebar"] .stButton > button:hover {
    background: rgba(255,255,255,0.07); border-color: rgba(255,255,255,0.10); color: #FFFFFF !important;
}
[data-testid="stSidebar"] .stButton > button p { color: inherit !important; font-size: 13.5px; }

.ledger-rail { margin-top: 4px; }
.ledger-item { display: flex; gap: 9px; padding: 7px 2px; position: relative; }
.ledger-item::before {
    content: ""; position: absolute; left: 5.5px; top: 20px; bottom: -7px; width: 1px;
    background: rgba(255,255,255,0.12);
}
.ledger-item:last-child::before { display: none; }
.ledger-dot { width: 11px; height: 11px; border-radius: 50%; margin-top: 2px; flex-shrink: 0; border: 2px solid var(--navy-900); }
.ledger-text { font-size: 11.5px; line-height: 1.4; color: #B7C2D6; }
.ledger-text b { color: #EAEFF7; font-weight: 600; }
.ledger-time { font-size: 10px; color: #6F7F9C; font-family: var(--font-mono); }

/* ============================= TYPOGRAPHY ============================= */
.eyebrow {
    font-family: var(--font-mono); font-size: 11px; font-weight: 500;
    letter-spacing: 1.2px; text-transform: uppercase; color: var(--blue-600); margin-bottom: 4px;
}
.page-title { font-family: var(--font-display); font-weight: 600; font-size: 30px; color: var(--ink-900); line-height: 1.15; margin: 0; }
.page-sub { color: var(--ink-600); font-size: 14px; margin-top: 5px; }
.section-title { font-family: var(--font-display); font-weight: 600; font-size: 18px; color: var(--ink-900); margin: 0; }
.section-caption { color: var(--ink-600); font-size: 12.5px; margin-top: 2px; }
.mono { font-family: var(--font-mono); }
.divider-hr { border: none; border-top: 1px solid var(--hairline-warm); margin: 22px 0; }

/* ============================= CARDS ============================= */
.card {
    background: var(--paper); border: 1px solid var(--hairline);
    border-radius: var(--radius-lg); padding: 18px 20px;
    box-shadow: var(--shadow-card); margin-bottom: 14px;
}
.card--soft { background: var(--paper-soft); }
.card--flush { padding: 0; overflow: hidden; }
.card-header-row { display: flex; align-items: flex-start; justify-content: space-between; margin-bottom: 10px; }

.empty-state {
    text-align: center; padding: 34px 20px; color: var(--ink-400);
    background: var(--paper-soft); border: 1px dashed var(--hairline); border-radius: var(--radius-md);
}
.empty-state .empty-icon { font-size: 26px; margin-bottom: 8px; opacity: 0.7; }
.empty-state .empty-title { font-weight: 600; color: var(--ink-600); font-size: 13.5px; }
.empty-state .empty-sub { font-size: 12px; margin-top: 3px; }

/* ============================= KPI TILES ============================= */
.kpi-tile {
    background: var(--paper); border: 1px solid var(--hairline); border-radius: var(--radius-lg);
    padding: 16px 18px 14px; box-shadow: var(--shadow-card); position: relative; overflow: hidden;
    height: 100%;
}
.kpi-tile::before { content: ""; position: absolute; top: 0; left: 0; right: 0; height: 3px; }
.kpi-tile--blue::before { background: var(--blue-600); }
.kpi-tile--rust::before { background: var(--rust-700); }
.kpi-tile--green::before { background: var(--green-700); }
.kpi-tile--amber::before { background: var(--amber-700); }
.kpi-label { font-size: 11px; font-weight: 600; letter-spacing: 0.6px; text-transform: uppercase; color: var(--ink-600); }
.kpi-value { font-family: var(--font-display); font-size: 34px; font-weight: 600; color: var(--ink-900); line-height: 1.2; margin-top: 2px; }
.kpi-foot { font-size: 11.5px; color: var(--ink-400); margin-top: 4px; font-family: var(--font-mono); }
.kpi-foot--rust { color: var(--rust-700); font-weight: 600; }

/* ============================= BADGES ============================= */
.badge {
    display: inline-flex; align-items: center; font-size: 11px; font-weight: 600;
    padding: 3px 9px; border-radius: 999px; letter-spacing: 0.15px; white-space: nowrap;
    line-height: 1.5;
}
.badge--success { background: var(--green-100); color: var(--green-700); }
.badge--danger  { background: var(--red-100); color: var(--red-700); }
.badge--warning { background: var(--amber-100); color: var(--amber-700); }
.badge--info    { background: var(--teal-100); color: var(--teal-700); }
.badge--action  { background: var(--rust-100); color: var(--rust-700); }
.badge--neutral { background: var(--neutral-100); color: var(--neutral-700); }

/* ============================= STAGE TRACK ============================= */
.stage-track { display: flex; align-items: center; flex-wrap: wrap; gap: 0; margin: 10px 0 4px; }
.stage-step { display: flex; align-items: center; gap: 6px; }
.stage-step-label { font-size: 10.5px; color: var(--ink-400); white-space: nowrap; }
.stage-dot { width: 9px; height: 9px; border-radius: 50%; background: var(--hairline); flex-shrink: 0; }
.stage-step--done .stage-dot { background: var(--green-700); }
.stage-step--done .stage-step-label { color: var(--ink-600); }
.stage-step--current .stage-dot { background: var(--blue-600); box-shadow: 0 0 0 3px var(--blue-100); }
.stage-step--current .stage-step-label { color: var(--blue-600); font-weight: 700; }
.stage-step--current-warn .stage-dot { background: var(--amber-700); box-shadow: 0 0 0 3px var(--amber-100); }
.stage-step--current-warn .stage-step-label { color: var(--amber-700); font-weight: 700; }
.stage-step--current-danger .stage-dot { background: var(--red-700); box-shadow: 0 0 0 3px var(--red-100); }
.stage-step--current-danger .stage-step-label { color: var(--red-700); font-weight: 700; }
.stage-connector { width: 18px; height: 1px; background: var(--hairline); margin: 0 4px; }
.stage-connector--done { background: var(--green-700); opacity: 0.4; }

/* ============================= RFI / LIST ROW CARDS ============================= */
.row-card {
    background: var(--paper); border: 1px solid var(--hairline); border-left: 3px solid var(--hairline);
    border-radius: var(--radius-md); padding: 13px 16px; margin-bottom: 10px;
}
.row-card--priority-high { border-left-color: var(--rust-700); }
.row-card--priority-medium { border-left-color: var(--amber-700); }
.row-card--priority-low { border-left-color: var(--hairline); }
.row-title-line { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.row-code { font-family: var(--font-mono); font-size: 12px; color: var(--ink-400); }
.row-vessel { font-weight: 700; font-size: 14.5px; color: var(--ink-900); font-family: var(--font-display); }
.row-meta { font-size: 12px; color: var(--ink-600); margin-top: 3px; }
.row-meta b { color: var(--ink-700); }

/* ============================= CERTIFICATE SEAL (signature element) ============================= */
.seal-card {
    display: flex; gap: 16px; align-items: center; background: var(--paper);
    border: 1px solid var(--hairline); border-radius: var(--radius-lg); padding: 16px 18px;
    box-shadow: var(--shadow-card); margin-bottom: 12px;
}
.seal {
    width: 64px; height: 64px; border-radius: 50%; flex-shrink: 0;
    display: flex; align-items: center; justify-content: center; position: relative;
    border: 2px solid var(--seal-color, var(--blue-600));
}
.seal::before {
    content: ""; position: absolute; inset: 5px; border-radius: 50%;
    border: 1px dashed var(--seal-color, var(--blue-600)); opacity: 0.55;
}
.seal-code { font-family: var(--font-display); font-weight: 700; font-size: 13px; color: var(--seal-color, var(--blue-600)); }
.seal-cert-number { font-family: var(--font-mono); font-size: 13px; font-weight: 600; color: var(--ink-900); }
.seal-cert-type { font-family: var(--font-display); font-size: 16px; font-weight: 600; color: var(--ink-900); margin-top: 1px; }
.seal-meta { font-size: 12px; color: var(--ink-600); margin-top: 4px; }

/* ============================= WIZARD RAIL ============================= */
.wizard-rail { display: flex; gap: 6px; margin-bottom: 22px; }
.wizard-step {
    flex: 1; padding: 10px 12px; border-radius: var(--radius-md); border: 1px solid var(--hairline);
    background: var(--paper-soft);
}
.wizard-step--done { background: var(--green-100); border-color: var(--green-700); }
.wizard-step--active { background: var(--blue-100); border-color: var(--blue-600); box-shadow: 0 0 0 2px rgba(27,75,145,0.12); }
.wizard-step-num { font-family: var(--font-mono); font-size: 10px; color: var(--ink-400); letter-spacing: 0.5px; }
.wizard-step--active .wizard-step-num { color: var(--blue-600); font-weight: 700; }
.wizard-step--done .wizard-step-num { color: var(--green-700); font-weight: 700; }
.wizard-step-label { font-size: 12px; font-weight: 600; color: var(--ink-700); margin-top: 2px; }



/* ============================= EPAS v3.2 UX HARDENING ============================= */
.epas-state-card {
    background: var(--paper); border: 1px solid var(--hairline); border-radius: var(--radius-lg);
    padding: 16px 18px; min-height: 128px; box-shadow: var(--shadow-card);
}
.epas-state-card--current { border-top: 3px solid var(--blue-600); }
.epas-state-card--warning { border-top: 3px solid var(--amber-700); }
.epas-state-card--action { border-top: 3px solid var(--rust-700); }
.epas-state-label { font-family: var(--font-mono); font-size: 10px; letter-spacing: .9px; font-weight: 700; color: var(--ink-400); }
.epas-state-title { font-family: var(--font-display); font-size: 17px; font-weight: 650; color: var(--ink-900); margin-top: 5px; }
.epas-state-copy { font-size: 12px; color: var(--ink-600); margin-top: 6px; line-height: 1.45; }
.epas-step-next { border-left: 3px solid var(--rust-700); padding: 8px 12px; background: var(--rust-100); border-radius: var(--radius-sm); }
.epas-error-reference { font-family: var(--font-mono); font-size: 11px; color: var(--ink-400); }

@media (max-width: 1100px) {
    .block-container { padding-left: 1rem; padding-right: 1rem; }
    .page-title { font-size: 26px; }
    .kpi-value { font-size: 28px; }
}
@media (max-width: 800px) {
    [data-testid="stSidebar"] { min-width: 230px !important; }
    .block-container { padding-top: 1rem; }
    .stage-track { gap: 5px; }
    .stage-connector { width: 10px; }
    .epas-state-card { min-height: auto; margin-bottom: 10px; }
    .seal-card { align-items: flex-start; }
}
@media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { scroll-behavior: auto !important; transition: none !important; animation: none !important; }
}

/* ============================= WIDGET OVERRIDES ============================= */
.stButton > button {
    border-radius: var(--radius-sm); font-weight: 600; font-size: 13.5px;
    border: 1px solid var(--hairline); padding: 0.45rem 1rem;
    transition: all 0.15s ease;
}
.stButton > button[kind="primary"] {
    background: var(--blue-600); border-color: var(--blue-600); color: white;
}
.stButton > button[kind="primary"]:hover { background: var(--navy-700); border-color: var(--navy-700); }
.stButton > button:not([kind="primary"]) { background: var(--paper); color: var(--ink-700); }
.stButton > button:not([kind="primary"]):hover { border-color: var(--blue-500); color: var(--blue-600); }

[data-testid="stTabs"] button[role="tab"] {
    font-family: var(--font-body); font-weight: 600; font-size: 13.5px; color: var(--ink-600);
}
[data-testid="stTabs"] button[aria-selected="true"] { color: var(--blue-600); }
[data-testid="stTabs"] [data-baseweb="tab-highlight"] { background-color: var(--blue-600) !important; height: 2.5px; }
[data-testid="stTabs"] [data-baseweb="tab-border"] { background-color: var(--hairline); }

[data-testid="stExpander"] { border: 1px solid var(--hairline); border-radius: var(--radius-md); background: var(--paper); }
[data-testid="stExpander"] summary { font-weight: 600; font-size: 13.5px; }

[data-testid="stDataFrame"] { border: 1px solid var(--hairline); border-radius: var(--radius-md); overflow: hidden; }

div[data-testid="stForm"] { border: 1px solid var(--hairline); border-radius: var(--radius-lg); background: var(--paper); padding: 18px 20px; }

div[role="dialog"] { border-radius: var(--radius-lg); }

[data-testid="stMetric"] { background: var(--paper); border: 1px solid var(--hairline); border-radius: var(--radius-md); padding: 10px 14px; }
[data-testid="stMetricLabel"] { font-size: 11.5px; color: var(--ink-600); }

hr { border-color: var(--hairline-warm); }

[data-testid="stTextInput"] input, [data-testid="stNumberInput"] input, [data-testid="stDateInput"] input,
[data-testid="stSelectbox"] div[data-baseweb="select"] > div, textarea {
    border-radius: var(--radius-sm) !important; border-color: var(--hairline) !important;
    font-size: 13.5px !important;
}

[data-testid="stProgress"] > div > div { background-color: var(--blue-600); }
"""



PSB_V361_CSS = r"""
/* =========================================================
   PSB v3.6.1 Premium Visual System
   ========================================================= */

:root {
  --psb-deep: #03131F;
  --psb-navy: #04263A;
  --psb-teal: #0A7485;
  --psb-cyan: #167FA3;
  --psb-green: #0B8F62;
  --psb-mint: #DFF5EC;
  --psb-gold: #D5A64A;
  --psb-paper: #FFFFFF;
  --psb-mist: #F4F7F8;
  --psb-line: #DCE8EC;
  --psb-text: #12222D;
  --psb-muted: #637680;
  --psb-shadow: 0 10px 30px rgba(3, 19, 31, .07);
}

[data-testid="stAppViewContainer"] {
  background:
    radial-gradient(circle at 90% 10%, rgba(10,116,133,.08), transparent 24%),
    linear-gradient(180deg, #F8FBFC 0%, #F1F5F6 100%);
}

.block-container {
  max-width: 1480px;
  padding-top: 1.05rem !important;
  padding-left: clamp(1rem, 2.3vw, 2.5rem) !important;
  padding-right: clamp(1rem, 2.3vw, 2.5rem) !important;
}

.psb-topbar {
  display:flex; align-items:center; justify-content:space-between; gap:16px;
  margin: 0 0 10px; padding: 10px 14px;
  background: rgba(255,255,255,.86);
  backdrop-filter: blur(14px);
  border:1px solid rgba(220,232,236,.95);
  border-radius:16px;
  box-shadow: var(--psb-shadow);
}
.psb-topbar__brand { display:flex; align-items:center; gap:11px; min-width:0; }
.psb-topbar__logo { width:42px; height:56px; object-fit:contain; border-radius:10px; background:#fff; padding:3px; }
.psb-topbar__org { font-size:13px; font-weight:800; letter-spacing:.65px; color:var(--psb-navy); }
.psb-topbar__product { margin-top:2px; color:var(--psb-muted); font-size:10.5px; letter-spacing:.25px; }
.psb-topbar__context { display:flex; align-items:center; gap:12px; }
.psb-user-block { display:flex; flex-direction:column; align-items:flex-end; }
.psb-user-block strong { font-size:12.5px; color:var(--psb-text); }
.psb-user-block span { font-size:10.5px; color:var(--psb-muted); }

.psb-role-pill {
  padding:6px 10px; border-radius:999px; font-size:10px; font-weight:800;
  text-transform:uppercase; letter-spacing:.65px; border:1px solid;
}
.psb-role-pill--gm { color:#7D5C10; background:#FFF8E6; border-color:#E8C982; }
.psb-role-pill--dm { color:#0B6875; background:#E9F8FA; border-color:#9EDDE5; }
.psb-role-pill--engineer { color:#0A5B7A; background:#EAF5FA; border-color:#ABD9E8; }
.psb-role-pill--surveyor { color:#0B7652; background:#E9F7F1; border-color:#AEE2CD; }
.psb-role-pill--designer { color:#8A5B10; background:#FFF7E8; border-color:#F0D28B; }
.psb-role-pill--shipmanagement { color:#604E87; background:#F2EDFB; border-color:#D4C5EC; }
.psb-role-pill--stakeholder { color:#435560; background:#F0F4F6; border-color:#CFDCE1; }

.psb-context-row {
  display:flex; justify-content:space-between; align-items:center; gap:16px;
  padding:4px 3px 12px; color:var(--psb-muted); font-size:10.5px;
}
.psb-context-label { display:inline-block; margin-right:8px; font-weight:800; letter-spacing:.7px; }
.psb-context-value { color:var(--psb-text); font-weight:650; }
.psb-secure-badge { color:#0B7652; font-weight:700; }

div[data-testid="stRadio"] > div {
  background: rgba(255,255,255,.72) !important;
  padding: 5px !important; border:1px solid var(--psb-line) !important;
  border-radius:14px !important; box-shadow: 0 4px 16px rgba(3,19,31,.035);
}
div[data-testid="stRadio"] label {
  padding: 7px 14px !important; border-radius:10px !important; color:var(--psb-muted) !important;
  font-weight:700 !important; font-size:11px !important;
}
div[data-testid="stRadio"] label:has(input:checked) {
  background:var(--psb-navy) !important; color:white !important;
}

.kpi-card {
  background:var(--psb-paper); border:1px solid var(--psb-line) !important;
  border-radius:14px !important; box-shadow:0 5px 18px rgba(3,19,31,.035);
  padding:15px !important; min-height:104px !important;
}
.kpi-label { font-size:10px !important; text-transform:uppercase; letter-spacing:.6px; color:var(--psb-muted) !important; font-weight:800; }
.kpi-value { font-size:27px !important; font-weight:800; color:var(--psb-navy) !important; line-height:1.1; margin-top:5px; }
.kpi-foot { font-size:10.5px !important; color:var(--psb-muted) !important; margin-top:5px; }

.epas-state-card {
  border-radius:14px !important; padding:14px 15px !important; background:rgba(255,255,255,.88) !important;
  box-shadow:0 6px 20px rgba(3,19,31,.04) !important;
}
.epas-state-card--current { border:1px solid #C8DDE4 !important; }
.epas-state-card--warning { border:1px solid #E8D6AA !important; }
.epas-state-card--action { border:1px solid #B7DCD1 !important; }
.epas-state-label { font-size:9px !important; letter-spacing:.8px; font-weight:850; color:var(--psb-muted) !important; }
.epas-state-title { margin-top:5px; font-size:15px !important; font-weight:800; color:var(--psb-text) !important; }
.epas-state-copy { margin-top:4px; font-size:10.5px !important; color:var(--psb-muted) !important; }

[data-testid="stExpander"] {
  border:1px solid var(--psb-line) !important;
  border-radius:14px !important; background:rgba(255,255,255,.72) !important;
}
[data-testid="stExpander"] details[open] { box-shadow:0 8px 26px rgba(3,19,31,.05); }

[data-testid="stForm"] {
  border:1px solid var(--psb-line) !important; border-radius:16px !important; background:#fff !important;
  box-shadow:var(--psb-shadow); padding:22px !important;
}

[data-testid="stFileUploader"] section {
  border:1px dashed #BFD5DB !important; border-radius:12px !important; background:#FBFEFF !important;
}

.stButton > button[kind="primary"] {
  background:linear-gradient(135deg, #0A7485, #0B8F62) !important;
  border:0 !important; box-shadow:0 7px 18px rgba(10,116,133,.18) !important;
}
.stButton > button[kind="secondary"] {
  border-color:#C9DCE2 !important; color:var(--psb-navy) !important;
}

.psb-login-hero {
  position:relative; overflow:hidden; min-height:625px;
  border-radius:22px; padding:38px 34px; display:flex; align-items:center;
  background:
    radial-gradient(circle at 28% 18%, rgba(16,135,138,.22), transparent 28%),
    radial-gradient(circle at 78% 78%, rgba(11,143,98,.14), transparent 30%),
    linear-gradient(145deg, #03131F 0%, #04263A 54%, #073B4D 100%);
  box-shadow:0 18px 50px rgba(3,19,31,.22);
}
.psb-login-hero__grid {
  position:absolute; inset:0; opacity:.20;
  background-image:
    linear-gradient(rgba(255,255,255,.06) 1px, transparent 1px),
    linear-gradient(90deg, rgba(255,255,255,.06) 1px, transparent 1px);
  background-size:32px 32px;
}
.psb-login-hero__content { position:relative; z-index:2; width:100%; text-align:center; color:white; }
.psb-login-logo-wrap {
  width:185px; height:220px; margin:0 auto 18px; padding:10px;
  display:flex; align-items:center; justify-content:center;
  background:rgba(255,255,255,.98); border-radius:26px;
  box-shadow:0 14px 40px rgba(0,0,0,.25);
}
.psb-login-logo { max-width:100%; max-height:100%; object-fit:contain; }
.psb-login-kicker { font-size:9px; letter-spacing:1.4px; font-weight:850; color:#B8DDE3; }
.psb-login-hero h1 { margin:8px 0 5px !important; color:white !important; font-size:33px !important; font-weight:850 !important; }
.psb-login-title { color:#BDE1E4; font-size:14px; margin:0; }
.psb-login-divider { width:72px; height:3px; margin:16px auto; border-radius:99px; background:linear-gradient(90deg,#0A7485,#0B8F62,#D5A64A); }
.psb-login-points { display:flex; justify-content:center; flex-wrap:wrap; gap:7px; margin-top:12px; }
.psb-login-points span { border:1px solid rgba(255,255,255,.14); padding:7px 10px; border-radius:999px; font-size:9.5px; color:#D4E9ED; background:rgba(255,255,255,.045); }
.psb-login-footer { margin-top:50px; font-size:10px; color:#8FAEB8; letter-spacing:.35px; }

.psb-login-panel {
  min-height:625px; display:flex; flex-direction:column; justify-content:center;
  padding:44px clamp(20px,5vw,60px); border:1px solid var(--psb-line); border-radius:22px;
  background:rgba(255,255,255,.92); box-shadow:0 18px 50px rgba(3,19,31,.08);
}
.psb-login-panel__kicker { color:var(--psb-teal); font-size:9px; font-weight:850; letter-spacing:1.25px; }
.psb-login-panel__title { color:var(--psb-navy); font-size:36px; font-weight:850; margin-top:9px; }
.psb-login-panel__copy { color:var(--psb-muted); font-size:12px; line-height:1.65; margin:8px 0 22px; }
.psb-security-chip { display:block; background:#F1F7F8; border:1px solid #D8E8EC; border-radius:999px; padding:7px 10px; font-size:9.5px; text-align:center; color:#31525D; }
.psb-login-help { margin-top:18px; font-size:10.5px; line-height:1.6; color:var(--psb-muted); }
.psb-login-bottom { margin:13px 2px 0; text-align:center; color:var(--psb-muted); font-size:10px; }

.brand-image { width:40px !important; height:50px !important; object-fit:contain; border-radius:9px; background:white; padding:2px; flex-shrink:0; }

.page-title { letter-spacing:-.45px !important; }
.eyebrow { color:var(--psb-teal) !important; font-weight:850 !important; letter-spacing:1.05px !important; }
@media (max-width: 900px) {
  .psb-topbar { align-items:flex-start; }
  .psb-topbar__context { flex-direction:column; align-items:flex-end; }
  .psb-login-hero, .psb-login-panel { min-height:560px; }
}
@media (max-width: 720px) {
  .psb-topbar { flex-direction:column; }
  .psb-topbar__context { width:100%; align-items:flex-start; }
  .psb-user-block { align-items:flex-start; }
  .psb-login-hero { min-height:520px; padding:28px 20px; }
  .psb-login-panel { min-height:auto; }
  .psb-login-logo-wrap { width:150px; height:175px; }
  .psb-login-hero h1 { font-size:27px !important; }
  div[data-testid="stRadio"] label { padding:7px 9px !important; font-size:10px !important; }
}
"""


PSB_V362_PROJECT_CSS = r"""
/* =========================================================
   PSB v3.6.2 Project Context Workspace
   ========================================================= */
.psb-project-header {
  display:flex; align-items:center; justify-content:space-between; gap:20px;
  padding:18px 20px; margin:4px 0 14px;
  border:1px solid var(--psb-line); border-radius:18px;
  background:linear-gradient(135deg, rgba(255,255,255,.96), rgba(239,248,249,.92));
  box-shadow:0 10px 28px rgba(3,19,31,.055);
}
.psb-project-header__identity { min-width:0; }
.psb-project-header__code { color:var(--psb-teal); font-size:10px; font-weight:850; letter-spacing:1px; text-transform:uppercase; }
.psb-project-header__name { color:var(--psb-navy); font-size:25px; font-weight:850; margin-top:3px; }
.psb-project-header__meta { color:var(--psb-muted); font-size:11px; margin-top:5px; }
.psb-project-header__metrics { display:flex; align-items:stretch; gap:7px; flex-wrap:wrap; justify-content:flex-end; }
.psb-project-header__metrics span:not(.psb-project-health) {
  min-width:78px; padding:7px 10px; border:1px solid var(--psb-line);
  border-radius:11px; background:#fff; text-align:center;
}
.psb-project-header__metrics b { display:block; color:var(--psb-navy); font-size:17px; }
.psb-project-header__metrics small { color:var(--psb-muted); font-size:8.5px; text-transform:uppercase; letter-spacing:.55px; font-weight:800; }
.psb-project-health { align-self:center; padding:10px 13px; border-radius:999px; font-size:9px; font-weight:850; text-transform:uppercase; letter-spacing:.7px; }
.psb-project-health--healthy { color:#0B7652; background:#E7F6EF; border:1px solid #A7DFC9; }
.psb-project-health--watch { color:#876213; background:#FFF7E4; border:1px solid #E9CF8A; }
.psb-project-health--attention { color:#A43C3C; background:#FFF0F0; border:1px solid #E7B1B1; }

.psb-project-side-title { font-size:9px; color:var(--psb-teal); font-weight:850; letter-spacing:1px; margin:2px 0 8px; }
.psb-project-side-hint { margin-top:9px; padding:12px; border-radius:12px; background:#F4F8F9; border:1px solid var(--psb-line); color:var(--psb-muted); font-size:10.5px; line-height:1.45; }
.psb-project-side-hint strong { color:var(--psb-navy); font-size:12px; }
.psb-project-side-divider { height:1px; background:var(--psb-line); margin:13px 0; }
.psb-project-side-meta { color:#7C8A92; font-size:9.5px; line-height:1.55; }

.psb-workspace-section-kicker { color:var(--psb-teal); font-size:9px; font-weight:850; letter-spacing:1px; margin-bottom:5px; }

.psb-project-row-title { display:flex; gap:9px; align-items:center; flex-wrap:wrap; }
.psb-project-code { font-size:9px; color:var(--psb-teal); font-weight:850; letter-spacing:.75px; }
.psb-project-name { font-size:15px; color:var(--psb-navy); font-weight:820; }
.psb-project-status { margin-left:auto; border:1px solid #CFE0E5; background:#F4F8F9; color:#516670; border-radius:999px; padding:4px 8px; font-size:8.5px; font-weight:850; text-transform:uppercase; }
.psb-task-row { display:flex; justify-content:space-between; gap:12px; padding:10px 0 6px; border-bottom:1px solid var(--psb-line); color:var(--psb-text); }
.psb-task-state { padding:4px 7px; border-radius:999px; font-size:8px; font-weight:850; }
.psb-task-state--on_track { background:#E9F7F1; color:#0B7652; }
.psb-task-state--due_soon { background:#FFF7E8; color:#876213; }
.psb-task-state--overdue, .psb-task-state--breached { background:#FFF0F0; color:#A43C3C; }

@media (max-width: 900px) {
  .psb-project-header { flex-direction:column; align-items:flex-start; }
  .psb-project-header__metrics { justify-content:flex-start; width:100%; }
}
"""



EPAS_V37_REFERENCE_CSS = r"""
:root{--psb-shell:#03131F;--psb-shell-2:#043342;--psb-bg:#F2F5F6;--psb-line:#DCE4E8;--psb-text:#10212B;--psb-muted:#6C7B86;--psb-teal:#0A7485;--psb-green:#1E8F68;--psb-amber:#C18B22;--psb-red:#C53C35;--psb-shadow:0 5px 18px rgba(3,19,31,.055)}
[data-testid="stAppViewContainer"]{background:var(--psb-bg)!important}
[data-testid="stSidebar"]{background:linear-gradient(180deg,var(--psb-shell-2),var(--psb-shell))!important;min-width:250px!important}
[data-testid="stSidebar"] .stButton>button{border-radius:9px!important;color:#D7E7EC!important;background:transparent!important;border:1px solid transparent!important}
[data-testid="stSidebar"] .stButton>button:hover{background:rgba(255,255,255,.07)!important}
.psb-topbar{background:linear-gradient(90deg,#042C3A,#053B49)!important;color:#F5FBFD!important;border:0!important;border-radius:12px!important;box-shadow:0 6px 18px rgba(3,19,31,.18)!important}
.psb-topbar__org{color:#F7FBFC!important;letter-spacing:.85px!important}.psb-topbar__product{color:#A9C4CB!important}.psb-user-block strong{color:#F4FBFD!important}.psb-user-block span{color:#9CB9C0!important}
div[data-testid="stRadio"]>div{background:rgba(255,255,255,.95)!important;border:1px solid var(--psb-line)!important;border-radius:10px!important}
div[data-testid="stRadio"] label{font-size:11px!important;padding:8px 13px!important}div[data-testid="stRadio"] label:has(input:checked){background:#083D4B!important;color:#fff!important}
.ref-page-kicker{font-size:10px;letter-spacing:1.05px;color:#738590;font-weight:800;text-transform:uppercase;margin-top:3px}.ref-page-title{font-family:Georgia,'Times New Roman',serif!important;font-size:31px!important;color:var(--psb-text)!important;margin:2px 0 2px!important}.ref-page-subtitle{font-size:13px;color:#667781;margin-bottom:16px}
.ref-kpi{background:#fff;border:1px solid var(--psb-line);border-radius:10px;padding:13px 14px;min-height:96px;box-shadow:var(--psb-shadow);margin-bottom:12px}.ref-kpi__label{font-size:9.5px;letter-spacing:.65px;text-transform:uppercase;font-weight:800;color:#6D7D87}.ref-kpi__value{font-size:25px;font-weight:850;color:#092C3A;line-height:1.08;margin-top:5px}.ref-kpi__foot{font-size:10.5px;color:#71808A;margin-top:6px}.ref-kpi--red .ref-kpi__value{color:#C43C35}.ref-kpi--green .ref-kpi__value{color:#1E8F68}.ref-kpi--amber .ref-kpi__value{color:#B9791E}.ref-kpi--rust .ref-kpi__value{color:#A6461B}.ref-kpi--teal .ref-kpi__value{color:#0A7485}.ref-kpi--navy .ref-kpi__value{color:#083D4B}
.ref-panel{background:#fff;border:1px solid var(--psb-line);border-radius:10px;box-shadow:var(--psb-shadow);padding:15px 16px;margin-bottom:14px}.ref-panel__head{display:flex;justify-content:space-between;gap:10px;margin-bottom:10px}.ref-panel__title{font-size:13px;font-weight:850;color:#152A34}.ref-panel__subtitle{font-size:10px;color:#778791;text-align:right}
.ref-flow-row{display:grid;grid-template-columns:14px 1fr auto;gap:8px;align-items:center;padding:8px 0;border-bottom:1px solid #EEF2F4;font-size:11.5px}.ref-flow-row:last-child{border-bottom:0}.ref-flow-row b{font-size:16px}.ref-flow-icon{width:9px;height:9px;border-radius:3px;display:inline-block;background:#0A7485}.ref-flow-icon--risk{background:#C53C35}.ref-flow-icon--action{background:#A6461B}.ref-flow-icon--warning{background:#C18B22}.ref-flow-icon--ok{background:#1E8F68}
.ref-list-row{display:grid;grid-template-columns:10px 1fr auto;gap:8px;align-items:center;padding:9px 0;border-bottom:1px solid #EEF2F4}.ref-list-row:last-child{border-bottom:0}.ref-dot{width:8px;height:8px;border-radius:50%}.ref-dot--danger{background:#C53C35}.ref-dot--warning{background:#C18B22}.ref-dot--ok{background:#1E8F68}.ref-list-main{display:flex;flex-direction:column;gap:2px}.ref-list-main strong{font-size:11.5px;color:#223740}.ref-list-main span{font-size:10px;color:#7B8B94}.ref-list-status{font-size:9px;font-weight:850;padding:3px 7px;border-radius:999px}.ref-list-status--danger{background:#F9E6E4;color:#A3332E}.ref-list-status--warning{background:#FFF2D9;color:#9A6B12}.ref-list-status--ok{background:#E7F5EF;color:#1D7659}
.ref-donut{width:128px;height:128px;border-radius:50%;margin:6px auto 10px;background:conic-gradient(#1E8F68 0 52%,#C18B22 52% 84%,#C53C35 84% 100%);display:flex;align-items:center;justify-content:center}.ref-donut__inner{width:94px;height:94px;border-radius:50%;background:#fff;display:flex;align-items:center;justify-content:center;flex-direction:column;font-size:26px;font-weight:850;color:#17333E}.ref-donut__inner span{font-size:9px;letter-spacing:.7px;text-transform:uppercase;color:#7A8B94;font-weight:800;margin-top:3px}.ref-health-list{display:flex;justify-content:center;gap:13px;flex-wrap:wrap;font-size:10px;color:#6A7B85}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:4px}.dot.ok{background:#1E8F68}.dot.watch{background:#C18B22}.dot.danger{background:#C53C35}
.ref-progress-row{display:grid;grid-template-columns:68px 1fr 26px;gap:8px;align-items:center;margin:10px 0;font-size:10px;color:#6B7D87}.ref-progress{height:6px;background:#EDF1F3;border-radius:99px;overflow:hidden}.ref-progress i{display:block;height:100%;border-radius:99px}.ref-progress i.ok{background:#1E8F68}.ref-progress i.warning{background:#C18B22}.ref-progress i.danger{background:#C53C35}.ref-progress i.green{background:#5AA77E}
.ref-activity{display:flex;gap:10px;padding:8px 0;border-bottom:1px solid #EEF2F4}.ref-activity:last-child{border-bottom:0}.activity-dot{width:8px;height:8px;border-radius:50%;background:#0A7485;margin-top:5px;flex:0 0 auto}.ref-activity strong{font-size:11px}.ref-activity span{display:block;font-size:9.8px;color:#7A8A93}.ref-cert-row{display:grid;grid-template-columns:1fr auto auto;gap:8px;align-items:center;padding:8px 0;border-bottom:1px solid #EEF2F4}.ref-cert-row:last-child{border-bottom:0}.ref-cert-row strong{font-size:10.5px;display:block}.ref-cert-row span{font-size:9.5px;color:#7C8B94;display:block}.ref-cert-row em{font-size:9px;font-style:normal;font-weight:850;color:#0A7485}
@media(max-width:1050px){.ref-kpi__value{font-size:22px}.ref-page-title{font-size:27px!important}}@media(max-width:760px){.ref-kpi{min-height:88px}.ref-panel__subtitle{display:none}.ref-page-title{font-size:24px!important}}
"""
EPAS_V38_PROJECT_NAV_CSS = r"""
/* =========================================================
   EPAS v3.8 — Project-specific left navigation
   ========================================================= */
[data-testid="stSidebar"] {
  background: linear-gradient(180deg,#062C3B 0%,#031925 100%) !important;
  border-right:1px solid rgba(255,255,255,.07) !important;
}
.psb-project-sidebar-kicker{color:#8FB7BF;font-size:9px;font-weight:850;letter-spacing:1.05px;text-transform:uppercase;margin:2px 4px 8px}
.psb-project-sidebar-project{background:linear-gradient(135deg,rgba(11,78,93,.92),rgba(3,34,49,.95));border:1px solid rgba(129,194,204,.20);border-radius:14px;padding:12px 12px 11px;box-shadow:0 8px 22px rgba(0,0,0,.16);margin-bottom:10px}
.psb-project-sidebar-code{color:#91D0D7;font-size:8.5px;font-weight:900;letter-spacing:1px;text-transform:uppercase}
.psb-project-sidebar-name{color:#F5FBFD;font-size:15px;font-weight:850;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.psb-project-sidebar-meta{color:#B3CCD2;font-size:9.5px;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.psb-project-sidebar-section{color:#90B0B8;font-size:8px;font-weight:900;letter-spacing:1.1px;text-transform:uppercase;margin:14px 4px 7px}
.psb-project-sidebar-current{margin-top:7px;padding:9px 10px;border-left:3px solid #1E8F68;background:rgba(19,117,97,.15);border-radius:8px;color:#F4FBFD;font-size:9px;line-height:1.35}
.psb-project-sidebar-current b{display:block;font-size:10px;letter-spacing:.25px}
.psb-project-sidebar-current span{display:block;color:#A7C3C8;margin-top:3px}
.psb-project-sidebar-row{display:grid;grid-template-columns:1fr auto;gap:8px;padding:6px 4px;border-bottom:1px solid rgba(255,255,255,.07);font-size:9px;color:#A8BEC5}
.psb-project-sidebar-row b{color:#F5FBFD;font-size:9px;text-align:right;font-weight:750}
.psb-project-sidebar-note{margin-top:11px;padding:10px;border:1px solid rgba(255,255,255,.08);border-radius:10px;color:#93ACB4;font-size:8.5px;line-height:1.45;background:rgba(255,255,255,.025)}
.psb-project-breadcrumb{font-size:10px;color:#7B8B94;margin:2px 0 8px;letter-spacing:.1px}
.psb-project-breadcrumb span{color:#0A7485;padding:0 5px}
.psb-project-nav-pill{display:inline-flex;align-items:center;gap:6px;padding:4px 7px;border-radius:999px;background:#E7F5EF;color:#1D7659;font-size:8px;font-weight:850;text-transform:uppercase;letter-spacing:.6px;margin-right:5px}
[data-testid="stSidebar"] div[data-testid="stRadio"] > div{background:transparent !important;border:none !important;display:flex;flex-direction:column;gap:4px}
[data-testid="stSidebar"] div[data-testid="stRadio"] label{display:flex !important;align-items:center !important;gap:8px !important;background:transparent !important;color:#D7E7EC !important;border:1px solid transparent !important;border-radius:9px !important;padding:8px 10px !important;font-size:10px !important;font-weight:700 !important;line-height:1.2 !important}
[data-testid="stSidebar"] div[data-testid="stRadio"] label:hover{background:rgba(255,255,255,.06) !important;border-color:rgba(255,255,255,.08) !important}
[data-testid="stSidebar"] div[data-testid="stRadio"] label:has(input:checked){background:linear-gradient(90deg,rgba(18,137,118,.34),rgba(18,137,118,.14)) !important;border-left:3px solid #2FB590 !important;color:#FFFFFF !important;padding-left:7px !important}
[data-testid="stSidebar"] div[data-testid="stRadio"] label [data-testid="stMarkdownContainer"] p{margin:0 !important}
[data-testid="stSidebar"] .stButton > button{background:rgba(255,255,255,.04)!important;border-color:rgba(255,255,255,.10)!important;color:#D9EAEE!important;font-size:10px!important;font-weight:750!important}
[data-testid="stSidebar"] .stButton > button:hover{background:rgba(255,255,255,.08)!important;border-color:rgba(56,182,154,.25)!important}
@media (max-width: 900px){.psb-project-sidebar-project{padding:10px}.psb-project-sidebar-name{font-size:14px}}
"""

def inject_css() -> None:
    st.markdown(f"<style>{CSS}{EPAS_V30_CSS}{EPAS_V35_CSS}{EPAS_V36_CSS}{PSB_V361_CSS}{PSB_V362_PROJECT_CSS}{EPAS_V37_REFERENCE_CSS}{EPAS_V38_PROJECT_NAV_CSS}</style>", unsafe_allow_html=True)


EPAS_V30_CSS = r"""
/* v3.2 role cockpit polish */
.epas-role-strip { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:10px; margin:12px 0 18px; }
.epas-role-strip-card { border:1px solid var(--hairline); background:var(--paper); border-radius:var(--radius-md); padding:12px 14px; min-height:86px; }
.epas-role-strip-label { font-family:var(--font-mono); text-transform:uppercase; letter-spacing:.8px; font-size:9.5px; color:var(--ink-400); }
.epas-role-strip-value { font-family:var(--font-display); font-size:22px; font-weight:700; color:var(--ink-900); margin-top:4px; }
.epas-role-strip-help { color:var(--ink-600); font-size:11px; margin-top:3px; }
.epas-workflow-chain { display:flex; flex-wrap:wrap; gap:6px; align-items:center; margin:10px 0 16px; }
.epas-workflow-node { border:1px solid var(--hairline); border-radius:999px; padding:5px 9px; background:var(--paper-soft); font-size:11px; font-weight:650; color:var(--ink-700); }
.epas-workflow-node--done { background:var(--green-100); border-color:var(--green-700); color:var(--green-700); }
.epas-workflow-node--current { background:var(--blue-100); border-color:var(--blue-600); color:var(--blue-600); }
.epas-workflow-node--blocked { background:var(--red-100); border-color:var(--red-700); color:var(--red-700); }
.epas-workflow-arrow { color:var(--ink-400); font-size:12px; }
[data-testid="stTextInput"] input:focus,
[data-testid="stTextArea"] textarea:focus,
[data-testid="stSelectbox"] input:focus,
[data-testid="stDateInput"] input:focus,
[data-testid="stFileUploader"] section:focus-within,
button:focus-visible,
[role="button"]:focus-visible { outline:3px solid rgba(27,75,145,.42) !important; outline-offset:2px !important; }
@media (max-width: 980px) { .epas-role-strip { grid-template-columns:repeat(2,minmax(0,1fr)); } }
@media (max-width: 680px) { .epas-role-strip { grid-template-columns:1fr; } }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior:auto !important; transition:none !important; animation:none !important; } }
"""

EPAS_V35_CSS = r"""
.fleet-card { background: var(--paper); border: 1px solid var(--hairline); border-radius: 12px; padding: 14px 16px; min-height: 108px; box-shadow: var(--shadow-card); }
.fleet-card__label { font-size: 10.5px; text-transform: uppercase; letter-spacing: .8px; color: var(--ink-600); font-weight: 700; }
.fleet-card__value { margin-top: 7px; font-family: var(--font-display); font-size: 26px; font-weight: 700; color: var(--ink-900); line-height: 1.05; }
.fleet-card__foot { margin-top: 7px; font-size: 11px; color: var(--ink-600); }
.fleet-card--amber { border-top: 3px solid var(--amber-700); }
.fleet-card--red { border-top: 3px solid var(--red-700); }
.fleet-card--rust { border-top: 3px solid var(--rust-700); }
.fleet-card--blue { border-top: 3px solid var(--blue-600); }
.fleet-card--green { border-top: 3px solid var(--green-700); }
.fleet-card--neutral { border-top: 3px solid var(--hairline); }
.readiness-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:8px; }
.readiness-item { border:1px solid var(--hairline); border-radius:8px; background:var(--paper-soft); padding:8px 10px; font-size:12px; }
.readiness-item--ok { border-left:3px solid var(--green-700); }
.readiness-item--wait { border-left:3px solid var(--amber-700); }
@media (max-width: 900px) { .readiness-grid { grid-template-columns:1fr 1fr; } .fleet-card__value { font-size:22px; } }
@media (max-width: 640px) { .readiness-grid { grid-template-columns:1fr; } .fleet-card { min-height:92px; } .page-title { font-size:25px; } }
"""

EPAS_V36_CSS = r"""
/* EPAS v3.6 accessibility reinforcement */
.epas-live-status { font-size: 12px; line-height: 1.5; color: var(--ink-700); }
.stButton > button:focus-visible, .stTextInput input:focus-visible, .stSelectbox div:focus-visible { outline: 3px solid var(--blue-600) !important; outline-offset: 2px !important; }
"""

# v3.8 project-specific left navigation: selected project becomes the
# navigation context after a project is opened.

