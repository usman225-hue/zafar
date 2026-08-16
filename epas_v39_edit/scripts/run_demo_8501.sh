#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export EPAS_RUNTIME_MODE=demo
export EPAS_DEMO_PASSWORD="${EPAS_DEMO_PASSWORD:-PSB-Demo-2026!}"
export EPAS_REQUIRE_ANTIVIRUS=0
python -m streamlit run app.py --server.address 0.0.0.0 --server.port 8501
