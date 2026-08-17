<#
.SYNOPSIS
    Drop a new mod into RDC Season 2, live.

.DESCRIPTION
    One command, start to finish:
        add to pack -> resolve deps -> commit -> push -> sync server -> restart

    Run it, wait for the "TELL THE CAST TO RELAUNCH" banner, then say the line.

.EXAMPLE
    .\scripts\drop.ps1 -Mod naturalist
    .\scripts\drop.ps1 -Mod "https://modrinth.com/mod/mutant-monsters"
    .\scripts\drop.ps1 -Mod supplementaries -Source curseforge
    .\scripts\drop.ps1 -Mod naturalist -DryRun
    .\scripts\drop.ps1 -Remove naturalist
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Add', Mandatory = $true, Position = 0)]
    [string]$Mod,

    [Parameter(ParameterSetName = 'Remove', Mandatory = $true)]
    [string]$Remove,

    [ValidateSet('modrinth', 'curseforge', 'github')]
    [string]$Source = 'modrinth',

    [string]$Message,

    # Stop after the pack is updated. Nothing is pushed, synced or restarted.
    [switch]$DryRun,

    # Update the pack and push, but leave the server alone. Use when the cast is
    # mid-fight and you want the drop staged for the next natural break.
    [switch]$SkipServer,

    # Sync the server files but don't restart it yourself.
    [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$PackDir     = Join-Path $RepoRoot 'pack'
$ServerPack  = Join-Path $RepoRoot 'serverpack'
$Packwiz     = Join-Path $RepoRoot '.tools\packwiz.exe'
$Bootstrap   = Join-Path $ServerPack 'packwiz-installer-bootstrap.jar'
$ConfigFile  = Join-Path $RepoRoot 'drop.config.ps1'

# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
$script:StepNo = 0
function Step([string]$Text) {
    $script:StepNo++
    Write-Host ''
    Write-Host "[$script:StepNo] $Text" -ForegroundColor Cyan
}
function Ok  ([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Note([string]$Text) { Write-Host "    $Text" -ForegroundColor DarkGray }
function Warn([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }
function Die ([string]$Text) {
    Write-Host ''
    Write-Host "  ABORTED: $Text" -ForegroundColor Red
    Write-Host ''
    exit 1
}

# --------------------------------------------------------------------------
# preflight - everything that can fail cheaply, fails here, before we touch
# anything the cast can see
# --------------------------------------------------------------------------
Step 'Preflight'

if (-not (Test-Path $Packwiz))   { Die "packwiz missing. Run: .\scripts\setup-tools.ps1" }
if (-not (Test-Path $ConfigFile)) {
    Die "drop.config.ps1 not found. Copy scripts\config.example.ps1 to drop.config.ps1 and fill it in."
}
. $ConfigFile

foreach ($required in 'PackUrl', 'PanelUrl', 'PanelApiKey', 'ServerId', 'Transport', 'RemoteModsDir', 'KeepOnServer') {
    if (-not (Get-Variable -Name $required -ErrorAction SilentlyContinue)) {
        Die "drop.config.ps1 is missing `$$required"
    }
}
if ($PanelApiKey -like '*REPLACE_ME*') { Die "drop.config.ps1 still has the placeholder API key in it." }
if ($PanelUrl -match '/server/') { Die "`$PanelUrl must be just the domain, not the full address bar. Use $(($PanelUrl -split '/server/')[0])" }

# --------------------------------------------------------------------------
# Refuse to touch a server that isn't Minecraft.
#
# One panel account can hold servers for several games. This script uploads
# jars, deletes files it doesn't recognise, and issues a restart - all of which
# are destructive against the wrong target, and a running game server full of
# other people is exactly the wrong target. A server id is one mistyped
# character away from a different game.
# --------------------------------------------------------------------------
function Assert-MinecraftServer {
    param($Headers)

    if (-not $ServerId) {
        Die "`$ServerId is blank in drop.config.ps1. Set it to your Minecraft server's id (the code in the panel URL after /server/)."
    }

    try {
        $srv = Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId" -Headers $Headers -Method Get -TimeoutSec 20
    }
    catch { Die "cannot reach server '$ServerId' on $PanelUrl - $($_.Exception.Message)" }

    if ($srv.object -ne 'server' -or -not $srv.attributes.identifier) {
        Die "$PanelUrl did not return Pterodactyl data. It should be just the domain, e.g. https://games.bisecthosting.com"
    }
    $name = $srv.attributes.name

    try {
        $root = Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId/files/list?directory=%2F" `
                                  -Headers $Headers -Method Get -TimeoutSec 20
    }
    catch { Die "cannot list the root of '$name' ($ServerId) - $($_.Exception.Message)" }

    $names = @($root.data | ForEach-Object { $_.attributes.name })

    # name the game we actually found, so the error is obvious rather than cryptic
    $other = $null
    if     ($names -contains 'PalServer.exe' -or $names -contains 'PalServer.sh') { $other = 'Palworld' }
    elseif ($names -contains 'pzexe.jar' -or $names -match '^ProjectZomboid')      { $other = 'Project Zomboid' }
    elseif ($names -contains 'srcds_run' -or $names -contains 'srcds.exe')         { $other = 'a Source engine game' }
    elseif ($names -contains 'bedrock_server' -or $names -contains 'bedrock_server.exe') { $other = 'Minecraft Bedrock (this pack is Java)' }

    if ($other) {
        Die "server '$name' ($ServerId) is running $other, not Minecraft Java.`n  Refusing to upload mods or restart it. Fix `$ServerId in drop.config.ps1."
    }

    $isMinecraft = ($names -contains 'server.properties') -or
                   ($names -contains 'mods') -or
                   ($names -match 'fabric.*\.jar')
    if (-not $isMinecraft) {
        Die "server '$name' ($ServerId) has no Minecraft markers (no server.properties, no mods/, no fabric jar).`n  If it's brand new, install Fabric and start it once so those exist, then run this again."
    }

    Ok "target verified: '$name' ($ServerId) is a Minecraft server"
}

Push-Location $RepoRoot
try {
    $dirty = & git status --porcelain 2>&1
    if ($LASTEXITCODE -ne 0) { Die "not a git repo, or git failed: $dirty" }
    if ($dirty) {
        Warn 'Working tree is dirty going in:'
        $dirty | ForEach-Object { Note "  $_" }
        Warn 'Those changes will be committed along with this drop.'
    }
} finally { Pop-Location }

Ok "pack -> $PackUrl"

# Verify the target BEFORE anything is committed or pushed, so a wrong server id
# costs you nothing instead of leaving a published pack the server never gets.
if ($DryRun -or $SkipServer) {
    Note "server checks skipped ($(if ($DryRun) { 'DryRun' } else { 'SkipServer' }))"
}
else {
    Assert-MinecraftServer -Headers @{
        'Authorization' = "Bearer $PanelApiKey"
        'Accept'        = 'Application/vnd.pterodactyl.v1+json'
        'Content-Type'  = 'application/json'
    }
}
if ($DryRun) { Warn 'DRY RUN - nothing will be pushed, synced or restarted.' }

# --------------------------------------------------------------------------
# snapshot the mod list so we can report exactly what the drop pulled in,
# including transitive dependencies the cast will also receive
# --------------------------------------------------------------------------
function Get-ModSlugs {
    if (-not (Test-Path (Join-Path $PackDir 'mods'))) { return @() }
    return @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Name -replace '\.pw\.toml$', '' })
}
$before = Get-ModSlugs

# --------------------------------------------------------------------------
# mutate the pack
# --------------------------------------------------------------------------
Push-Location $PackDir
try {
    if ($PSCmdlet.ParameterSetName -eq 'Remove') {
        Step "Removing '$Remove' from the pack"
        $out = & $Packwiz remove $Remove -y 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Die "packwiz remove failed:`n$out" }
        Ok $out.Trim()
        $action = "remove $Remove"
    }
    else {
        Step "Adding '$Mod' from $Source"
        $out = & $Packwiz $Source add $Mod -y 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Die "packwiz $Source add failed:`n$out" }
        Ok $out.Trim()
        $action = "add $Mod"
    }

    Step 'Refreshing index'
    $out = & $Packwiz refresh 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Die "packwiz refresh failed:`n$out" }
    Ok 'index.toml rehashed'
}
finally { Pop-Location }

# --------------------------------------------------------------------------
# report the real delta
# --------------------------------------------------------------------------
$after = Get-ModSlugs
$added   = @($after | Where-Object { $before -notcontains $_ })
$dropped = @($before | Where-Object { $after  -notcontains $_ })

Step 'Change summary'
if ($added.Count -eq 0 -and $dropped.Count -eq 0) {
    Warn 'Nothing changed. That mod was probably already in the pack.'
}
foreach ($a in $added)   { Ok   "+ $a" }
foreach ($d in $dropped) { Warn "- $d" }

# Anything added beyond what you asked for is a dependency. Worth seeing, because
# a "one mod" drop that quietly pulls in four libraries is a bigger download than
# you promised the cast.
$requested = $Mod
if ($PSCmdlet.ParameterSetName -eq 'Remove') { $requested = $Remove }
$extra = @($added | Where-Object { $requested -notlike "*$_*" })
if ($extra.Count -gt 0) { Note "($($extra.Count) of those are dependencies)" }

# side breakdown - a client-only drop needs no server restart at all
$clientOnly = 0
$serverSide = 0
foreach ($slug in $added) {
    $meta = Get-Content (Join-Path $PackDir "mods\$slug.pw.toml") -Raw -ErrorAction SilentlyContinue
    if ($meta -match 'side\s*=\s*"client"') { $clientOnly++ } else { $serverSide++ }
}
if ($added.Count -gt 0 -and $serverSide -eq 0) {
    Note 'All client-side. The server does not strictly need a restart for this one.'
}

if ($DryRun) {
    Write-Host ''
    Warn 'DRY RUN complete. Pack was modified locally but nothing was published.'
    Note 'Undo with:  git checkout -- pack/  ;  git clean -fd pack/'
    exit 0
}

# --------------------------------------------------------------------------
# publish
# --------------------------------------------------------------------------
Step 'Publishing pack'
if (-not $Message) { $Message = "drop: $action" }

Push-Location $RepoRoot
try {
    & git add -A pack/ 2>&1 | Out-Null
    $staged = & git diff --cached --name-only 2>&1
    if (-not $staged) {
        Warn 'Nothing staged - skipping commit.'
    }
    else {
        $out = & git commit -m $Message 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Die "git commit failed:`n$out" }
        Ok "committed: $Message"

        $out = & git push 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Die "git push failed - the cast will NOT get this drop:`n$out" }
        Ok 'pushed'
    }
}
finally { Pop-Location }

if ($SkipServer) {
    Write-Host ''
    Warn 'SkipServer set - pack is live for clients but the server was not touched.'
    Warn 'Do NOT tell the cast to relaunch yet; they would desync from the server.'
    exit 0
}

# --------------------------------------------------------------------------
# materialise the server side
#
# Reads the LOCAL pack.toml, not $PackUrl, so this does not wait on the CDN
# deploy. Side filtering means client-only mods never touch the server.
# --------------------------------------------------------------------------
Step 'Building server mod set'

if (-not (Test-Path $Bootstrap)) { Die "bootstrap jar missing at $Bootstrap. Run: .\scripts\setup-tools.ps1" }

$localPackToml = Join-Path $PackDir 'pack.toml'
$out = & java -jar $Bootstrap -g -s server --pack-folder $ServerPack $localPackToml 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Die "packwiz-installer failed building the server set:`n$out" }

$serverMods = @(Get-ChildItem (Join-Path $ServerPack 'mods') -Filter '*.jar' -ErrorAction SilentlyContinue)
Ok "$($serverMods.Count) server-side jars staged"

# --------------------------------------------------------------------------
# push mods to the host
# --------------------------------------------------------------------------
Step "Syncing to server via $Transport"

$panelHeaders = @{
    'Authorization' = "Bearer $PanelApiKey"
    'Accept'        = 'Application/vnd.pterodactyl.v1+json'
    'Content-Type'  = 'application/json'
}

function Get-RemoteMods {
    $uri = "$PanelUrl/api/client/servers/$ServerId/files/list?directory=/$RemoteModsDir"
    $res = Invoke-RestMethod -Uri $uri -Headers $panelHeaders -Method Get
    return @($res.data | Where-Object { $_.attributes.name -like '*.jar' } |
             ForEach-Object { $_.attributes.name })
}

function Test-Protected([string]$Name) {
    foreach ($pattern in $KeepOnServer) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

if ($Transport -eq 'panel') {
    # signed one-shot upload URL, then multipart POST via curl.exe
    $signed = Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId/files/upload" `
                                -Headers $panelHeaders -Method Get
    $uploadUrl = $signed.attributes.url

    try   { $remote = Get-RemoteMods }
    catch { Die "could not list remote mods - check PanelUrl / ServerId / API key: $($_.Exception.Message)" }

    $uploaded = 0
    foreach ($jar in $serverMods) {
        if ($remote -contains $jar.Name) { continue }
        $target = "$uploadUrl&directory=/$RemoteModsDir"
        $res = & curl.exe -s -S -o NUL -w '%{http_code}' -X POST $target -F "files=@$($jar.FullName)" 2>&1
        if ($res -ne '200') { Die "upload of $($jar.Name) failed (HTTP $res)" }
        Ok "uploaded $($jar.Name)"
        $uploaded++
    }
    if ($uploaded -eq 0) { Note 'no new jars to upload' }

    # remove anything the pack no longer wants, except protected jars
    $localNames = @($serverMods | ForEach-Object { $_.Name })
    $toDelete = @($remote | Where-Object { $localNames -notcontains $_ -and -not (Test-Protected $_) })
    $protectedHits = @($remote | Where-Object { Test-Protected $_ })
    foreach ($k in $protectedHits) { Note "keeping $k (protected)" }

    if ($toDelete.Count -gt 0) {
        $body = @{ root = "/$RemoteModsDir"; files = $toDelete } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId/files/delete" `
                          -Headers $panelHeaders -Method Post -Body $body | Out-Null
        foreach ($d in $toDelete) { Warn "deleted $d" }
    }
}
elseif ($Transport -eq 'sftp') {
    if (-not (Test-Path $SftpKey)) {
        Die "SSH key not found at $SftpKey. Password auth will hang the script mid-drop - set up a key first."
    }
    $batch = New-TemporaryFile
    $lines = @("cd $RemoteModsDir")
    foreach ($jar in $serverMods) { $lines += "put `"$($jar.FullName)`"" }
    $lines += 'bye'
    Set-Content -Path $batch -Value $lines -Encoding ascii

    & sftp -b $batch -P $SftpPort -i $SftpKey -o StrictHostKeyChecking=accept-new "$SftpUser@$SftpHost"
    if ($LASTEXITCODE -ne 0) { Die 'sftp upload failed' }
    Remove-Item $batch -Force
    Ok "$($serverMods.Count) jars uploaded"
    Warn 'sftp mode does not prune removed mods. Delete them by hand if this was a -Remove.'
}
else { Die "unknown Transport '$Transport' - use 'panel' or 'sftp'" }

# --------------------------------------------------------------------------
# restart
# --------------------------------------------------------------------------
if ($SkipRestart) {
    Write-Host ''
    Warn 'SkipRestart set. Restart the server yourself, THEN tell the cast to relaunch.'
    exit 0
}

Step 'Restarting server'
$body = @{ signal = 'restart' } | ConvertTo-Json -Compress
try {
    Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId/power" `
                      -Headers $panelHeaders -Method Post -Body $body | Out-Null
    Ok 'restart signal sent'
}
catch { Die "restart failed: $($_.Exception.Message)" }

# --------------------------------------------------------------------------
Write-Host ''
Write-Host '  ============================================' -ForegroundColor Magenta
Write-Host '   TELL THE CAST TO RELAUNCH' -ForegroundColor Magenta
Write-Host '  ============================================' -ForegroundColor Magenta
Write-Host ''
Write-Host '   "Quit to desktop. Not just the world - all the way out.' -ForegroundColor White
Write-Host '    Hit Play in Prism. Wait for the little sync window' -ForegroundColor White
Write-Host '    to finish. Then rejoin."' -ForegroundColor White
Write-Host ''
foreach ($a in $added) { Write-Host "   dropped: $a" -ForegroundColor Green }
Write-Host ''
Note 'Give the server ~60s before anyone tries to join.'
Write-Host ''
