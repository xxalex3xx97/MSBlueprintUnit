# Pak build driver. Runs each step whose script exists, echoes requirements for the rest.
# Exit 1 if any step is missing or fails, so a partial build is never taken as complete.
# MS_MODS_ROOT = this repo root (set here if unset; child scripts read it).
# Never touches the shared RE-UE4SS mirror used by the dev probe: writes only under this repo (build\, paks\prebuilt\).
# Requirements: private UE 5.7 project in ue\ (UE_ROOT = UE install folder for cook), retoc.exe in tools\retoc\ or on PATH.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $env:MS_MODS_ROOT) { $env:MS_MODS_ROOT = $root }

$steps = @(
    @{ Name = 'mesh (pak 97)';          Path = 'paks\src\build_mesh.ps1' },
    @{ Name = 'pak (IoStore, retoc)';   Path = 'paks\src\build_pak.ps1' },
    @{ Name = 'cook (UE project)';      Path = 'ue\scripts\bpunit_cook.ps1' },
    @{ Name = 'pack (UE project)';      Path = 'ue\scripts\pack.ps1' }
)
$missing = @()

if (-not (Test-Path -LiteralPath (Join-Path $root 'tools\retoc\retoc.exe') -PathType Leaf) -and -not (Get-Command retoc.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'REQUIRES: retoc.exe in tools\retoc\ or on PATH (MIT, fetched separately).'
    $missing += 'retoc.exe'
}
if (-not $env:UE_ROOT) {
    Write-Host 'REQUIRES: UE_ROOT = UE 5.7 install folder (cook step).'
    $missing += 'UE_ROOT'
}

foreach ($s in $steps) {
    $p = Join-Path $root $s.Path
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-Host "SKIPPED $($s.Name): $($s.Path) not found."
        $missing += $s.Name
        continue
    }
    Write-Host "== $($s.Name): $($s.Path)"
    $global:LASTEXITCODE = 0
    & $p
    if ($LASTEXITCODE -ne 0) { throw "$($s.Path) failed (exit $LASTEXITCODE)" }
}

if ($missing.Count -gt 0) {
    Write-Host "Build INCOMPLETE. Missing: $($missing -join ', ')"
    exit 1
}
Write-Host 'Build done. Next: scripts\release.ps1 -Version <x.y.z> -DryRun'
exit 0
