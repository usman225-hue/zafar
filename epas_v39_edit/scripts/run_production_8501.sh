#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export EPAS_RUNTIME_MODE=production
if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_ANON_KEY:-}" ]]; then
  echo "ERROR: SUPABASE_URL and SUPABASE_ANON_KEY are required in production." >&2
  exit 1
fi
export EPAS_REQUIRE_ANTIVIRUS="${EPAS_REQUIRE_ANTIVIRUS:-1}"
python -m streamlit run app.py --server.address 0.0.0.0 --server.port 8501
