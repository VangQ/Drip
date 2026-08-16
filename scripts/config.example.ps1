# Copy this to  drop.config.ps1  (repo root) and fill it in.
# drop.config.ps1 is gitignored - it holds your panel API key. Never commit it.

# ---- Pack hosting -----------------------------------------------------------
# The public URL of pack.toml. This is what the cast's Prism instance points at.
# Use a host that does NOT cache aggressively. Netlify serves
# "max-age=0, must-revalidate" and is the recommended option.
# Do NOT use raw.githubusercontent.com - it sends max-age=300, so during a live
# drop some of the cast will silently get the previous pack for five minutes.
$PackUrl = 'https://rdc-s2.netlify.app/pack.toml'

# ---- Server panel (Pterodactyl / Bisect Games panel) ------------------------
# Client API key: panel -> Account -> API Credentials. Starts with "ptlc_".
$PanelUrl    = 'https://panel.bisecthosting.com'
$PanelApiKey = 'ptlc_REPLACE_ME'
$ServerId    = 'abc12345'          # the short id in the panel URL

# ---- Mod transport ----------------------------------------------------------
# 'panel' = upload through the Pterodactyl API using the key above (no SSH key
#           needed, works on hosts that only give you a password).
# 'sftp'  = OpenSSH sftp. Needs key-based auth; password prompts will hang the
#           script mid-drop, which is the last thing you want live.
$Transport = 'panel'

# Only used when $Transport = 'sftp'
$SftpHost = 'node123.bisecthosting.com'
$SftpPort = 2022
$SftpUser = 'yourname.abc12345'
$SftpKey  = "$env:USERPROFILE\.ssh\id_ed25519"

# Remote path to the server's mods folder, relative to the server root.
$RemoteModsDir = 'mods'

# ---- Mods the sync must never delete ----------------------------------------
# drop.ps1 mirrors the pack to the server, so anything on the server that the
# pack doesn't know about would normally be removed. Server-only jars that you
# build yourself live here.
#
# PairedLife is deliberately NOT in the packwiz pack: packwiz can only set
# side="server" on metafiles that point at a URL, and PairedLife is a local
# build with no Modrinth page. Listing it here keeps it safe.
$KeepOnServer = @(
    'pairedlife-*.jar'
)
