<#
.SYNOPSIS
    Boot a real Fabric server against every mod in the queue and record what breaks.

.DESCRIPTION
    check-queue.ps1 proves a mod EXISTS for 1.21.1. This proves it STARTS.

    For each candidate it builds a scratch pack (your real pack is never touched),
    installs the server-side jars, restores a pristine world, launches an actual
    Fabric 1.21.1 server, and waits for "Done". Anything that crashes, hangs, or
    reports an incompatible mod set gets logged with the reason.

    Runs unattended. Everything is local - no panel, no network beyond mod
    downloads, nothing outward-facing.

    A pass here means the server starts. It does not mean the mod is fun, balanced,
    or free of client-side problems. It rules out the failure that ends a session.

.EXAMPLE
    .\scripts\boot-test.ps1 -AcceptEula
    .\scripts\boot-test.ps1 -Mod carry-on,mutant-monsters
    .\scripts\boot-test.ps1 -Rebuild -AcceptEula
#>
[CmdletBinding()]
param(
    # Test specific slugs instead of everything in queue.txt
    [string[]]$Mod,

    [string]$QueueFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'queue.txt'),

    # How long a server gets to reach "Done" before it's called a hang.
    [int]$TimeoutSec = 150,

    # Writes eula=true. Running a Minecraft server requires accepting Mojang's
    # EULA, and that is your call to make, not mine - so it needs this flag.
    [switch]$AcceptEula,

    # Wipe the test server and set it up again from scratch.
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$PackDir   = Join-Path $RepoRoot 'pack'
$Packwiz   = Join-Path $RepoRoot '.tools\packwiz.exe'
$Bootstrap = Join-Path $RepoRoot 'serverpack\packwiz-installer-bootstrap.jar'
$BootDir   = Join-Path $RepoRoot 'boottest'
$Scratch   = Join-Path $BootDir '_scratchpack'
$Snapshot  = Join-Path $BootDir '_world_pristine'
$Results   = Join-Path $BootDir 'results.md'

$McVer      = '1.21.1'
$LoaderVer  = '0.19.3'
$InstallVer = '1.1.2'
$ServerJar  = 'fabric-server-launch.jar'

# Native programs that write to stderr (packwiz and packwiz-installer both do on
# their failure paths) raise a terminating NativeCommandError under
# $ErrorActionPreference='Stop' in PowerShell 5.1 - even when the program exits 0.
# Unguarded, that kills the whole run on the first mod that has anything to say.
# Capture output with the preference relaxed and judge success by exit code.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try   { $out = (& $Block 2>&1 | Out-String) }
    catch { $out = $_.Exception.Message; $global:LASTEXITCODE = 1 }
    finally { $ErrorActionPreference = $prev }
    return $out
}

function Say ([string]$m) { Write-Host "  $m" -ForegroundColor Gray }
function Good([string]$m) { Write-Host "  $m" -ForegroundColor Green }
function Bad ([string]$m) { Write-Host "  $m" -ForegroundColor Red }
function Warn([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Head([string]$m) { Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }

if (-not (Test-Path $Packwiz))   { throw "packwiz missing. Run: .\scripts\setup-tools.ps1" }
if (-not (Test-Path $Bootstrap)) { throw "bootstrap jar missing. Run: .\scripts\setup-tools.ps1" }

if ($Rebuild -and (Test-Path $BootDir)) {
    Head 'Rebuilding test server from scratch'
    Remove-Item $BootDir -Recurse -Force
}

# ==========================================================================
# setup
# ==========================================================================
$launcher = Join-Path $BootDir $ServerJar
if (-not (Test-Path $launcher)) {
    Head "Setting up a local Fabric $McVer server"
    New-Item -ItemType Directory -Force $BootDir | Out-Null

    $url = "https://meta.fabricmc.net/v2/versions/loader/$McVer/$LoaderVer/$InstallVer/server/jar"
    Say "downloading server launcher..."
    Invoke-WebRequest -Uri $url -OutFile $launcher -UseBasicParsing
    Good "$ServerJar ($([int]((Get-Item $launcher).Length/1KB)) KB)"

    # Tuned for boot speed, not for play. A small view distance and no spawn
    # protection means the server reaches "Done" in seconds instead of a minute.
    @(
        'online-mode=false'
        'server-port=25599'
        'view-distance=4'
        'simulation-distance=4'
        'spawn-protection=0'
        'sync-chunk-writes=false'
        'max-players=1'
        'motd=boot test'
    ) | Set-Content (Join-Path $BootDir 'server.properties') -Encoding ascii
}

$eulaFile = Join-Path $BootDir 'eula.txt'
if (-not (Test-Path $eulaFile)) {
    if (-not $AcceptEula) {
        Write-Host ''
        Warn 'A Minecraft server will not start until Mojang''s EULA is accepted.'
        Warn 'That is your decision to make, so this script will not do it silently.'
        Write-Host ''
        Write-Host '    Read it:  https://aka.ms/MinecraftEULA' -ForegroundColor Gray
        Write-Host '    Then re-run with:  -AcceptEula' -ForegroundColor Gray
        Write-Host ''
        exit 1
    }
    "eula=true" | Set-Content $eulaFile -Encoding ascii
    Good 'eula accepted (via -AcceptEula)'
}

# ==========================================================================
# boot the server once and keep a clean copy of the world
#
# Each mod is then tested against an EXISTING world, which is the situation a
# live drop actually creates - not a fresh generation.
# ==========================================================================
function Invoke-Server {
    param([string]$Label, [int]$Timeout)

    $log = Join-Path $BootDir 'boot.log'
    $err = Join-Path $BootDir 'boot.err'
    Remove-Item $log, $err -Force -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath 'java' `
        -ArgumentList @('-Xms1G', '-Xmx2G', '-jar', $ServerJar, 'nogui') `
        -WorkingDirectory $BootDir -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $err

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $state = 'timeout'

    while ($sw.Elapsed.TotalSeconds -lt $Timeout) {
        Start-Sleep -Milliseconds 700

        $text = ''
        try { $text = Get-Content $log -Raw -ErrorAction SilentlyContinue } catch { }
        if ($text) {
            if ($text -match 'Done \([\d.]+s\)!') { $state = 'ok'; break }
            if ($text -match 'Incompatible mod set|Mod resolution encountered|A potential solution has been determined|Failed to start the minecraft server') {
                $state = 'modset'; break
            }
        }
        if ($proc.HasExited) { $state = 'exited'; break }
    }
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if (-not $proc.HasExited) {
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit(15000) | Out-Null } catch { }
    }
    # java can leave the port held for a moment; give it room before the next boot
    Start-Sleep -Milliseconds 800

    $out = ''
    try { $out = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $err -Raw -ErrorAction SilentlyContinue) } catch { }

    return [pscustomobject]@{ State = $state; Seconds = $secs; Log = $out }
}

function Get-FailReason {
    param([string]$Log)
    if (-not $Log) { return 'no output' }

    # Fabric states the real problem plainly; prefer its own words.
    $patterns = @(
        'requires (any version of|version) [^\r\n]+',
        "Mod '[^']+' [^\r\n]*requires[^\r\n]+",
        'Incompatible mod set[^\r\n]*',
        'java\.lang\.[A-Za-z]+Error[^\r\n]*',
        'java\.lang\.[A-Za-z]+Exception[^\r\n]*',
        'Mixin apply[^\r\n]*',
        'Caused by: [^\r\n]+'
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($Log, $p)
        if ($m.Success) {
            $r = $m.Value.Trim() -replace '\s+', ' '
            if ($r.Length -gt 150) { $r = $r.Substring(0, 150) + '...' }
            return $r
        }
    }
    return 'server did not reach "Done" - see log'
}

if (-not (Test-Path $Snapshot)) {
    Head 'First boot - generating a world to test against'
    Say '(this one is slow; every later boot reuses it)'

    # baseline: the real pack's server-side mods, nothing extra
    Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $PackDir $Scratch -Recurse -Force
    Invoke-Native { & java -jar $Bootstrap -g -s server --pack-folder $BootDir (Join-Path $Scratch 'pack.toml') } | Out-Null

    $r = Invoke-Server -Label 'baseline' -Timeout 300
    if ($r.State -ne 'ok') {
        Bad "baseline server failed to start ($($r.State)) - the BASE PACK is broken, not a candidate mod"
        Say (Get-FailReason $r.Log)
        Say "full log: $(Join-Path $BootDir 'boot.log')"
        exit 1
    }
    Good "baseline booted in $($r.Seconds)s"

    $world = Join-Path $BootDir 'world'
    if (-not (Test-Path $world)) { throw "server booted but produced no world folder" }
    Copy-Item $world $Snapshot -Recurse -Force
    Good 'pristine world snapshot saved'
}

# ==========================================================================
# candidates
# ==========================================================================
if ($Mod) { $slugs = @($Mod) }
else {
    if (-not (Test-Path $QueueFile)) { throw "queue file not found: $QueueFile" }
    $slugs = @(Get-Content $QueueFile |
               ForEach-Object { ($_ -split '#')[0].Trim() } |
               Where-Object { $_ })
}

$inPack = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' |
            ForEach-Object { $_.Name -replace '\.pw\.toml$', '' })
$slugs = @($slugs | Where-Object { $inPack -notcontains $_ })

Head "Boot-testing $($slugs.Count) mod(s), up to ${TimeoutSec}s each"
Say "worst case ~$([math]::Ceiling($slugs.Count * $TimeoutSec / 60)) min; passes are much faster"
Write-Host ''

$results = @()
$n = 0
foreach ($slug in $slugs) {
    $n++
    $prefix = "[{0,2}/{1}] {2,-28}" -f $n, $slugs.Count, $slug
    Write-Host -NoNewline "  $prefix "

    # scratch pack - the real pack is never modified
    Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $PackDir $Scratch -Recurse -Force

    Push-Location $Scratch
    $addOut = Invoke-Native { & $Packwiz modrinth add $slug -y }
    $addCode = $LASTEXITCODE
    if ($addCode -eq 0) { Invoke-Native { & $Packwiz refresh } | Out-Null }
    Pop-Location

    if ($addCode -ne 0) {
        Write-Host 'ADD FAILED' -ForegroundColor Red
        $results += [pscustomobject]@{ Mod = $slug; Result = 'add-failed'; Seconds = 0; Reason = ($addOut.Trim() -replace '\s+', ' ') }
        continue
    }

    $installOut = Invoke-Native { & java -jar $Bootstrap -g -s server --pack-folder $BootDir (Join-Path $Scratch 'pack.toml') }
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'INSTALL FAILED' -ForegroundColor Red
        $results += [pscustomobject]@{ Mod = $slug; Result = 'install-failed'; Seconds = 0; Reason = ($installOut.Trim() -replace '\s+', ' ') }
        continue
    }

    # fresh copy of the world so one bad mod can't poison the next test
    $world = Join-Path $BootDir 'world'
    Remove-Item $world -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $Snapshot $world -Recurse -Force

    $r = Invoke-Server -Label $slug -Timeout $TimeoutSec

    if ($r.State -eq 'ok') {
        Write-Host ("PASS  {0,5}s" -f $r.Seconds) -ForegroundColor Green
        $results += [pscustomobject]@{ Mod = $slug; Result = 'pass'; Seconds = $r.Seconds; Reason = '' }
    }
    else {
        $reason = Get-FailReason $r.Log
        Write-Host ("FAIL  {0,5}s  {1}" -f $r.Seconds, $r.State) -ForegroundColor Red
        Write-Host "          $reason" -ForegroundColor DarkYellow
        $results += [pscustomobject]@{ Mod = $slug; Result = "fail-$($r.State)"; Seconds = $r.Seconds; Reason = $reason }
        $keep = Join-Path $BootDir "fail-$slug.log"
        Set-Content -Path $keep -Value $r.Log -Encoding utf8
    }
}

# clean the test server back to the base pack
Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $PackDir $Scratch -Recurse -Force
Invoke-Native { & java -jar $Bootstrap -g -s server --pack-folder $BootDir (Join-Path $Scratch 'pack.toml') } | Out-Null

# ==========================================================================
# report
# ==========================================================================
$pass = @($results | Where-Object { $_.Result -eq 'pass' })
$fail = @($results | Where-Object { $_.Result -ne 'pass' })

Write-Host ''
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
Good "$($pass.Count) passed"
if ($fail.Count -gt 0) { Bad "$($fail.Count) failed: $(($fail.Mod) -join ', ')" }

$md = @()
$md += "# Boot test results"
$md += ""
$md += "Fabric $McVer / loader $LoaderVer. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')."
$md += ""
$md += "Each mod was installed onto the base pack and booted against an existing world."
$md += "A pass means the server reached ``Done``. It says nothing about balance or client-side behaviour."
$md += ""
$md += "| Mod | Result | Boot | Reason |"
$md += "|---|---|---|---|"
foreach ($r in $results) {
    $mark = if ($r.Result -eq 'pass') { 'pass' } else { "**$($r.Result)**" }
    $rsn = $r.Reason -replace '\|', '\|'
    if ($rsn.Length -gt 110) { $rsn = $rsn.Substring(0, 110) + '...' }
    $md += "| ``$($r.Mod)`` | $mark | $($r.Seconds)s | $rsn |"
}
$md += ""
if ($fail.Count -gt 0) {
    $md += "## Pull these from queue.txt"
    $md += ""
    foreach ($f in $fail) { $md += "- ``$($f.Mod)`` - $($f.Reason)" }
    $md += ""
    $md += "Per-failure logs are in ``boottest/fail-<mod>.log``."
}
Set-Content -Path $Results -Value ($md -join "`n") -Encoding utf8

Write-Host ''
Say "report: $Results"
Write-Host ''
