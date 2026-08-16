#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-../epas-production}"
python scripts/strip_demo_for_production.py --output "$OUTPUT"
cat <<EOF
Production package created at: $OUTPUT
Next:
  export EPAS_RUNTIME_MODE=production
  export SUPABASE_URL='https://YOUR_PROJECT.supabase.co'
  export SUPABASE_ANON_KEY='YOUR_SUPABASE_ANON_KEY'
  cd "$OUTPUT"
  ./scripts/run_production_8501.sh
EOF
