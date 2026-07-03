#!/usr/bin/env bash
#
#  Uninstaller for the Project Zomboid B42 ARM server — reverses install.sh.
#
#  Usage:   sudo ./uninstall.sh
#
#  Removes the server, its systemd services, scripts, config and firewall rules.
#  Prompts before deleting your worlds/saves and before touching the shared box64.
#
#  !!! USE AT YOUR OWN RISK !!!  This `rm -rf`s /opt/zomboid-server and (after a prompt) your
#  entire ~/Zomboid folder. If you kept unrelated files in those paths, they go too.
#
set -uo pipefail   # deliberately NOT -e: keep going even if pieces are already gone

b()   { printf '\033[1m%s\033[0m' "$*"; }
say()  { printf '\033[1;32m>>>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*"; }
ask()  { local p="$1" d="${2:-}" a; read -rp "$(printf '\033[1;36m?\033[0m') $p ${d:+[$d] }" a; printf '%s' "${a:-$d}"; }
is_yes() { case "${1,,}" in y|yes|e|evet) return 0;; *) return 1;; esac; }

cat <<'EOF'

  Project Zomboid B42  ->  UNINSTALL
  ---------------------------------
EOF
[ "$(id -u)" -eq 0 ] || { echo "Please run as root:  sudo ./uninstall.sh"; exit 1; }

# discover paths from the installer's env file (fall back to defaults)
[ -f /etc/zomboid-b42.env ] && . /etc/zomboid-b42.env
PZ_USER="${PZ_USER:-ubuntu}"
PZ_HOME="$(getent passwd "$PZ_USER" | cut -d: -f6)"; PZ_HOME="${PZ_HOME:-/home/ubuntu}"
INSTALL_DIR="${PZ_INSTALL:-/opt/zomboid-server}"
WS="$INSTALL_DIR/steamapps/workshop/content/108600"

echo "This removes: the PZ B42 server, its systemd services, pzctl, the watchdog, the"
echo "box64 [ProjectZomboid64] tuning we added, and the UDP 16261-16262 firewall rules."
warn "USE AT YOUR OWN RISK — this rm -rf's $INSTALL_DIR and (if you confirm below) ALL of"
warn "$PZ_HOME/Zomboid. Anything you stored inside those folders will be gone for good."
is_yes "$(ask 'Continue? (type y to proceed)' 'n')" || { echo "Aborted."; exit 0; }

# ----------------------------------------------------------------- 1. services
step "Stopping and disabling services"
systemctl stop zomboid-b42.service zomboid-watchdog.timer zomboid-watchdog.service zomboid-ciopfs.service 2>/dev/null
systemctl disable zomboid-b42.service zomboid-watchdog.timer zomboid-ciopfs.service 2>/dev/null
say "stopped."

# ----------------------------------------------------------------- 2. ciopfs unmount
step "Unmounting ciopfs"
fusermount -u "$WS" 2>/dev/null || umount -l "$WS" 2>/dev/null || true
say "unmounted (if it was mounted)."

# ----------------------------------------------------------------- 3. units + scripts + env
step "Removing systemd units, scripts and pzctl"
rm -f /etc/systemd/system/zomboid-b42.service \
      /etc/systemd/system/zomboid-ciopfs.service \
      /etc/systemd/system/zomboid-watchdog.service \
      /etc/systemd/system/zomboid-watchdog.timer
rm -f /usr/local/sbin/zomboid-watchdog.sh /usr/local/sbin/pz-boot-retry /usr/local/bin/pzctl /etc/zomboid-b42.env
systemctl daemon-reload 2>/dev/null
systemctl reset-failed zomboid-b42.service 2>/dev/null
say "removed."

# ----------------------------------------------------------------- 4. box64rc tuning block
step "Reverting the box64 [ProjectZomboid64] tuning"
if [ -f /etc/box64.box64rc ] && grep -q '^# Appended to.*install\.sh' /etc/box64.box64rc; then
  sed -i '/^# Appended to.*install\.sh/,$d' /etc/box64.box64rc
  say "removed the block install.sh appended."
else
  say "nothing appended by us (left box64rc untouched)."
fi

# ----------------------------------------------------------------- 5. firewall rules
step "Removing the UDP 16261-16262 firewall rules"
if command -v iptables >/dev/null; then
  iptables -D INPUT -p udp --dport 16261 -j ACCEPT 2>/dev/null
  iptables -D INPUT -p udp --dport 16262 -j ACCEPT 2>/dev/null
  netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  say "removed (the Oracle VCN Security List rule, if any, is separate — remove it in the console)."
fi

# ----------------------------------------------------------------- 6. server files
step "Deleting server files"
rm -rf "$INSTALL_DIR" /opt/depotdownloader
say "removed $INSTALL_DIR and /opt/depotdownloader."

# ----------------------------------------------------------------- 7. worlds / saves (prompt)
step "Worlds and saves"
if [ -d "$PZ_HOME/Zomboid" ]; then
  if is_yes "$(ask "Delete your worlds & saves at $PZ_HOME/Zomboid too? (irreversible)" 'y')"; then
    rm -rf "$PZ_HOME/Zomboid"; say "worlds/saves deleted."
  else
    say "kept your worlds/saves at $PZ_HOME/Zomboid."
  fi
else
  say "no ~/Zomboid data found."
fi

# ----------------------------------------------------------------- 8. box64 (prompt, shared)
step "box64 emulator (shared)"
if is_yes "$(ask 'Remove box64 too? Only if nothing else on this box needs x86 emulation.' 'n')"; then
  rm -f /etc/binfmt.d/box64.conf 2>/dev/null; systemctl restart systemd-binfmt 2>/dev/null || true
  apt-get remove -y -qq 'box64*' >/dev/null 2>&1 || warn "box64 wasn't an apt package (source build?) — remove /usr/local/bin/box64 by hand if you want it gone."
  say "box64 removal attempted."
else
  say "left box64 in place."
fi

step "Done"
echo "  Project Zomboid B42 server removed."
echo "  Oracle Cloud: you may also remove the UDP 16261 rule from your VCN Security List."
