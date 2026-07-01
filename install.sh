#!/usr/bin/env bash
#
#  Project Zomboid Build 42 — one-shot dedicated-server installer for ARM64 (box64)
#
#  Usage:   sudo ./install.sh
#
#  Turns a fresh Ubuntu ARM64 box (e.g. Oracle Cloud Ampere free tier) into a running,
#  self-restarting PZ B42 server. Then manage everything with:  pzctl
#
set -euo pipefail

# ----------------------------------------------------------------- pretty output
b()   { printf '\033[1m%s\033[0m' "$*"; }
say()  { printf '\033[1;32m>>>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXXX %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local p="$1" d="${2:-}" a; read -rp "$(printf '\033[1;36m?\033[0m') $p ${d:+[$d] }" a; printf '%s' "${a:-$d}"; }

cat <<'EOF'

  Project Zomboid  B42  ->  ARM64 (box64)
  ---------------------------------------
EOF

# ----------------------------------------------------------------- 0. sanity checks
[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo ./install.sh"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) : ;;
  x86_64|amd64) die "You're on x86-64 — you do NOT need this. Run the PZ server natively; box64 is only for ARM/other non-x86 CPUs." ;;
  *) warn "Unrecognised arch '$ARCH'. box64 targets ARM64 (also RISC-V/LoongArch). Continuing, but you're off the tested path." ;;
esac
command -v systemctl >/dev/null || die "This installer needs systemd (Ubuntu/Debian)."
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_USER="${SUDO_USER:-ubuntu}"
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' not found. Run via 'sudo' as your normal user."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
INSTALL_DIR=/opt/zomboid-server
WS="$INSTALL_DIR/steamapps/workshop/content/108600"
say "Service user: $(b "$TARGET_USER")   home: $(b "$TARGET_HOME")"

# ----------------------------------------------------------------- interactive config
step "Configuration (press Enter to accept defaults)"
DETECT_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
DEF_RAM=$(( DETECT_GB>16 ? 12 : (DETECT_GB>8 ? DETECT_GB-4 : DETECT_GB/2) )); [ "$DEF_RAM" -lt 2 ] && DEF_RAM=2
ADMIN_PW="$(ask 'Admin password (for the in-game admin account):' 'admin')"
JOIN_PW="$(ask 'Join password (players type this to connect; blank = open):' '')"
RAM_GB="$(ask "RAM for the server in GB (host has ${DETECT_GB}G):" "$DEF_RAM")"
say "RAM ${RAM_GB}G, admin password set, join password $( [ -n "$JOIN_PW" ] && echo set || echo 'none')."

# ----------------------------------------------------------------- 1. dependencies
step "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ciopfs fuse3 wget curl unzip jq ca-certificates >/dev/null || \
  apt-get install -y -qq ciopfs fuse wget curl unzip jq ca-certificates >/dev/null
# allow_other for the ciopfs FUSE mount
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo 'user_allow_other' >> /etc/fuse.conf

if ! command -v box64 >/dev/null; then
  say "Adding the box64 apt repo (ryanfortner/box64-debs)..."
  curl -fsSL https://ryanfortner.github.io/box64-debs/box64.list -o /etc/apt/sources.list.d/box64.list
  curl -fsSL https://ryanfortner.github.io/box64-debs/KEY.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg
  apt-get update -qq
  apt-get install -y -qq box64-generic-arm || apt-get install -y -qq box64 || \
    die "box64 install failed. Install it manually (https://github.com/ptitSeb/box64) and re-run."
fi
say "box64 ready: $(box64 --version 2>&1 | head -1 || echo installed)"

# ----------------------------------------------------------------- 2. DepotDownloader
step "Setting up DepotDownloader (native ARM Steam content downloader)"
DD_DIR=/opt/depotdownloader
mkdir -p "$DD_DIR"
DD=""
if [ -x "$DD_DIR/DepotDownloader" ]; then DD="$DD_DIR/DepotDownloader"
elif [ -f "$DD_DIR/DepotDownloader.dll" ]; then DD="dotnet $DD_DIR/DepotDownloader.dll"
else
  REL="$(curl -fsSL https://api.github.com/repos/SteamRE/DepotDownloader/releases/latest)"
  URL="$(echo "$REL" | jq -r '.assets[].browser_download_url' | grep -iE 'linux-arm64' | head -1)"
  if [ -n "$URL" ] && [ "$URL" != "null" ]; then
    say "Downloading self-contained arm64 build..."
    curl -fsSL "$URL" -o /tmp/dd.zip && unzip -oq /tmp/dd.zip -d "$DD_DIR"
    chmod +x "$DD_DIR/DepotDownloader"; DD="$DD_DIR/DepotDownloader"
  else
    warn "No self-contained arm64 asset; falling back to .NET runtime + framework build."
    apt-get install -y -qq dotnet-runtime-8.0 dotnet-runtime-9.0 2>/dev/null || apt-get install -y -qq dotnet-runtime-8.0 || die "Could not install .NET runtime for DepotDownloader."
    URL="$(echo "$REL" | jq -r '.assets[].browser_download_url' | grep -iE 'framework' | head -1)"
    curl -fsSL "$URL" -o /tmp/dd.zip && unzip -oq /tmp/dd.zip -d "$DD_DIR"; DD="dotnet $DD_DIR/DepotDownloader.dll"
  fi
fi
say "DepotDownloader: $DD"

# ----------------------------------------------------------------- 3. download the server
step "Downloading Project Zomboid B42 (unstable) server — this can take several minutes"
mkdir -p "$INSTALL_DIR"
chown "$TARGET_USER":"$TARGET_USER" "$INSTALL_DIR"       # so DepotDownloader (run as the user) can write here
sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" $DD -app 380870 -branch unstable -os linux -dir "$INSTALL_DIR" \
  || die "Server download failed (Steam/DepotDownloader). Re-run to resume."
chmod +x "$INSTALL_DIR/ProjectZomboid64" "$INSTALL_DIR"/*.sh 2>/dev/null || true

# ----------------------------------------------------------------- 4. config files
step "Writing box64 + JVM configuration"
if ! grep -q '^\[ProjectZomboid64\]' /etc/box64.box64rc 2>/dev/null; then
  cat "$REPO_DIR/templates/box64rc-ProjectZomboid64.conf" >> /etc/box64.box64rc
  say "Added [ProjectZomboid64] tuning to /etc/box64.box64rc"
else
  say "box64rc already has a [ProjectZomboid64] section — left as-is"
fi
sed "s/__XMX__/${RAM_GB}g/" "$REPO_DIR/templates/ProjectZomboid64.json" > "$INSTALL_DIR/ProjectZomboid64.json"

# ----------------------------------------------------------------- 5. ciopfs dirs
step "Preparing ciopfs (case-insensitive mods)"
if [ -d "$WS" ] && [ ! -d "${WS}.ci" ]; then mv "$WS" "${WS}.ci"; fi
mkdir -p "${WS}.ci" "$WS" "$TARGET_HOME/Zomboid/mods"
chown -R "$TARGET_USER":"$TARGET_USER" "$INSTALL_DIR" "$TARGET_HOME/Zomboid" 2>/dev/null || true

# ----------------------------------------------------------------- 6. systemd + scripts
step "Installing systemd services and the pzctl control panel"
render() { sed -e "s|__USER__|$TARGET_USER|g" -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
               -e "s|__HOME__|$TARGET_HOME|g"  -e "s|__ADMIN_PW__|$ADMIN_PW|g" "$1"; }
render "$REPO_DIR/templates/zomboid-b42.service"    > /etc/systemd/system/zomboid-b42.service
render "$REPO_DIR/templates/zomboid-ciopfs.service" > /etc/systemd/system/zomboid-ciopfs.service
render "$REPO_DIR/templates/zomboid-watchdog.service" > /etc/systemd/system/zomboid-watchdog.service
cp "$REPO_DIR/templates/zomboid-watchdog.timer" /etc/systemd/system/zomboid-watchdog.timer
install -m755 "$REPO_DIR/scripts/zomboid-watchdog.sh" /usr/local/sbin/zomboid-watchdog.sh
install -m755 "$REPO_DIR/scripts/boot-retry.sh"       /usr/local/sbin/pz-boot-retry
install -m755 "$REPO_DIR/pzctl"                       /usr/local/bin/pzctl
# let pzctl / boot-retry know the environment on this host
cat > /etc/zomboid-b42.env <<EOF
PZ_SERVICE=zomboid-b42
PZ_USER=$TARGET_USER
PZ_INSTALL=$INSTALL_DIR
PZ_CONSOLE=$TARGET_HOME/Zomboid/server-console.txt
PZ_INI=$TARGET_HOME/Zomboid/Server/servertest.ini
PZ_MODS=$TARGET_HOME/Zomboid/mods
PZ_DD=$DD
EOF
systemctl daemon-reload
systemctl enable zomboid-ciopfs.service zomboid-b42.service zomboid-watchdog.timer >/dev/null 2>&1
systemctl start  zomboid-ciopfs.service

# ----------------------------------------------------------------- 7. first boot -> generate ini
step "First boot (generates server config; box64 boot is flaky so this may retry)"
PZ_CONSOLE="$TARGET_HOME/Zomboid/server-console.txt" /usr/local/sbin/pz-boot-retry || \
  warn "Server didn't reach 'listening' automatically. You can retry later with:  pzctl  (menu: Start)"

INI="$TARGET_HOME/Zomboid/Server/servertest.ini"
if [ -f "$INI" ] && [ -n "$JOIN_PW" ]; then
  sed -i "s/^Password=.*/Password=$JOIN_PW/" "$INI" 2>/dev/null || echo "Password=$JOIN_PW" >> "$INI"
  systemctl restart zomboid-b42.service
  say "Join password applied."
fi

# ----------------------------------------------------------------- done
PUBIP="$(curl -fsSL --max-time 5 ifconfig.me 2>/dev/null || echo YOUR_SERVER_IP)"
step "Done"
cat <<EOF
  Server:   $(b "$PUBIP:16261")   (UDP)
  Admin pw: $(b "$ADMIN_PW")
  $( [ -n "$JOIN_PW" ] && echo "Join pw:  $(b "$JOIN_PW")" || echo "Join pw:  (none — open server)" )

  1) Open $(b 'UDP port 16261') in your cloud firewall / security list.
  2) Manage the server anytime with:   $(b pzctl)
       start / stop / status / logs / add-mod / settings / backup

  Note: 'unstable' B42 is a moving target; if a future build breaks something,
  re-run this installer to update, or see the README troubleshooting section.
EOF
