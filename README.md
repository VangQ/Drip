# RDC Season 2 — live mod-drop pack

Fabric **1.21.1**, Fabric Loader **0.19.3**. A new mod drops every couple of hours,
live, and the whole cast picks it up by quitting to desktop and pressing Play.

```
  you run drop.ps1
        │
        ├─ packwiz adds the mod + resolves its dependencies
        ├─ git push ──────────────► Netlify ──────► cast's Prism auto-syncs on Play
        └─ server jars uploaded ──► panel API ────► server restarts
```

---

## One-time setup

**1. Tools**

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\setup-tools.ps1
```

**2. Host the pack**

Create a GitHub repo, push this folder, then connect it to Netlify with
**publish directory = `pack`**. You want `https://<site>.netlify.app/pack.toml` to load.

> Do **not** use `raw.githubusercontent.com`. It sends `Cache-Control: max-age=300`,
> so during a live drop part of the cast silently gets the previous pack for five
> minutes and desyncs from the server. Netlify sends `max-age=0, must-revalidate`.

**3. Config**

Copy `scripts/config.example.ps1` to `drop.config.ps1` in the repo root and fill in
your pack URL, panel URL, client API key (`ptlc_…`) and server id. It's gitignored.

**4. Build the cast instance**

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\build-instance.ps1
```

Produces `RDC-Season-2.zip` (~90KB, contains no mods — it can't go stale). Send it once.
Each person: install Prism → Add Instance → Import from zip → Play.

**5. Server**

Install Fabric Loader 0.19.3 on the host, then run one drop with `-SkipRestart` to
populate `mods/`. Put `pairedlife-*.jar` in `mods/` by hand — it's deliberately not in
the packwiz pack (packwiz can only mark `side = "server"` on entries that point at a
URL, and PairedLife is a local build). `$KeepOnServer` protects it from the sync.

---

## Session day

**The day before:**

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\check-queue.ps1
```

Confirms every candidate still has a 1.21.1 Fabric build, and shows what each one
drags in as dependencies. Then **boot each one against a copy of the world.** The
validator proves a mod exists; it does not prove it won't crash your save.

**During:**

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\drop.ps1 -Mod carry-on
```

Wait for the `TELL THE CAST TO RELAUNCH` banner, then say the line. Budget ~5 minutes
of dead air per drop: ~60s server restart, ~2–3min for everyone to quit, relaunch,
sync and rejoin.

Useful flags:

| Flag | Use it when |
|---|---|
| `-DryRun` | Rehearsing. Touches the local pack only, publishes nothing. |
| `-SkipServer` | Cast is mid-fight. Pack goes live, server untouched — **don't** tell anyone to relaunch yet. |
| `-SkipRestart` | You want to time the restart yourself. |
| `-Remove <slug>` | Taking a mod away as a bit. |
| `-Source curseforge` | Mod isn't on Modrinth. |

---

## Rules that will save a session

**Never change the Minecraft or Fabric Loader version mid-season.** Prism 9.4+ reads
`mmc-pack.json` *before* running the pre-launch command
([#3944](https://github.com/PrismLauncher/PrismLauncher/issues/3944) → #4126), so
packwiz physically cannot push a loader bump. Mods are fine; the loader is frozen.

**Never pick a drop mod live.** An untested jar going into a live world with the whole
cast on camera is how you lose the session. The reveal is live. The choice is not.

**Worldgen mods are already in the base pack.** Anything tagged `WORLDGEN` by
`check-queue.ps1` only affects unexplored chunks, so as a live drop the reveal lands on
nothing. `queue.txt` keeps those commented out with a note.

**Client-only mods need no server restart.** `drop.ps1` tells you when a drop is
client-only — that's a much cheaper beat when you want a moment without stopping
everything.

---

## When it goes wrong

**One person can't join: "Registry remapping failed! Received ID map contains IDs
unknown to the receiver!"**
They didn't actually relaunch, or they closed the sync window early. Quit to desktop —
all the way out, not just to the title screen — and press Play again.

**"hash invalid" for everyone.** `.gitattributes` lost its `* -text`. Line-ending
conversion changed the packwiz hashes. Restore it and run `git add --renormalize .`.

**Sync window never appears.** `OverrideCommands=true` is missing from `instance.cfg`,
or the paths in `PreLaunchCommand` aren't absolute. Prism runs pre-launch commands in
the *launcher's* working folder, and `--pack-folder` defaults to `.` — without absolute
paths the mods install into the Prism directory and the instance stays empty.

**Server won't boot after a drop.** Roll back and move on, don't debug live:

```bash
git revert --no-edit HEAD
powershell -ExecutionPolicy Bypass -File .\scripts\drop.ps1 -Mod noop -SkipServer
```

Faster: delete the new jar from the server's `mods/` in the panel file manager and
restart. Fix the pack after the session.

---

## Layout

```
pack/                 the published pack — this is what Netlify serves
  pack.toml           1.21.1 / Fabric 0.19.3
  mods/*.pw.toml      one metafile per mod, with auto-detected client/server side
prism-instance/       template for the cast's zip; __PACK_URL__ is substituted at build
serverpack/           materialised server-side jars (gitignored, rebuilt each drop)
scripts/              setup-tools, check-queue, drop, build-instance
queue.txt             the vetted drop queue, tiered by on-camera impact
.gitattributes        load-bearing — see the file
```

## Base pack

Foundation only. Performance stack sized for people recording and streaming on top of
a modded client:

`fabric-api` · `sodium` · `lithium` · `ferrite-core` · `entityculling` ·
`immediatelyfast` · `modmenu` (+ `placeholder-api`, pulled in by Mod Menu)

Add your worldgen and biome mods here before world creation. Mod Menu is in on purpose —
"open Mod Menu and see what showed up" is a usable on-camera beat.
