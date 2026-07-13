#!/bin/sh
# cap.sh - stream identityservicesd unified log across restarts into a file.
# Primary evidence is /var/mobile/idsbaa.log (from the tweak hooks); this is the
# supplementary full oslog (catches "Building Absinthe", "absinthe-baa:..", NACInit,
# registration result). Controlled by the flag file below.
OUT=/var/mobile/idsbaa_oslog.txt
FLAG=/var/mobile/.idsbaa_capturing
: > "$OUT"; chmod 666 "$OUT"
touch "$FLAG"
(
  while [ -f "$FLAG" ]; do
    PID=$(ps ax -o pid,comm | grep -v grep | grep '[i]dentityservicesd' | head -1 | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1)
    if [ -n "$PID" ]; then
      echo "=== attach oslog pid=$PID $(date) ===" >> "$OUT"
      oslog --info --debug -p "$PID" >> "$OUT" 2>>"$OUT"
    fi
    sleep 0.5
  done
) >/dev/null 2>&1 &
echo $! > /var/mobile/.idsbaa_cap_pid
echo "[cap] streaming -> $OUT (stop: rm $FLAG)"
