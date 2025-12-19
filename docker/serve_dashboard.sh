#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="/srv/cyberarxiv/_site"
if [ ! -d "$SITE_DIR" ]; then
  echo "Building dashboard site..."
  Rscript /srv/cyberarxiv/docker/run_dashboard.R
fi

echo "Serving site at http://0.0.0.0:8000"
cd "$SITE_DIR"
python3 -m http.server 8000
