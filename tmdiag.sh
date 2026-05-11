#!/bin/bash
# tmdiag — grab TestMonitor screenshot + status + logs in one shot
# Usage: ./tmdiag.sh [outdir]
#   outdir defaults to /tmp/tmdiag-$(date +%s)

set -euo pipefail

HOST="localhost:7777"
OUT="${1:-/tmp/tmdiag-$(date +%s)}"
mkdir -p "$OUT"

echo "[tmdiag] Capturing to $OUT ..."

curl -sf "$HOST/ss"     -o "$OUT/screenshot.png"  && echo "  ✓ screenshot.png"
curl -sf "$HOST/status" -o "$OUT/status.json"     && echo "  ✓ status.json"
curl -sf "$HOST/logs"   -o "$OUT/logs.txt"        && echo "  ✓ logs.txt"

# Pretty-print the JSON status inline
echo ""
echo "=== STATUS ==="
python3 -m json.tool "$OUT/status.json" 2>/dev/null || cat "$OUT/status.json"

echo ""
echo "=== LOGS (last 40 lines of each suite) ==="
awk '/^===/{suite=$0; next} suite{print suite": "$0; suite=""} {print}' "$OUT/logs.txt" | tail -80

echo ""
echo "[tmdiag] Files saved to $OUT"
echo "  open $OUT/screenshot.png"
