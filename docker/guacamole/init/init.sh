#!/bin/bash
# ============================================================
# Generate Guacamole PostgreSQL schema
# Run ONCE before first docker compose up:
#   chmod +x docker/guacamole/init/init.sh
#   ./docker/guacamole/init/init.sh
# The generated initdb.sql is gitignored.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/initdb.sql"

if [[ -f "${OUTPUT}" ]]; then
  echo "initdb.sql already exists. Delete it first if you want to regenerate."
  exit 0
fi

echo "Generating Guacamole PostgreSQL schema..."
docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql > "${OUTPUT}"

echo "Schema written to ${OUTPUT}"
echo "You can now run: docker compose up -d"
