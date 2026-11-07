# Local checks: Lua unit tests (tests\*.lua, mods\BlueprintUnit\tests\test_*.lua) + luac -p on mods\BlueprintUnit\Scripts\*.lua.
# Lua: lua.exe / lua5.4 / luajit on PATH, else `nvim -l`. luac: PATH, else F:\MSDemoMods-public\tests\out\luac.exe.
# No Lua interpreter: luac-only mode, prints WARNING, exit 0 if syntax passes. No interpreter and no luac: exit 1.
# Exit 1 on any failure.
$root = Split-Path -Parent $PSScriptRoot
$fail = 0

function Find-Cmd([string[]]$names) {
    foreach ($n in $names) {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

$lua = Find-Cmd @('lua.exe', 'lua5.4', 'luajit')
$nvim = $null
if (-not $lua) { $nvim = Find-Cmd @('nvim.exe') }
$luac = Find-Cmd @('luac.exe', 'luac5.4', 'luac')
if (-not $luac -and (Test-Path -LiteralPath 'F:\MSDemoMods-public\tests\out\luac.exe' -PathType Leaf)) {
    $luac = 'F:\MSDemoMods-public\tests\out\luac.exe'
}

if (-not $lua -and -not $nvim -and -not $luac) {
    Write-Host 'ERROR: no Lua interpreter (lua.exe, lua5.4, luajit, nvim) and no luac found. Nothing was checked. Install Lua (choco install lua) and rerun.'
    exit 1
}

$tests = @()
$tests += @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.lua' -File -ErrorAction SilentlyContinue)
$tests += @(Get-ChildItem -LiteralPath (Join-Path $root 'mods\BlueprintUnit\tests') -Filter 'test_*.lua' -File -ErrorAction SilentlyContinue)

if ($lua -or $nvim) {
    foreach ($t in $tests) {
        Write-Host "lua: $($t.FullName)"
        if ($lua) { & $lua $t.FullName } else { & $nvim -l $t.FullName }
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: $($t.Name)"; $fail++ }
    }
} else {
    Write-Host "WARNING: no Lua interpreter found: $($tests.Count) Lua test file(s) NOT run. Only the luac -p syntax check ran."
}

if ($luac) {
    $scripts = @(Get-ChildItem -LiteralPath (Join-Path $root 'mods\BlueprintUnit\Scripts') -Filter '*.lua' -File -ErrorAction SilentlyContinue)
    foreach ($s in $scripts) {
        & $luac -p $s.FullName
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: luac -p $($s.Name)"; $fail++ }
    }
    Write-Host "luac -p: $($scripts.Count) file(s) checked"
} else {
    Write-Host 'WARNING: luac not found: syntax check (luac -p) NOT run.'
}

if ($fail -gt 0) { Write-Host "FAILED: $fail check(s)"; exit 1 }
Write-Host 'OK'
exit 0
