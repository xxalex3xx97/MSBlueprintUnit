# Build the BlueprintUnit release zip + manifest.txt via the shared release-mod.ps1.
# Local only: no gh, no git tag, no git push, no upload. -DryRun builds the same zip into -OutDir and checks the listing.
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutDir,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$releaseMod = 'F:\MSDemoMods-public\scripts\release-mod.ps1'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not $OutDir) { $OutDir = Join-Path $root 'build\release' }
$OutDir = [IO.Path]::GetFullPath($OutDir)

# version guard: bpu_version.lua must carry the same x.y.z
$verFile = Join-Path $root 'mods\BlueprintUnit\Scripts\bpu_version.lua'
if (-not (Test-Path -LiteralPath $verFile -PathType Leaf)) { throw "missing file: $verFile" }
$vm = [regex]::Match((Get-Content -LiteralPath $verFile -Raw), '["''](\d+\.\d+\.\d+)["'']')
if (-not $vm.Success) { throw "no x.y.z version string in $verFile" }
if ($vm.Groups[1].Value -ne $Version) { throw "version mismatch: -Version $Version, bpu_version.lua says $($vm.Groups[1].Value)" }

if (-not (Test-Path -LiteralPath $releaseMod -PathType Leaf)) { throw "missing shared script: $releaseMod" }

# <local>=<zip path> pairs
$luaNames = 'main.lua', 'bpu_version.lua', 'bpu_window.lua', 'bpu_json.lua', 'bpu_plan.lua', 'bpu_live.lua', 'bpu_build.lua', 'bpu_ports.lua', 'bpu_port_data.lua'
$pakNames = foreach ($n in 'pakchunk97-BPUnitMesh_P', 'pakchunk100-BlueprintUnit_P', 'pakchunk102-BPUnitUI_P') {
    foreach ($e in 'pak', 'ucas', 'utoc') { "$n.$e" }
}
$files = @()
foreach ($n in $luaNames) { $files += (Join-Path $root "mods\BlueprintUnit\Scripts\$n") + "=Mods/BlueprintUnit/Scripts/$n" }
foreach ($n in $pakNames) { $files += (Join-Path $root "paks\prebuilt\$n") + "=Paks/$n" }

# expected zip content (release-mod.ps1 writes mscore.mod itself)
$expected = @($files | ForEach-Object { $_.Substring($_.LastIndexOf('=') + 1) })
$expected += 'Mods/BlueprintUnit/enabled.txt', 'Mods/BlueprintUnit/mscore.mod'
$expected = @($expected | Sort-Object)

& $releaseMod -Name BlueprintUnit -Repo xxalex3xx97/MSBlueprintUnit -Version $Version -MinNative 0.7.2 -Files $files -Empty @('Mods/BlueprintUnit/enabled.txt') -OutDir $OutDir
if ($LASTEXITCODE -ne 0) { throw 'release-mod.ps1 failed' }

# listing check on the built zip
$zip = Join-Path $OutDir "BlueprintUnit-$Version.zip"
$listed = @(& $tar -tf $zip | ForEach-Object { $_.Trim() -replace '\\', '/' } | Where-Object { $_ -and $_ -notmatch '/$' } | Sort-Object)
$dev = @($listed | Where-Object { $_ -match '\.(md|py|ps1|txt|cpp|hpp|h|c|json|ini|log|bat|sln|vcxproj)$' -and $_ -ne 'Mods/BlueprintUnit/enabled.txt' })
if ($dev) { throw "source/dev files in zip: $($dev -join ', ')" }
$diff = @(Compare-Object -ReferenceObject $expected -DifferenceObject $listed)
if ($diff) { throw "zip content differs from expected list: $(($diff | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join '; ')" }

Write-Host "Zip content OK ($($listed.Count) entries):"
$listed | ForEach-Object { "  $_" }
Get-Content -LiteralPath (Join-Path $OutDir 'manifest.txt')
if ($DryRun) {
    Write-Host "DRY RUN: built into $OutDir. Nothing published (no release, tag or push)."
} else {
    Write-Host "Built $zip. Not published: create the GitHub release (tag v$Version, mark Latest) only after the user approves."
}
exit 0
