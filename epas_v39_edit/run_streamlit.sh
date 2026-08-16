#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
MODE="${EPAS_RUNTIME_MODE:-production}"
if [[ "$MODE" == "demo" ]]; then
  exec ./scripts/run_demo_8501.sh
fi
exec ./scripts/run_production_8501.sh
