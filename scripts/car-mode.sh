#!/bin/bash
#
# car-mode.sh — fork helper: display OFF, system awake. Pure toggle.
#
# For in-car use: run this in its OWN terminal window. It turns the display
# off immediately and holds the system awake (no idle sleep) until you stop it.
# It does NOT launch or manage MacPlay — do that in another window.
#
# The video tap lives inside the GStreamer pipeline (not screen capture), so
# the MJPEG stream to the car browser is unaffected by the display state.
#
# Usage:
#     ./scripts/car-mode.sh
#
# Press Ctrl-C in this window to exit car mode (wakes the display).
# Any keypress / mouse move also wakes the display manually at any time.
#
set -euo pipefail

cleanup() {
    # wake the display so you see the Mac is back
    caffeinate -u -t 2 >/dev/null 2>&1 &
    kill "$CAFF_PID" 2>/dev/null || true
    echo ""
    echo "==> car mode OFF. Display waking up."
}
trap cleanup INT TERM EXIT

# Hold the system awake (block idle sleep). The display is still allowed to
# sleep — we deliberately do NOT pass -d, which would keep the display on.
echo "==> car mode ON: holding system awake (caffeinate -i)"
caffeinate -i &
CAFF_PID=$!

# Display off now.
pmset displaysleepnow
echo "    display: off  |  system: awake (no idle sleep)"
echo "    car browser: http://<mac-lan-ip>:8080/"
echo ""
echo "    Press Ctrl-C in THIS window to exit car mode."

wait "$CAFF_PID"
