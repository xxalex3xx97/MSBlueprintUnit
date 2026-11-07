# Import both meshes into the MiningUnitUI UE project (stand-in materials at game paths), cook, copy ONLY the three meshes to mesh\.
$ErrorActionPreference = 'Stop'
$d = $PSScriptRoot
$root = if ($env:MS_MODS_ROOT) { $env:MS_MODS_ROOT } else { 'F:\MSDemoMods' }
if (Get-Process UnrealEditor* -ErrorAction SilentlyContinue) { throw 'UnrealEditor running' }
$ue = if ($env:UE_ROOT) { $env:UE_ROOT } else { 'F:\UE_5.7' }
$ed = "$ue\Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$proj = "$root\ue\MiningUnitUI\MiningUnitUI.uproject"
$c = "$root\ue\MiningUnitUI\Content\Meshes"
$names = @{ 'Machines' = @('SM2_BPUnitTbl', 'SM2_BPUnitHidden00'); 'Effects' = @('SM_BPUnitBlueprintHolo_01') }
# fresh import: drop old copies
foreach ($k in $names.Keys) { foreach ($n in $names[$k]) { Remove-Item "$c\$k\$n.*" -Force -ErrorAction SilentlyContinue } }
$py = "$d\ue_import_table.py"
for ($i = 0; $i -lt 6; $i++) {   # run 1-3 = imports (crash after save is expected), run 3 = post-process
    Remove-Item "$env:TEMP\bpunit_import.log" -ErrorAction SilentlyContinue
    & $ed $proj -ExecutePythonScript="$py" -unattended -stdout -NoLogTimes | Out-Null
    $log = Get-Content "$env:TEMP\bpunit_import.log" -Raw -ErrorAction SilentlyContinue
    Write-Output $log
    if ($log -match 'POSTDONE') { break }
}
if ($log -notmatch 'POSTDONE') { throw 'import did not finish' }
$cookArgs = @('-run=cook', '-targetplatform=Windows', '-unattended', '-stdout', '-NoLogTimes', '-unversioned')
foreach ($p in '/Game/Meshes/Machines', '/Game/Meshes/Effects', '/Game/Materials', '/Game/Art/MaterialLibrary') {
    $cookArgs += "-ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:+DirectoriesToAlwaysCook=(Path=`"$p`")"
}
& $ed $proj @cookArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw "cook failed $LASTEXITCODE" }
$cooked = "$root\ue\MiningUnitUI\Saved\Cooked\Windows\MiningUnitUI\Content\Meshes"
foreach ($k in $names.Keys) {
    New-Item -ItemType Directory -Force "$d\mesh\$k" | Out-Null
    Remove-Item "$d\mesh\$k\*" -Force
    foreach ($n in $names[$k]) { Copy-Item "$cooked\$k\$n.*" "$d\mesh\$k\" }
}
Remove-Item "$d\mesh\Materials" -Recurse -Force -ErrorAction SilentlyContinue   # no custom materials ship
Get-ChildItem "$d\mesh" -Recurse -File | ForEach-Object { "{0}  {1}" -f $_.FullName, $_.Length }
