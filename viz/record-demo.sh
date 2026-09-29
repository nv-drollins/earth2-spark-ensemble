#!/usr/bin/env bash
# Record a demo video of the booth display + operator console.
#
# Headless: Xvfb + Chrome + ffmpeg on the WORKSTATION. Nothing is installed on
# the Spark nodes and no OBS is needed. Beats are driven through the app's own
# REST API, so there is no xdotool/synthetic-keystroke dependency.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PORT="${E2_PORT:-8500}"
API="http://127.0.0.1:${PORT}/api"
URL="${E2_URL:-http://127.0.0.1:${PORT}}"
OUT="${1:-$HOME/e2viz/earth2-demo.mp4}"
DISP="${E2_XDISPLAY:-:77}"
W=1920; H=1080

c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_red(){ printf '\033[31m%s\033[0m\n' "$*"; }
step(){ printf '\033[36m  [%s] %s\033[0m\n' "$(date +%M:%S)" "$*"; }

command -v ffmpeg >/dev/null || { c_red "ffmpeg missing"; exit 1; }
command -v Xvfb   >/dev/null || { c_red "Xvfb missing"; exit 1; }
CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser)"
[ -z "$CHROME" ] && { c_red "no chrome/chromium"; exit 1; }

# Fail fast if the display server is not actually serving.
curl -s -o /dev/null --max-time 5 "$API/state" || {
  c_red "display server not responding on port $PORT -- run viz/start-display.sh"; exit 1; }

# Fail fast if no frames are rendered: recording an empty booth screen for
# 90 seconds and only noticing afterwards is the classic waste.
NLEAD=$(curl -s --max-time 5 "$API/state" | python3 -c 'import json,sys; print(json.load(sys.stdin)["manifest"].get("n_lead",0))' 2>/dev/null || echo 0)
[ "${NLEAD:-0}" -lt 2 ] && { c_red "only $NLEAD lead frames rendered -- run viz/render.py first"; exit 1; }

mkdir -p "$(dirname "$OUT")"
cleanup(){
  [ -n "${FF_PID:-}" ] && kill -INT "$FF_PID" 2>/dev/null
  sleep 2
  [ -n "${CH1:-}" ] && kill "$CH1" 2>/dev/null
  [ -n "${CH2:-}" ] && kill "$CH2" 2>/dev/null
  [ -n "${XV_PID:-}" ] && kill "$XV_PID" 2>/dev/null
  rm -rf /tmp/chrome-e2rec-$$-a /tmp/chrome-e2rec-$$-b
}
trap cleanup EXIT

step "starting Xvfb on $DISP (${W}x${H})"
Xvfb "$DISP" -screen 0 "${W}x${H}x24" -nolisten tcp >/dev/null 2>&1 &
XV_PID=$!
sleep 2

# Two windows side by side: display (left, larger) + operator (right).
# --window-position needs --app mode to be honoured reliably.
step "launching display window"
# --test-type is REQUIRED to suppress the yellow "unsupported command-line
# flag: --no-sandbox" infobar. --disable-infobars does NOT suppress that one,
# and it steals ~30px off the top of every recorded frame.
DISPLAY="$DISP" "$CHROME" --no-sandbox --test-type --disable-gpu --disable-dev-shm-usage \
  --no-first-run --disable-infobars --disable-session-crashed-bubble \
  --user-data-dir="/tmp/chrome-e2rec-$$-a" \
  --window-position=0,0 --window-size=1270,1080 \
  --app="$URL/display" >/dev/null 2>&1 &
CH1=$!
sleep 4

step "launching operator window"
DISPLAY="$DISP" "$CHROME" --no-sandbox --test-type --disable-gpu --disable-dev-shm-usage \
  --no-first-run --disable-infobars --disable-session-crashed-bubble \
  --user-data-dir="/tmp/chrome-e2rec-$$-b" \
  --window-position=1270,0 --window-size=650,1080 \
  --app="$URL/operator" >/dev/null 2>&1 &
CH2=$!
sleep 6   # let both pages paint before the first frame

step "recording -> $OUT"
ffmpeg -y -loglevel error -f x11grab -draw_mouse 0 \
  -video_size "${W}x${H}" -framerate 25 -i "$DISP" \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "$OUT" &
FF_PID=$!
sleep 3

# ---- the beats, driven through the app's own API ----
beat(){ curl -s -X POST --max-time 8 "$API/beat/$1" >/dev/null; }
lead(){ curl -s -X POST --max-time 8 "$API/lead/$1" >/dev/null; }

step "beat: idle"       ; beat idle     ; sleep 4
step "beat: one forecast"; beat single   ; sleep 7
step "beat: six members" ; beat ensemble ; lead 0 ; sleep 7

step "divergence 0h -> 48h"
for l in $(seq 0 $((NLEAD-1))); do lead "$l"; sleep 1.7; done
sleep 3

step "beat: uncertainty map"; beat spread ; sleep 9

# CorrDiff zoom beat, only if frames exist (it is an optional second act).
if curl -s --max-time 5 "$API/state" | grep -q '"corrdiff"'; then
  step "beat: zoom (CorrDiff)"; beat zoom ; sleep 10
fi

step "finalizing"
kill -INT "$FF_PID" 2>/dev/null   # -INT so ffmpeg writes the moov atom
wait "$FF_PID" 2>/dev/null
FF_PID=""

[ -s "$OUT" ] || { c_red "no output written"; exit 1; }
SZ=$(du -h "$OUT" | cut -f1)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null | cut -d. -f1)
c_grn "Recorded $OUT ($SZ, ${DUR}s)"

# Verify the OUTPUT, not the exit code: extract a storyboard to eyeball.
SB="$(dirname "$OUT")/storyboard"
mkdir -p "$SB"; rm -f "$SB"/*.png
ffmpeg -v error -i "$OUT" -vf "fps=1/6,scale=1100:-1" "$SB/f_%02d.png"
c_grn "Storyboard frames: $SB"
