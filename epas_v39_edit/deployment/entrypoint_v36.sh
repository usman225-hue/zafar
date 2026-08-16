#!/bin/sh
set -eu
if command -v freshclam >/dev/null 2>&1; then
  mkdir -p /var/lib/clamav
  # Refresh the database at container startup. Fail only when the scanner is required
  # and no usable database is available. Network failures do not erase a valid DB.
  freshclam --stdout --verbose || true
  if [ "${EPAS_REQUIRE_ANTIVIRUS:-1}" = "1" ] && ! ls /var/lib/clamav/main.cvd /var/lib/clamav/main.cld /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld >/dev/null 2>&1; then
    echo 'ERROR: ClamAV database is unavailable; refusing to start with EPAS_REQUIRE_ANTIVIRUS=1.' >&2
    exit 1
  fi
fi
exec python -m streamlit run app.py --server.address=0.0.0.0 --server.port=851
