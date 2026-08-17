<#
.SYNOPSIS
    Check every moving part before you need it to work.

.DESCRIPTION
    Without this, the first time your API key gets exercised is during a live
    drop with the cast waiting. Run it now, and again any time you change hosts,
    rotate the key, or come back after a long gap.

    Never prints your API key.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\test-connection.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$script:Fails = 0
function Pass([string]$m) { Write-Host "  [ ok ] $m" -ForegroundColor Green }
function Fail([string]$m, [string]$fix) {
    Write-Host "  [FAIL] $m" -ForegroundColor Red
    if ($fix) { Write-Host "         $fix" -ForegroundColor Yellow }
    $script:Fails++
}
function Info([string]$m) { Write-Host "         $m" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  Drip - connection check' -ForegroundColor Cyan
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray

# ---- 1. local tools ------------------------------------------------------
$packwiz = Join-Path $RepoRoot '.tools\packwiz.exe'
if (Test-Path $packwiz) { Pass 'packwiz.exe present' }
else { Fail 'packwiz.exe missing' 'Run: .\scripts\setup-tools.ps1' }

$bootstrap = Join-Path $RepoRoot 'serverpack\packwiz-installer-bootstrap.jar'
if (Test-Path $bootstrap) { Pass 'packwiz-installer-bootstrap.jar present' }
else { Fail 'bootstrap jar missing' 'Run: .\scripts\setup-tools.ps1' }

try {
    $jv = (& java -version 2>&1 | Select-Object -First 1) -replace '"', ''
    Pass "java present  ($jv)"
}
catch { Fail 'java not found on PATH' 'Install Java 21 (Adoptium/Temurin).' }

# ---- 2. config -----------------------------------------------------------
$cfgPath = Join-Path $RepoRoot 'drop.config.ps1'
if (-not (Test-Path $cfgPath)) {
    Fail 'drop.config.ps1 missing' 'Copy scripts\config.example.ps1 to drop.config.ps1'
    Write-Host ''
    exit 1
}
. $cfgPath
Pass 'drop.config.ps1 loaded'

if ($PanelApiKey -like '*REPLACE_ME*') {
    Fail 'API key is still the placeholder' 'Panel -> avatar -> Account -> API Credentials -> Create Key'
}
elseif ($PanelApiKey -like 'ptla_*') {
    Fail 'That is an APPLICATION key (ptla_), not a client key' `
         'Application keys live under Admin and will not work here. You need one from your OWN account page - it starts with ptlc_'
}
elseif ($PanelApiKey -notlike 'ptlc_*') {
    Fail 'API key does not start with ptlc_' 'Client API keys always start with ptlc_. Re-copy it.'
}
else { Pass 'API key looks like a client key (ptlc_)' }

# ---- 3. pack hosting -----------------------------------------------------
Write-Host ''
Write-Host '  Pack hosting' -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -Uri $PackUrl -UseBasicParsing -TimeoutSec 20
    if ($r.Content -match 'name\s*=\s*"([^"]+)"') {
        Pass "pack.toml reachable  (pack name: $($Matches[1]))"
    }
    else { Fail 'URL responded but does not look like a pack.toml' "Got: $($r.Content.Substring(0,[Math]::Min(60,$r.Content.Length)))" }

    $cc = $r.Headers['Cache-Control']
    if ($cc -match 'max-age=(\d+)' -and [int]$Matches[1] -gt 60) {
        Fail "host caches for $($Matches[1])s" 'During a live drop some of the cast will get the OLD pack. Move to Netlify/Cloudflare Pages.'
    }
    else { Info "cache-control: $cc" ; Pass 'no problematic caching' }

    # the deep path is the one that actually breaks when publish-dir is wrong
    $base = $PackUrl -replace '/pack\.toml$', ''
    $idx = Invoke-WebRequest -Uri "$base/index.toml" -UseBasicParsing -TimeoutSec 20
    Pass 'index.toml reachable'
    $firstMod = (Get-ChildItem (Join-Path $RepoRoot 'pack\mods') -Filter '*.pw.toml' | Select-Object -First 1).Name
    if ($firstMod) {
        Invoke-WebRequest -Uri "$base/mods/$firstMod" -UseBasicParsing -TimeoutSec 20 | Out-Null
        Pass "mods/$firstMod reachable"
    }
}
catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 404) {
        Fail "404 from $PackUrl" 'Netlify publish directory is probably not set to "pack".'
    }
    elseif ($code -eq 401) {
        Fail "401 from $PackUrl" 'Site is behind a login gate. Netlify: Project configuration -> Visitor access -> set to public.'
    }
    else { Fail "could not fetch $PackUrl" $_.Exception.Message }
}

# ---- 4. panel ------------------------------------------------------------
Write-Host ''
Write-Host '  Server panel' -ForegroundColor Cyan
$h = @{
    'Authorization' = "Bearer $PanelApiKey"
    'Accept'        = 'Application/vnd.pterodactyl.v1+json'
    'Content-Type'  = 'application/json'
}

$panelOk = $false
try {
    $srv = Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId" -Headers $h -Method Get -TimeoutSec 20
    Pass "server reachable  ($($srv.attributes.name))"
    Info "node: $($srv.attributes.node)  |  id: $ServerId"
    $panelOk = $true
}
catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    switch ($code) {
        401     { Fail 'panel rejected the API key (401)' 'Key is wrong, revoked, or has a typo. Create a fresh one.' }
        403     { Fail 'key valid but access denied (403)' 'This key belongs to an account without permission on this server.' }
        404     { Fail 'server not found (404)' "Either \$ServerId ('$ServerId') or \$PanelUrl ('$PanelUrl') is wrong. Check your address bar: PANEL/server/ID" }
        default { Fail "could not reach $PanelUrl" "$($_.Exception.Message)  -  is the panel URL right?" }
    }
}

if ($panelOk) {
    try {
        $files = Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId/files/list?directory=/$RemoteModsDir" `
                                   -Headers $h -Method Get -TimeoutSec 20
        $jars = @($files.data | Where-Object { $_.attributes.name -like '*.jar' })
        Pass "$RemoteModsDir/ listed  ($($jars.Count) jar(s) there now)"
        foreach ($j in ($jars | Select-Object -First 12)) { Info $j.attributes.name }

        $prot = @($jars | Where-Object { $n = $_.attributes.name; ($KeepOnServer | Where-Object { $n -like $_ }) })
        if ($prot.Count -gt 0) { Pass "protected from sync: $(($prot | ForEach-Object { $_.attributes.name }) -join ', ')" }
        else { Info 'no protected jars found yet (PairedLife not uploaded)' }
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 404) { Fail "no '$RemoteModsDir' folder on the server" 'Install Fabric on the server first, or fix $RemoteModsDir.' }
        else { Fail 'could not list the mods folder' $_.Exception.Message }
    }

    # upload endpoint: check we CAN, without actually writing anything
    try {
        $signed = Invoke-RestMethod -Uri "$PanelUrl/api/client/servers/$ServerId/files/upload" -Headers $h -Method Get -TimeoutSec 20
        if ($signed.attributes.url) { Pass 'upload endpoint authorised' }
    }
    catch { Fail 'cannot get an upload URL' 'The key may be read-only. Recreate it without restrictions.' }
}

# ---- verdict -------------------------------------------------------------
Write-Host ''
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
if ($script:Fails -eq 0) {
    Write-Host '  All checks passed. You are clear to drop.' -ForegroundColor Green
}
else {
    Write-Host "  $($script:Fails) check(s) failed - fix these before a session." -ForegroundColor Red
}
Write-Host ''
