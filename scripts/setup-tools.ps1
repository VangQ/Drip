<#
.SYNOPSIS
    Fetch packwiz.exe and packwiz-installer-bootstrap.jar into .tools/.

.DESCRIPTION
    Both are gitignored, so run this after a fresh clone.

    packwiz publishes no tagged releases - only CI artifacts. The usual
    nightly.link branch URL goes stale and 404s ("artifact has expired") even
    while a good build exists, so this resolves the newest successful run from
    the GitHub API first and asks nightly.link for that specific run.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tools    = Join-Path $RepoRoot '.tools'
New-Item -ItemType Directory -Force $Tools | Out-Null

# ---- packwiz -------------------------------------------------------------
$packwizExe = Join-Path $Tools 'packwiz.exe'
if ((Test-Path $packwizExe) -and (-not $Force)) {
    Write-Host "packwiz.exe already present (use -Force to refresh)" -ForegroundColor DarkGray
}
else {
    Write-Host 'Resolving newest packwiz CI build...' -ForegroundColor Cyan
    $arts = Invoke-RestMethod -Uri 'https://api.github.com/repos/packwiz/packwiz/actions/artifacts?per_page=30' `
                              -Headers @{ 'User-Agent' = 'RDCS2Pack' }
    $win = $arts.artifacts |
           Where-Object { $_.name -eq 'Windows 64-bit' -and -not $_.expired } |
           Sort-Object { [datetime]$_.created_at } -Descending |
           Select-Object -First 1
    if (-not $win) { throw 'No unexpired Windows packwiz artifact found. Build from source with Go 1.19+.' }

    $runId = $win.workflow_run.id
    $url   = "https://nightly.link/packwiz/packwiz/actions/runs/$runId/Windows%2064-bit.zip"
    Write-Host "  run $runId" -ForegroundColor DarkGray

    $zip = Join-Path $Tools 'packwiz.zip'
    & curl.exe -sL -o $zip $url
    if (-not (Test-Path $zip)) { throw "download failed: $url" }

    # nightly.link returns an HTML error page with HTTP 404 rather than a zip
    $head = [System.IO.File]::ReadAllBytes($zip)[0..1]
    if ($head[0] -ne 0x50 -or $head[1] -ne 0x4B) {
        Remove-Item $zip -Force
        throw "nightly.link did not return a zip for run $runId - it may have expired. Check https://github.com/packwiz/packwiz/actions"
    }

    Expand-Archive $zip -DestinationPath $Tools -Force
    Remove-Item $zip -Force
    Write-Host "  packwiz.exe installed" -ForegroundColor Green
}

& $packwizExe --version 2>&1 | Select-Object -First 1

# ---- packwiz-installer-bootstrap -----------------------------------------
# Tiny launcher that self-updates to the current packwiz-installer at runtime,
# which is why a 2020 release tag is still the right thing to ship.
$bootstrapUrl = 'https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar'
$targets = @(
    (Join-Path $RepoRoot 'serverpack\packwiz-installer-bootstrap.jar'),
    (Join-Path $RepoRoot 'prism-instance\.minecraft\packwiz-installer-bootstrap.jar')
)
foreach ($t in $targets) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $t) | Out-Null
    if ((Test-Path $t) -and (-not $Force)) { continue }
    Invoke-WebRequest -Uri $bootstrapUrl -OutFile $t -UseBasicParsing
    Write-Host "  bootstrap -> $t" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Tools ready.' -ForegroundColor Green
