# 🧟 Project Zomboid B42 server on ARM — the easy way

Spin up a **modded Project Zomboid Build 42** dedicated server on a cheap (or **free**) **ARM64**
box — like an **Oracle Cloud Ampere** VM — with **one command**. Then run everything from a
simple terminal menu. No fiddling with JVM flags, box64 tuning, or Steam downloaders — the
installer handles all of it.

> **Why ARM / box64?** The PZ server is x86-only, so on an ARM CPU it has to be emulated with
> [box64](https://github.com/ptitSeb/box64). That normally means a long night of cryptic
> crashes — this repo packages the fixes so you skip straight to playing.

---

## 🚀 Quick start

On a fresh **Ubuntu 22.04/24.04 (ARM64)** server:

```bash
git clone https://github.com/kaanzapkinus/zomboid-b42-on-arm.git
cd zomboid-b42-on-arm
sudo ./install.sh
```

Answer three questions (admin password, join password, RAM). The installer does the rest —
installs box64, downloads the B42 server, applies every fix, sets up auto-restart, and boots it.

When it finishes, **open UDP port `16261`** in your cloud firewall, and you're live. 🎉

---

## 🎮 Managing your server: `pzctl`

Everything is one menu. Just run:

```bash
pzctl
```

```
  Project Zomboid B42  —  pzctl
  ------------------------------------------
  service: active    state: LISTENING (players can join)
  ------------------------------------------
   1) Start / bring up        6) Add a mod
   2) Stop                    7) List / remove mods
   3) Restart                 8) Settings (name/pw/players/RAM)
   4) Status                  9) Backup world
   5) Live logs               0) Exit
```

### Adding a mod is one step
Menu → **6**, paste the Workshop link (or ID), done:
```
? Workshop URL or ID: https://steamcommunity.com/sharedfiles/filedetails/?id=3713362869
  + installed mod id: Faster Reading
```
Then **Restart** (menu → 3). Tell your friends to **subscribe** to that mod on the Workshop —
that's the only manual step, and `pzctl` prints the exact link for you.

---

## ✅ Requirements
- An **ARM64** (`aarch64`) server running **Ubuntu** with **systemd** (Oracle Ampere free tier is perfect: 4 cores / 24 GB).
- **UDP 16261** open in your cloud firewall / security list.
- That's it. The installer pulls in everything else (box64, ciopfs, DepotDownloader).

## 🔁 Keeping it alive
The installer sets up **auto-restart** and a **watchdog**, so the server comes back on its own
after a crash, a hung boot, or a reboot. You normally never touch it after install.

---

<details>
<summary><b>🛠️ For the curious — what this actually does, and the problems it solves</b></summary>

### Honest expectations
This is **x86 emulated on ARM**. It runs great for you and a group of friends, but:
- **Boot is flaky** — box64 hangs at random points during JVM startup. The included retry loop
  and watchdog handle this automatically; you just wait a few minutes on first boot.
- **Performance is emulated** — fine for a moderate mod list and a handful of players; it can
  rubber-band under heavy load (huge hordes, many players, script-heavy mods). **More RAM does
  not fix this** — it's the emulation ceiling. For a large public server, use a native x86 host.

### The dozen problems this package solves for you
Getting B42 to run modded on ARM by hand means hitting all of these. The installer/`pzctl`
handle every one:

| # | Problem | Fix baked in |
|---|---|---|
| 1 | `steamcmd` won't run on ARM | Uses **DepotDownloader** (native ARM) instead |
| 2 | JVM deadlocks at boot | `BOX64_DYNAREC_STRONGMEM=3` |
| 3 | Freezes/crashes under load | `-XX:+UseSerialGC` (ZGC deadlocks under box64) + tuned flags |
| 4 | Clients get "server did not respond" | `-Dzomboid.steam=1` |
| 5 | Mods "no such file" | Mods placed in the workshop path PZ actually reads |
| 6 | Clothing bug / crash on unequip (Linux case-sensitivity) | **ciopfs** case-insensitive overlay |
| 7 | Server won't restart after a crash | `Restart=always` (start script masks crashes) |
| 8 | SIGSEGV when a player joins | `-XX:CompileCommand=exclude,…` for the mis-compiled method |
| 9 | Some mods spam errors / tank performance | Guidance + easy remove via `pzctl` |
| 10 | **Adding a mod crash-loops the server** (`EResult 33`) | `pzctl` installs new mods as **local mods** (no Steam re-download) |
| 11 | Watchdog kills healthy boots | **Hybrid** hang detection (console-static **and** CPU-idle) |
| 12 | Boot only succeeds sometimes | `pz-boot-retry` restarts until it's actually listening |

A few worth expanding:

- **#6 ciopfs** — Windows filesystems are case-insensitive; Linux isn't, so mods with mixed-case
  filenames render broken clothing/models and even crash the JVM. We mount the workshop folder
  through [ciopfs](https://www.brain-dump.org/projects/ciopfs/) so it behaves like Windows.
  (Lowercasing the files instead **breaks** them — mods reference their own original casing.)
- **#8 the JIT crash** — box64's dynarec mis-translates one hot animation method; joining a
  player would SIGSEGV. Telling the JVM to run just that method interpreted
  (`-XX:CompileCommand=exclude,zombie/core/skinnedmodel/advancedanimation/IAnimationVariableRegistry.setVariable`)
  fixes it at ~zero cost.
- **#10 adding mods** — with `steam=1` the server tries to *Steam-download* every `WorkshopItems=`
  entry on boot; a freshly added one fails to write into the ciopfs mount (`EResult 33`,
  LockingFailed) and NPE-crashes in a loop. `pzctl` sidesteps this by installing added mods as
  **local mods** (`~/Zomboid/mods/`, in `Mods=` but not `WorkshopItems=`). Trade-off: players
  subscribe to those mods manually.

### What's in the repo
```
install.sh              one-shot installer (arch-checked, interactive)
pzctl                   interactive control panel (start/stop/mods/settings/backup)
templates/              JVM config, box64 tuning, systemd units (filled in at install)
scripts/
  zomboid-watchdog.sh   hybrid boot-hang watchdog
  boot-retry.sh         restart-until-listening (installed as pz-boot-retry)
```

### Credits
Builds on [Dyarven/zomboid-server-on-arm](https://github.com/Dyarven/zomboid-server-on-arm)
(which covers **B41**); B42 bundles a newer JVM and needed a different recipe.
Powered by [box64](https://github.com/ptitSeb/box64),
[DepotDownloader](https://github.com/SteamRE/DepotDownloader), and
[ciopfs](https://www.brain-dump.org/projects/ciopfs/).

</details>

---

*MIT licensed. Not affiliated with The Indie Stone. "Unstable" B42 changes often — if a build
breaks something, re-run `sudo ./install.sh` to update.*
