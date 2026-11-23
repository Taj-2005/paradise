#!/usr/bin/env bash
# Build paradise-presentation.pptx + .pdf. Needs python-pptx and Google Chrome.
set -euo pipefail
cd "$(dirname "$0")"
PY="${PYTHON:-python3}"
"$PY" build_deck.py
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --no-pdf-header-footer --allow-file-access-from-files \
  --print-to-pdf="$PWD/paradise-presentation.pdf" "file://$PWD/paradise-presentation.html" 2>/dev/null
pdfinfo paradise-presentation.pdf | grep -E 'Pages|Page size' || true
