# Stage cooked Content\BlueprintUnitUI and pack it with retoc (same method as pack.ps1 for pak98).
# Refuses to pack anything outside Content\BlueprintUnitUI or any /Game/ path outside /Game/BlueprintUnitUI/.
# Output: build\out\pakchunk102-BPUnitUI_P.{pak,ucas,utoc}. Only that pak's files are replaced (pack.ps1 wipes all of build\out).
# Usage: .\bpunit_pack.ps1 [-Retoc <path>] [-Name pakchunk102-BPUnitUI_P]   (run bpunit_cook.ps1 first)
param(
    [string]$Retoc = $(if ($env:MS_MODS_ROOT) { "$env:MS_MODS_ROOT\tools\retoc\retoc.exe" } else { 'F:\MSDemoMods\tools\retoc\retoc.exe' }),
    [string]$Name = 'pakchunk102-BPUnitUI_P',
    [string]$Uproject = (Join-Path $PSScriptRoot '..\MiningUnitUI.uproject'),
    [string]$Version = 'UE5_7'
)
$ErrorActionPreference = 'Stop'

$proj = Split-Path (Resolve-Path $Uproject).Path
$cooked = Join-Path $proj 'Saved\Cooked\Windows\MiningUnitUI\Content'
if (-not (Test-Path (Join-Path $cooked 'BlueprintUnitUI'))) { throw "run bpunit_cook.ps1 first: $cooked\BlueprintUnitUI missing" }
if (-not (Test-Path $Retoc)) { throw "retoc not found: $Retoc" }

$build = Join-Path $proj 'build'
$stage = Join-Path $build 'stage-bpunit'
$out   = Join-Path $build 'out'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$stage\MainSequence\Content", $out | Out-Null

# Game mounts packages as /Game under MainSequence\Content, so stage there (package paths /Game/BlueprintUnitUI/...).
New-Item -ItemType Directory -Force "$stage\MainSequence\Content\BlueprintUnitUI" | Out-Null
Copy-Item "$cooked\BlueprintUnitUI\*" "$stage\MainSequence\Content\BlueprintUnitUI" -Recurse -Force   # -Recurse: Art\ subfolder

$pkgDir = "$stage\MainSequence\Content\BlueprintUnitUI"
$bad = Get-ChildItem $stage -Recurse -File | Where-Object { $_.FullName -notlike "$pkgDir\*" }
if ($bad) { throw "files staged outside Content\BlueprintUnitUI: $($bad.FullName -join ', ')" }

# Our package may reference only /Game/BlueprintUnitUI/* (own prefix; the MiningUnitUI scan lives in tests\test_asset_refs.py).
python -I (Join-Path $PSScriptRoot 'bpunit_refscan.py') $pkgDir
if ($LASTEXITCODE -ne 0) { throw "asset reference scan failed (exit $LASTEXITCODE): game paths in cooked package" }

# Replace only this pak's files in out\ (pack.ps1 deletes the whole out\ dir).
Get-ChildItem $out -Filter "$Name.*" -ErrorAction SilentlyContinue | Remove-Item -Force
$utoc = Join-Path $out "$Name.utoc"
& $Retoc to-zen --version $Version $stage $utoc
if ($LASTEXITCODE -ne 0) { throw "retoc to-zen failed (exit $LASTEXITCODE)" }

$v = & $Retoc verify $utoc 2>&1 | Out-String
if ($v -notmatch 'verified') { throw "retoc verify did not print 'verified': $v" }
& $Retoc list --path --size $utoc

Get-ChildItem $out -Filter "$Name.*" | ForEach-Object {
    "{0}  {1:N0} B  {2}" -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
