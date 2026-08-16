<#
.SYNOPSIS
    Build the Prism Launcher instance zip you send to the cast.

.DESCRIPTION
    Produces RDC-Season-2.zip. Each person imports it once:
        Prism -> Add Instance -> Import from zip

    After that they never touch it again. Every Play click runs
    packwiz-installer against the live pack and syncs whatever you dropped.

    The zip deliberately contains NO mods. The instance is empty until first
    launch, which means this file never goes stale - you can send the same zip
    in week one and week nine.

.EXAMPLE
    .\scripts\build-instance.ps1
    .\scripts\build-instance.ps1 -PackUrl https://rdc-s2.netlify.app/pack.toml
#>
[CmdletBinding()]
param(
    # Defaults to $PackUrl from drop.config.ps1
    [string]$PackUrl,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src      = Join-Path $RepoRoot 'prism-instance'
$Staging  = Join-Path $env:TEMP ("rdc-instance-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

if (-not $PackUrl) {
    $cfg = Join-Path $RepoRoot 'drop.config.ps1'
    if (Test-Path $cfg) { . $cfg }
    if (-not $PackUrl) { throw 'Pass -PackUrl, or set $PackUrl in drop.config.ps1' }
}
if ($PackUrl -notmatch '^https://') { throw "PackUrl must be https - Prism instances on other machines will not trust plain http: $PackUrl" }
if ($PackUrl -notmatch 'pack\.toml$') { throw "PackUrl must point at pack.toml itself, not the folder: $PackUrl" }
if ($PackUrl -match 'raw\.githubusercontent\.com') {
    Write-Warning 'raw.githubusercontent.com sends Cache-Control: max-age=300.'
    Write-Warning 'During a live drop, part of the cast will get the OLD pack for up to 5 minutes.'
    Write-Warning 'Use Netlify/Cloudflare Pages instead.'
}
if (-not $OutFile) { $OutFile = Join-Path $RepoRoot 'RDC-Season-2.zip' }

Write-Host "Building instance against $PackUrl" -ForegroundColor Cyan

# fresh staging copy so we never write the resolved URL back into the repo
Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Staging | Out-Null
Copy-Item "$Src\*" $Staging -Recurse -Force

# the bootstrap jar must ship inside the zip - it is what does the first sync
$jar = Join-Path $Staging '.minecraft\packwiz-installer-bootstrap.jar'
if (-not (Test-Path $jar)) { throw "bootstrap jar missing. Run: .\scripts\setup-tools.ps1" }

# substitute the pack URL into the pre-launch command
$cfgPath = Join-Path $Staging 'instance.cfg'
$content = Get-Content $cfgPath -Raw
if ($content -notmatch '__PACK_URL__') { throw 'instance.cfg has no __PACK_URL__ placeholder' }
$content = $content -replace '__PACK_URL__', $PackUrl
Set-Content -Path $cfgPath -Value $content -Encoding utf8 -NoNewline

# strip anything that would make one person's instance differ from another's
foreach ($junk in 'mods', 'config', 'saves', 'logs', 'crash-reports', 'packwiz.json', 'options.txt') {
    Remove-Item (Join-Path $Staging ".minecraft\$junk") -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $OutFile -Force -ErrorAction SilentlyContinue

# Built by hand rather than with Compress-Archive on purpose.
#
# PowerShell 5.1's Compress-Archive writes Windows path separators into the zip
# central directory (".minecraft\file" instead of ".minecraft/file"). The zip
# spec requires forward slashes, and Prism's extractor can end up creating a
# single literal file named ".minecraft\..." instead of the folder - which means
# the bootstrap jar is not where instance.cfg expects it, the pre-launch command
# silently fails, and the instance launches with zero mods. For everyone.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($OutFile, 'Create')
try {
    $staged = Get-ChildItem $Staging -Recurse -File
    foreach ($f in $staged) {
        $rel = $f.FullName.Substring($Staging.Length + 1) -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel) | Out-Null
    }
}
finally { $zip.Dispose() }
Remove-Item $Staging -Recurse -Force

# fail loudly rather than shipping a broken zip to six people
$verify = [System.IO.Compression.ZipFile]::OpenRead($OutFile)
try {
    $names = @($verify.Entries | ForEach-Object { $_.FullName })
    if ($names -join '' -match '\\') { throw "zip contains backslash separators: $($names -join ', ')" }
    if ($names -notcontains '.minecraft/packwiz-installer-bootstrap.jar') { throw 'bootstrap jar missing from zip' }
    if ($names -notcontains 'instance.cfg') { throw 'instance.cfg missing from zip' }
    if ($names -notcontains 'mmc-pack.json') { throw 'mmc-pack.json missing from zip' }
}
finally { $verify.Dispose() }

$size = [int]((Get-Item $OutFile).Length / 1KB)
Write-Host ''
Write-Host "  $OutFile  (${size}KB)" -ForegroundColor Green
Write-Host ''
Write-Host '  Send that file to the cast with these three lines:' -ForegroundColor Cyan
Write-Host ''
Write-Host '    1. Install Prism Launcher (prismlauncher.org) and sign in with your Microsoft account.'
Write-Host '    2. Add Instance -> Import from zip -> pick RDC-Season-2.zip'
Write-Host '    3. Press Play. It downloads the mods itself. Do that once before session one.'
Write-Host ''
Write-Host '  Then, every time mods drop: quit to desktop and press Play again.' -ForegroundColor Cyan
Write-Host ''
