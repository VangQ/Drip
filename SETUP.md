# Setup, from zero

Work through this once. Roughly an hour total. Nothing here needs to be redone later.

Every command below is run from **PowerShell inside this folder**. To get there:
open `C:\Users\kenne\Desktop\RDCS2Pack` in File Explorer, click the address bar,
type `powershell`, press Enter.

---

## What the pieces actually do

| Piece | Job |
|---|---|
| **This folder** | The list of which mods are in the pack. Text files, not jars. |
| **GitHub** | Stores that list online so it has a permanent home. |
| **Netlify** | Serves the list at a public web address. This is the address the cast's game reads. |
| **Prism Launcher** | What the cast plays through. Reads that address on every Play click. |
| **`drop.ps1`** | Does all of it in one command when you add a mod. |

The pack files never contain mods. They contain *download links* to mods. That's why the
cast's zip is 90 KB and why nothing you send them ever goes stale.

---

## Part 1 — Put the pack on the internet

### 1.1 Make a GitHub account

Go to [github.com](https://github.com) and sign up. Free. Skip if you have one.

### 1.2 Create an empty repository

On GitHub: **+** (top right) → **New repository**.

- Name: `rdc-season-2`
- **Private** (nobody needs to see this)
- **Do not** tick "Add a README" — the folder already has one, and ticking it causes a
  conflict on your first push

Click **Create repository**.

### 1.3 Connect this folder to it

Replace `YOUR-USERNAME`:

```bash
git remote add origin https://github.com/YOUR-USERNAME/rdc-season-2.git
```

```bash
git push -u origin main
```

A browser window opens to sign in to GitHub. Do it once; it remembers.

**Worked when:** refreshing the GitHub page shows your files instead of setup instructions.

### 1.4 Put it on Netlify

Go to [netlify.com](https://netlify.com) → **Sign up** → **GitHub** (sign in with the
account you just made, so it can see your repo).

Then: **Add new site** → **Import an existing project** → **GitHub** → pick
`rdc-season-2`.

On the settings screen, one field matters:

- **Publish directory:** `pack`

Leave build command empty. Click **Deploy**.

> This is the step that decides whether any of it works. `pack` is the subfolder holding
> `pack.toml`. Point it at the repo root instead and the cast's game gets a 404 forever.

### 1.5 Get your address

Netlify gives you something like `spontaneous-otter-4a1b.netlify.app`. Rename it under
**Site configuration → Change site name** to something you can type — `rdc-s2`.

Your pack address is that name plus `/pack.toml`:

```
https://rdc-s2.netlify.app/pack.toml
```

**Worked when:** opening that link in a browser shows text starting with
`name = "RDC Season 2"`. If you get a 404, the publish directory isn't `pack`.

---

## Part 2 — Connect your server

### 2.1 Find out which panel you have

Log into your host's control panel. Look at the URL and the layout:

- Sidebar with **Console / Files / Databases / Schedules**, address like
  `panel.something.com/server/abc12345` → **Pterodactyl**. Everything below works.
- Looks older, says **Multicraft** → no API. Skip to 2.4.

### 2.2 Get an API key (Pterodactyl only)

Click your **avatar → Account → API Credentials**. Under "Create API Key", put
`rdc-drops` as the description, leave the IP field empty, **Create**.

Copy the key immediately — it starts with `ptlc_` and is shown exactly once.

### 2.3 Get your server ID

It's in your panel URL: `panel.host.com/server/`**`abc12345`** ← that part.

### 2.4 Write your config file

```bash
Copy-Item .\scripts\config.example.ps1 .\drop.config.ps1
```

Open `drop.config.ps1` in Notepad and fill in:

- `$PackUrl` — your Netlify address from 1.5, ending in `/pack.toml`
- `$PanelUrl` — your panel address, no trailing slash, e.g. `https://panel.bisecthosting.com`
- `$PanelApiKey` — the `ptlc_…` key
- `$ServerId` — the short id

This file is gitignored, so the key never leaves your machine.

**On Multicraft:** set `$Transport = 'sftp'` and fill in the SFTP section instead. You'll
need an SSH key — if that's a wall, use `-SkipServer` on drops and upload jars through the
panel's file manager by hand. Slower, but it works.

---

## Part 3 — Set up the server

### 3.1 Install Fabric on it

In your panel there's usually a **Startup** or **Version** tab where you pick the server
type. Choose **Fabric**, Minecraft **1.21.1**, loader **0.19.3**.

If your host has no Fabric option, ask their support to install it — most will do it
for you, and it's a normal request.

### 3.2 Push the mods up for the first time

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\drop.ps1 -Mod fabric-api -SkipRestart
```

Fabric API is already in the pack, so nothing new gets added — this just runs the sync
and uploads the current mod set. That's what you want for a first run.

**Worked when:** the panel's file manager shows 4 jars in `mods/`.

### 3.3 Add PairedLife by hand

Upload `pairedlife-fabric-1.21.1-1.0.0.jar` into `mods/` through the panel file manager.

It stays outside the pack on purpose — it's your own build with no download link, and the
packwiz format can only mark something server-only if it has one. The `$KeepOnServer` line
in your config stops the sync from ever deleting it.

### 3.4 Start the server

Hit Start in the panel and watch the console. You want `Done (X.XXXs)!`.

---

## Part 4 — Send the cast their launcher

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\build-instance.ps1
```

Makes `RDC-Season-2.zip` (~90 KB). Send it to the cast along with the crew brief page.

Install Prism yourself too and import the same zip — you need to be able to test a drop
before you ask six other people to.

---

## Part 5 — Rehearse a drop before you need one

Do not let the first real drop be the first drop.

### 5.1 Dry run — changes nothing

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\drop.ps1 -Mod carry-on -DryRun
```

Prints what would happen and stops. Undo it:

```bash
git checkout -- pack/ ; git clean -fd pack/
```

### 5.2 Real drop

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\drop.ps1 -Mod carry-on
```

Watch for the `TELL THE CAST TO RELAUNCH` banner. Then quit Prism to desktop, press Play,
and confirm the sync window appears and Carry On is in Mod Menu.

### 5.3 Take it back off

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\drop.ps1 -Remove carry-on
```

Relaunch again and confirm it's gone. Now you've seen both directions work, and you know
how long a drop actually takes on your connection — which is the number you'll be
planning session breaks around.

---

## The day before each session

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\check-queue.ps1
```

Confirms every mod in `queue.txt` still exists for 1.21.1 and shows what each drags in.

Then boot each one against a copy of the world. The check proves a mod *exists*; it does
not prove it won't crash your save. This is the step that protects the session.
