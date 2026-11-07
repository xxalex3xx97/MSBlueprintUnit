param([ValidateSet('none', 'vanilla', 'clone')][string]$Container = 'none', [string]$Pos = '8,8')
$ErrorActionPreference = 'Stop'
# Hidden container default machine on BPO_BlueprintUnit (DefaultMachines, unversioned header idx 24). Variants:
#   none    = no container, 5 packages                    -> out\none
#   vanilla = container = vanilla BP_ContainerObject_2 (32 slots, bonus 10), 5 packages -> out\vanilla
#   clone   = container = clone BP_BPUnitStoreObj_01 (120 slots, bonus 200) + actor clone BP_BPUnitSto_2 (invisible, mesh SM2_BPUnitHidden00 from pak97), 7 packages -> out\clone. Install pakchunk97 AND pakchunk100 together.
# -Pos X,Y = machine position (block-relative units, default 8,8) -> env BPU_MX/BPU_MY for patch_bpo_machine.py.
#   Default 8,8 -> out\<variant>\ (also copied to out\). Other positions -> out\<variant>_<X>_<Y>\ (not copied to out\).
# Each variant writes out\<dir>\pakchunk100-BlueprintUnit_P.{pak,ucas,utoc}.
Set-Location $PSScriptRoot
$d = $PSScriptRoot
$root = if ($env:MS_MODS_ROOT) { $env:MS_MODS_ROOT } else { 'F:\MSDemoMods' }
$retoc = "$root\tools\retoc\retoc.exe"
$name = 'pakchunk100-BlueprintUnit_P'
$bpo = "$d\stage\MainSequence\Content\Blueprints\BuildingBlocks"
$xy = $Pos -split ','
if ($xy.Count -ne 2 -or -not ($xy[0] -match '^-?\d+$') -or -not ($xy[1] -match '^-?\d+$')) { throw "bad -Pos '$Pos' (want X,Y ints)" }
$px, $py = [int]$xy[0], [int]$xy[1]
$env:BPU_MX = "$px"
$env:BPU_MY = "$py"
$isDef = ($px -eq 8 -and $py -eq 8)
$tag = if ($isDef) { $Container } else { "${Container}_${px}_${py}" }
Remove-Item "$d\stage" -Recurse -Force -ErrorAction SilentlyContinue
if ($Container -eq 'clone') { $env:BPU_CONTAINER = '1' } else { Remove-Item Env:BPU_CONTAINER -ErrorAction SilentlyContinue }
node clone.js; if ($LASTEXITCODE) { throw 'clone failed' }
python -I patch_registry.py 3 B "$d\stage\MainSequence\Content\Data"; if ($LASTEXITCODE) { throw 'registry failed' }
python -I patch_research.py "$d\stage\MainSequence\Content\Data\Research"; if ($LASTEXITCODE) { throw 'research failed' }
switch ($Container) {
    'none' { Write-Host 'container none: skip patch_bpo_machine.py' }
    'vanilla' {
        python -I patch_bpo_machine.py $bpo '/Game/Blueprints/Machines/BP_ContainerObject_2' 'BP_ContainerObject_2_C'
        if ($LASTEXITCODE) { throw 'bpo machine (vanilla) failed' }
    }
    'clone' {
        python -I patch_bpo_machine.py $bpo '/Game/Blueprints/Machines/BP_BPUnitStoreObj_01' 'BP_BPUnitStoreObj_01_C'
        if ($LASTEXITCODE) { throw 'bpo machine (clone) failed' }
    }
}
$outDir = "$d\out\$tag"
New-Item -ItemType Directory -Force $outDir | Out-Null
& $retoc to-zen --version UE5_6 --no-parallel "$d\stage" "$outDir\$name.utoc"; if ($LASTEXITCODE) { throw 'to-zen failed' }
$v = & $retoc verify "$outDir\$name.utoc" 2>&1 | Out-String
if ($v -notmatch 'verified') { throw "verify: $v" }
& $retoc list --path --size "$outDir\$name.utoc"
if ($isDef) { Copy-Item "$outDir\$name.*" "$d\out" -Force }
Get-ChildItem $outDir -Filter "$name.*" | ForEach-Object { "{0}  {1}  {2}  {3}" -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $outDir }
