$ErrorActionPreference = 'Stop'
$d = $PSScriptRoot
$root = if ($env:MS_MODS_ROOT) { $env:MS_MODS_ROOT } else { 'F:\MSDemoMods' }
$retoc = "$root\tools\retoc\retoc.exe"
$name = 'pakchunk97-BPUnitMesh_P'
Remove-Item "$d\stage_mesh" -Recurse -Force -ErrorAction SilentlyContinue
# mesh\<k> -> Content\<dest>
$map = @{ 'Machines' = 'Meshes\Machines'; 'Effects' = 'Meshes\Effects' }
New-Item -ItemType Directory -Force "$d\out" | Out-Null
foreach ($k in $map.Keys) {
    $t = "$d\stage_mesh\MainSequence\Content\$($map[$k])"
    New-Item -ItemType Directory -Force $t | Out-Null
    Copy-Item "$d\mesh\$k\*" "$t\"
}
& $retoc to-zen --version UE5_7 "$d\stage_mesh" "$d\out\$name.utoc"; if ($LASTEXITCODE) { throw 'to-zen failed' }
$v = & $retoc verify "$d\out\$name.utoc" 2>&1 | Out-String
if ($v -notmatch 'verified') { throw "verify: $v" }
Write-Output $v
& $retoc list --path --size "$d\out\$name.utoc"
Get-ChildItem "$d\out" -Filter "$name.*" | ForEach-Object { "{0}  {1}  {2}" -f $_.Name, $_.Length, (Get-FileHash $_.FullName).Hash }
