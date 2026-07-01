#!/bin/bash
# Bring the server up through box64's flaky boot: restart, watch, and if it truly hangs,
# restart and try again. box64 boots succeed maybe 30-50% of the time on their own, so a
# few automated retries is the fast way to get to "listening".
#
#   success = UDP :16261 is listening
#   hang    = console silent >2 min AND CPU idle over 8s  -> restart & retry
#   crash   = a shutdown / failed-download line appears   -> STOP (retrying would just recrash)
#
# Installed as /usr/local/sbin/pz-boot-retry ; also invoked by `pzctl` (menu: Start / Bring up).
SVC="${PZ_SERVICE:-zomboid-b42}"
PORT="${PZ_PORT:-16261}"
C="${PZ_CONSOLE:-/home/ubuntu/Zomboid/server-console.txt}"
CG=/sys/fs/cgroup/system.slice/$SVC.service/cpu.stat
for attempt in $(seq 1 6); do
  echo "=== ATTEMPT $attempt $(date -u +%H:%M:%S) ==="
  sudo systemctl restart "$SVC"
  for poll in $(seq 1 40); do
    sleep 15
    listen=$(sudo ss -uln 2>/dev/null | grep -c ":$PORT")
    crash=$(grep -c "Shutdown handling started\|onItemNotDownloaded" "$C" 2>/dev/null)
    idle=$(( $(date +%s) - $(stat -c %Y "$C" 2>/dev/null || echo 0) ))
    last=$(tail -1 "$C" 2>/dev/null)
    echo "  [a$attempt p$poll] listen=$listen crash=$crash idle=${idle}s | ${last:0:40}"
    [ "$listen" = "1" ] && { echo ">>> LISTENING OK (attempt $attempt) <<<"; exit 0; }
    [ "$crash" -ge 1 ] 2>/dev/null && { echo ">>> CRASH — not retrying (would recrash). Check logs. <<<"; exit 2; }
    if [ "$idle" -ge 120 ] 2>/dev/null; then
      u1=$(awk '/usage_usec/{print $2}' "$CG" 2>/dev/null); sleep 8; u2=$(awk '/usage_usec/{print $2}' "$CG" 2>/dev/null)
      d=$(( (u2 - u1)/1000000 ))
      echo "    (console ${idle}s static, cpu delta=${d}s)"
      [ "$d" -lt 2 ] 2>/dev/null && { echo "    >> HANG (cpu idle) -> restart"; break; }
    fi
  done
done
echo ">>> no listening after 6 attempts <<<"; exit 1
