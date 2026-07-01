# Project Zomboid Build 42 dedicated server on ARM (box64)

Running a **modded Project Zomboid B42 (unstable)** dedicated server on an **ARM64** box
(Oracle Cloud Ampere free tier) by emulating the x86-64 game server with
[**box64**](https://github.com/ptitSeb/box64).

This repo is the hard-won recipe: the JVM flags, the box64 tuning, the systemd units, and —
most importantly — **the dozen non-obvious failures we hit and how we fixed each one.** If
you're trying to do the same thing, this will save you a long night.

> ### Read this first — honest expectations
> This is **x86 emulated on ARM**. It *works*, but:
> - **Boot is flaky.** box64 hangs at random points during JVM startup ~30-60% of the time.
>   You need a retry loop (included) and a watchdog (included). Once it's up, it stays up.
> - **Performance is limited.** The server tick runs under emulation + a conservative GC.
>   Fine for a handful of friends on a moderate mod list; it will rubber-band under heavy
>   load (big hordes, many players, script-heavy mods). **More RAM does not fix this.**
> - **If you have an x86 host, use it.** Native x86 is dramatically smoother. This repo is
>   for people who specifically want to use a cheap/free ARM box and accept the trade-offs.

Builds on [Dyarven/zomboid-server-on-arm](https://github.com/Dyarven/zomboid-server-on-arm),
which covers **B41**. B42 bundles a newer JVM (Java 25) and behaves differently under box64 —
this repo documents what changes for B42.

---

## What we ran it on
- **Oracle Cloud Ampere A1** (ARM Neoverse-N1), 4 vCPU, 24 GB RAM — free tier
- **Ubuntu 24.04 LTS** (aarch64)
- **box64** (+ box86) for x86 emulation
- **PZ Build 42 "unstable"** dedicated server (Steam app `380870`), which bundles **Java 25 (Zulu)**
- **ciopfs**, **DepotDownloader** (see below)

---

## The 12 problems we hit (and the fix for each)

This table is the reason the repo exists. Details for the tricky ones follow.

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `steamcmd` hangs at "Checking for available update", 0% CPU | steamcmd's 32-bit self-updater breaks under box86 on ARM | Download with **[DepotDownloader](https://github.com/SteamRE/DepotDownloader)** (native ARM). It doesn't `chmod +x` — set it yourself |
| 2 | JVM deadlocks partway through boot | box64 `STRONGMEM` too low for the multithreaded JVM | `BOX64_DYNAREC_STRONGMEM=3` in `/etc/box64.box64rc` **and** matching `Environment=` in the unit |
| 3 | JVM freezes / crashes under load | **ZGC** deadlocks under box64 | `-XX:+UseSerialGC` (plus `-XX:-UseCompressedOops -XX:TieredStopAtLevel=1 -XX:ActiveProcessorCount=2`) |
| 4 | Client: **"server did not respond"** even though ports are open | Server was `-Dzomboid.steam=0` (ZNetNoSteam); a Steam client can only join a *Steam* server | `-Dzomboid.steam=1` |
| 5 | Mods "no such file" | With `WorkshopItems=` set, PZ reads mods from the **workshop path**, not `~/Zomboid/mods` | Put workshop mods under `steamapps/workshop/content/108600/<id>/mods/...` |
| 6 | Clothing invisible / "no such model" / **JVM crash on unequip** | **Linux is case-sensitive; Windows isn't** — mods ship with inconsistent casing that only works on Windows | **[ciopfs](https://www.brain-dump.org/projects/ciopfs/)** case-insensitive FUSE overlay over the workshop dir. **Do NOT lowercase the files** — that breaks in-file references |
| 7 | Server never restarts after a crash | `start-server.sh` always `exit 0`, so systemd `on-failure` never fires | `Restart=always` |
| 8 | **SIGSEGV when a player joins** | box64 JIT mis-compiles one hot animation method | `-XX:CompileCommand=exclude,zombie/core/skinnedmodel/advancedanimation/IAnimationVariableRegistry.setVariable` |
| 9 | Log spam / perf collapse from certain mods | Some mods throw hundreds of exceptions or drive heavy per-tick work under emulation | Remove them (we dropped a computer mod and a character-customization mod that each spammed exceptions) |
| 10 | **Adding a new mod → boot crash-loop** (`EResult 33`, then an NPE) | With `steam=1`, the server tries to **Steam-download** every `WorkshopItems=` id; a newly-added id fails to write into the ciopfs mount (`k_EResultLockingFailed`) → NPE in `GameServerWorkshopItems.Install` | **Install added mods as LOCAL mods** — see [Adding mods](#adding-mods-the-important-one) |
| 11 | Watchdog kills healthy boots | A CPU-only hang detector fires during the low-CPU "Waiting for response from Steam servers" phase | **Hybrid** detection: restart only if console silent >6 min **AND** CPU idle |
| 12 | Boot succeeds only sometimes | box64 boot is inherently flaky | `boot-retry.sh` (auto-retry with real-hang detection) + the watchdog timer |

### #6 — the case-sensitivity fix (ciopfs), in detail
Most modders on Linux either give up or `tr A-Z a-z` the filenames — which breaks, because a
mod's own Lua/XML references the original mixed-case names. The clean fix is a **case-insensitive
filesystem view**:

```bash
sudo apt install ciopfs
# backing store holds the real (lowercased-internally) files:
mv .../content/108600 .../content/108600.ci
mkdir .../content/108600
# present it case-insensitively at the path PZ expects:
ciopfs -o allow_other .../content/108600.ci .../content/108600
```
The `zomboid-ciopfs.service` unit does this at boot, and `zomboid-b42.service` `Requires=` it.

### #8 — the box64 JIT crash, in detail
On player join the JVM took a SIGSEGV inside a skinned-model animation method. It's a box64
dynarec mis-translation of that specific hot method. You can't fix box64 easily, but you can
tell the JVM **not to JIT-compile that one method** and run it interpreted instead:
```
-XX:CompileCommand=exclude,zombie/core/skinnedmodel/advancedanimation/IAnimationVariableRegistry.setVariable
```
Negligible perf cost, and the crash is gone.

### #10 — adding mods (the important one)
This one cost us a night. With `-Dzomboid.steam=1`, on every boot the server walks the
`WorkshopItems=` list and asks the Steam client to (re)download anything it doesn't consider
installed. The 56 mods we downloaded early were tracked in Steam's `appworkshop_108600.acf`, so
Steam skipped them. But a **newly added** mod (fetched with DepotDownloader, so absent from that
manifest) triggers a Steam download **into the ciopfs mount**, which fails to acquire a write
lock → `EResult 33 (k_EResultLockingFailed)` → NPE in `GameServerWorkshopItems.Install` → the
server exits mid-boot and, thanks to `Restart=always`, loops forever. The tell-tale symptom is a
misleading shutdown-save NPE: `Cannot invoke "zombie.iso.IsoMetaGrid.save()" because "this.grid" is null`.

**The reliable workaround → install added mods as LOCAL mods:**
1. Put the mod folder in `~/Zomboid/mods/<ModFolder>/` (PZ always scans this path; Steam never touches it).
2. Add the real mod **id** (from the mod's `mod.info`, e.g. folder `[B42] Faster Reading` has `id=Faster Reading`) to `Mods=`.
3. Do **NOT** add its workshop id to `WorkshopItems=`.

Trade-off: local mods aren't auto-downloaded by clients, so **each player must manually subscribe**
to that mod on the Workshop. For a mod or two that's fine.

---

## Setup outline

> Assumes box64 + box86 are already installed (see the Dyarven repo). Paths below match the
> systemd units in [`systemd/`](systemd/); adjust to taste.

1. **Download the server** with DepotDownloader (native ARM):
   ```bash
   ./DepotDownloader -app 380870 -branch unstable -os linux -dir /opt/zomboid-server
   chmod +x /opt/zomboid-server/ProjectZomboid64 /opt/zomboid-server/*.sh
   ```
2. **box64 tuning** — append [`config/box64rc-ProjectZomboid64.conf`](config/box64rc-ProjectZomboid64.conf) to `/etc/box64.box64rc`.
3. **JVM flags** — replace `/opt/zomboid-server/ProjectZomboid64.json` with [`config/ProjectZomboid64.json`](config/ProjectZomboid64.json) (set `-Xmx` to your RAM).
4. **First run** to generate `~/Zomboid/Server/servertest.ini`, then set `Mods=`, `WorkshopItems=`, `Map=`, `Password=`, `DefaultPort=16261`. Keep `-Dzomboid.steam=1`.
5. **Mods** — DepotDownloader each workshop item into `steamapps/workshop/content/108600/<id>` (`-app 108600 -pubfile <id> -dir ...`), then set up **ciopfs** (#6). Add *new* mods the local way (#10).
6. **Install the units** from [`systemd/`](systemd/) into `/etc/systemd/system/`, the scripts from [`scripts/`](scripts/) into `/usr/local/sbin/` (`chmod +x`), set your admin password in `zomboid-b42.service`, then:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now zomboid-ciopfs.service zomboid-b42.service zomboid-watchdog.timer
   ```
7. **Bring it up** — box64 boot is flaky, so use the retry loop:
   ```bash
   bash scripts/boot-retry.sh     # restarts until UDP :16261 is listening
   ```
8. Open **UDP 16261** in your cloud firewall / security list.

---

## Operating it
- **Is it up?** `ss -uln | grep 16261` (listening = ready) and look for `*** SERVER STARTED ****` in `~/Zomboid/server-console.txt`.
- **A boot hung?** Confirm it's a *real* hang (console silent for minutes **and** CPU idle) before killing it — a slow Steam-registration or a silent-but-high-CPU asset load is not a hang. `boot-retry.sh` and the watchdog both check both signals.
- **Watchdog** runs every 3 min and restarts only a genuinely hung boot. See [`scripts/zomboid-watchdog.sh`](scripts/zomboid-watchdog.sh).

## If it's laggy
In rough order of impact: reduce zombie population, drop script-heavy/error-spammy mods, keep
the mod count sane, keep `-XX:+UseSerialGC` (other GCs were worse under box64). Ultimately,
emulation has a ceiling — a native x86 host is the real fix for large groups.

---

## What's in here
```
config/
  ProjectZomboid64.json              JVM launch flags (the SerialGC + JIT-exclude recipe)
  box64rc-ProjectZomboid64.conf      box64 [ProjectZomboid64] tuning block
systemd/
  zomboid-b42.service                the server (box64 env, Restart=always)
  zomboid-ciopfs.service             case-insensitive mod mount (must start first)
  zomboid-watchdog.service/.timer    hybrid boot-hang watchdog, every 3 min
scripts/
  zomboid-watchdog.sh                real-hang detector (console-static AND cpu-idle)
  boot-retry.sh                      restart-until-listening with hang detection
```

## Credits
- [Dyarven/zomboid-server-on-arm](https://github.com/Dyarven/zomboid-server-on-arm) — the B41 groundwork
- [box64](https://github.com/ptitSeb/box64) by ptitSeb — the emulator that makes this possible
- [DepotDownloader](https://github.com/SteamRE/DepotDownloader), [ciopfs](https://www.brain-dump.org/projects/ciopfs/)

## Disclaimer
Provided as-is (MIT). Not affiliated with The Indie Stone. "Unstable" B42 is a moving target;
flag names and behavior may shift between builds.
