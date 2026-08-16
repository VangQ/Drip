<#
.SYNOPSIS
    Validate the drop queue before a session.

.DESCRIPTION
    Run this the day before you record. For every slug in queue.txt it checks
    Modrinth for a real 1.21.1 Fabric build and reports the things that decide
    whether a mod is a good live drop:

      SIDE      client-only mods need no server restart
      SIZE      what each person downloads mid-session, live, on home internet
      DEPS      a "one mod" drop that pulls five libraries is a bigger download
                than you told the cast it would be
      WORLDGEN  flagged because worldgen is already in your base pack - a
                worldgen drop only affects unexplored chunks, so the reveal
                lands on nothing and the bit dies on camera

    This does NOT prove a mod is stable. It proves the mod EXISTS for your
    target. Booting each one against a copy of the world is still on you.

.EXAMPLE
    .\scripts\check-queue.ps1
    .\scripts\check-queue.ps1 -Mod naturalist
#>
[CmdletBinding()]
param(
    # Check one slug instead of the whole queue file.
    [string]$Mod,
    [string]$QueueFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'queue.txt')
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PackDir  = Join-Path $RepoRoot 'pack'
$McVer    = '1.21.1'
$Loader   = 'fabric'

# what's already in the pack, so we can flag duplicates and satisfied deps
$inPack = @()
if (Test-Path (Join-Path $PackDir 'mods')) {
    $inPack = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' |
                ForEach-Object { $_.Name -replace '\.pw\.toml$', '' })
}

if ($Mod) {
    $slugs = @($Mod)
}
else {
    if (-not (Test-Path $QueueFile)) { throw "queue file not found: $QueueFile" }
    $slugs = @(Get-Content $QueueFile |
               ForEach-Object { ($_ -split '#')[0].Trim() } |
               Where-Object { $_ })
}

Write-Host ''
Write-Host "  Checking $($slugs.Count) candidate(s) against Fabric $McVer" -ForegroundColor Cyan
Write-Host ''

$headers = @{ 'User-Agent' = 'RDCS2Pack/1.0 (drop queue validator)' }
$gv = [uri]::EscapeDataString('["' + $McVer + '"]')
$ld = [uri]::EscapeDataString('["' + $Loader + '"]')

$projectCache = @{}
function Get-Project([string]$id) {
    if ($projectCache.ContainsKey($id)) { return $projectCache[$id] }
    try   { $p = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$id" -Headers $headers }
    catch { $p = $null }
    $projectCache[$id] = $p
    return $p
}

$results = @()
foreach ($slug in $slugs) {
    $row = [ordered]@{
        Slug = $slug; Status = ''; Side = ''; MB = ''; Deps = ''; Flags = @()
    }

    $proj = Get-Project $slug
    if (-not $proj) {
        $row.Status = 'NOT FOUND'
        $results += [pscustomobject]$row
        continue
    }

    if ($inPack -contains $slug) { $row.Flags += 'already-in-pack' }

    try {
        $vers = Invoke-RestMethod -Headers $headers `
            -Uri "https://api.modrinth.com/v2/project/$slug/version?loaders=$ld&game_versions=$gv"
    }
    catch { $vers = @() }

    if (-not $vers -or $vers.Count -eq 0) {
        $row.Status = "NO $McVer BUILD"
        $results += [pscustomobject]$row
        continue
    }

    $v = $vers[0]
    $row.Status = 'ok'

    $cs = $proj.client_side; $ss = $proj.server_side
    if     ($ss -eq 'unsupported') { $row.Side = 'client-only' }
    elseif ($cs -eq 'unsupported') { $row.Side = 'server-only' }
    else                           { $row.Side = 'both' }

    $bytes = ($v.files | Where-Object { $_.primary } | Select-Object -First 1).size
    if (-not $bytes) { $bytes = $v.files[0].size }
    $row.MB = '{0:N1}' -f ($bytes / 1MB)

    # required deps not already satisfied by the pack
    $missing = @()
    foreach ($d in $v.dependencies) {
        if ($d.dependency_type -ne 'required') { continue }
        if (-not $d.project_id) { continue }
        $dp = Get-Project $d.project_id
        if (-not $dp) { continue }
        if ($inPack -notcontains $dp.slug) { $missing += $dp.slug }
    }
    if ($missing.Count -gt 0) { $row.Deps = ($missing -join ',') }

    $cats = @($proj.categories)
    if ($cats -contains 'worldgen') { $row.Flags += 'WORLDGEN' }
    if ($proj.categories -contains 'library') { $row.Flags += 'library' }
    if ($bytes -gt 40MB) { $row.Flags += 'BIG-DOWNLOAD' }

    $results += [pscustomobject]$row
}

# ---- report --------------------------------------------------------------
$fmt = "  {0,-30} {1,-14} {2,-12} {3,7}  {4,-24} {5}"
Write-Host ($fmt -f 'MOD', 'STATUS', 'SIDE', 'MB', 'PULLS IN', 'FLAGS') -ForegroundColor DarkGray
Write-Host ('  ' + ('-' * 108)) -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = 'Green'
    if ($r.Status -ne 'ok')                { $color = 'Red' }
    elseif ($r.Flags -contains 'WORLDGEN') { $color = 'Yellow' }
    elseif ($r.Flags.Count -gt 0)          { $color = 'Yellow' }

    Write-Host ($fmt -f $r.Slug, $r.Status, $r.Side, $r.MB, $r.Deps, ($r.Flags -join ' ')) -ForegroundColor $color
}

Write-Host ''
$bad  = @($results | Where-Object { $_.Status -ne 'ok' })
$wg   = @($results | Where-Object { $_.Flags -contains 'WORLDGEN' })
$good = @($results | Where-Object { $_.Status -eq 'ok' })

Write-Host "  $($good.Count) usable, $($bad.Count) unusable" -ForegroundColor Cyan
if ($bad.Count -gt 0) {
    Write-Host "  Pull these out of the queue: $(($bad.Slug) -join ', ')" -ForegroundColor Red
}
if ($wg.Count -gt 0) {
    Write-Host "  Worldgen - move to base pack or a dimension reveal: $(($wg.Slug) -join ', ')" -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  Reminder: this checks existence, not stability.' -ForegroundColor DarkGray
Write-Host '  Boot every one of these against a world copy before you go live.' -ForegroundColor DarkGray
Write-Host ''
