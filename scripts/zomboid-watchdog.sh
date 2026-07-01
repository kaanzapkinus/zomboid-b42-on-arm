#!/bin/bash
# Box64 boot-hang watchdog — HYBRID detection (console-static AND cpu-idle = real hang).
#
# Why hybrid: box64 boots are flaky and hang at random points, but two states LOOK
# like a hang without being one, and killing them wastes boot attempts:
#   1. "Waiting for response from Steam servers" — low CPU, but progressing.
#   2. Silent asset loading — no console output, but high CPU (working).
# So we restart ONLY when BOTH are true: console silent >6 min AND CPU idle over 8s.
#
# Installed at /usr/local/sbin/zomboid-watchdog.sh, driven by zomboid-watchdog.timer.
SVC="${PZ_SERVICE:-zomboid-b42}"
PORT="${PZ_PORT:-16261}"
CONSOLE="${PZ_CONSOLE:-/home/ubuntu/Zomboid/server-console.txt}"
STALL=360
[ "$(systemctl is-active "$SVC" 2>/dev/null)" != "active" ] && exit 0
ss -uln 2>/dev/null | grep -q ":$PORT" && exit 0            # listening = healthy
ae=$(systemctl show "$SVC" -p ActiveEnterTimestamp --value 2>/dev/null)
aesec=$(date -d "$ae" +%s 2>/dev/null) || exit 0
[ $(( $(date +%s) - aesec )) -lt "$STALL" ] && exit 0        # just (re)started, give it time
[ -f "$CONSOLE" ] || exit 0
idle=$(( $(date +%s) - $(stat -c %Y "$CONSOLE" 2>/dev/null || echo 0) ))
[ "$idle" -lt "$STALL" ] && exit 0                           # console updated recently = still working/waiting
CG=/sys/fs/cgroup/system.slice/$SVC.service/cpu.stat
[ -f "$CG" ] || exit 0
u1=$(awk "/usage_usec/{print \$2}" "$CG"); sleep 8; u2=$(awk "/usage_usec/{print \$2}" "$CG")
if [ $(( u2 - u1 )) -lt 2000000 ]; then                      # <2s CPU in 8s = idle
  logger -t zomboid-watchdog "not listening, console ${idle}s idle + cpu idle -> HUNG, restarting"
  systemctl restart "$SVC"
fi
