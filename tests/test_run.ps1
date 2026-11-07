# Self-test for tests/run.ps1 path discovery. Run: powershell -File tests/test_run.ps1. Exit 1 on failure.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pwshExe = (Get-Process -Id $PID).Path
$fail = 0
function Run-Copy([string]$name, [bool]$withMod) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("bpu-run-" + $name + "-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $tmp 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path (Join-Path $repo 'tests') 'run.ps1') -Destination (Join-Path $tmp 'tests')
    if ($withMod) { Copy-Item -LiteralPath (Join-Path $repo 'mods') -Destination $tmp -Recurse }
    $out = & $pwshExe -NoProfile -File (Join-Path (Join-Path $tmp 'tests') 'run.ps1') 2>&1 | Out-String
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Recurse -Force
    return @{ Code = $code; Out = $out }
}

# 1. no mods dir: zero test + zero Scripts files must FAIL (exit 1), not pass with nothing run
$r = Run-Copy 'empty' $false
if ($r.Code -eq 1 -and $r.Out -match 'no Lua test files found') { Write-Host 'PASS empty tree fails' } else { Write-Host "FAIL empty tree fails (exit $($r.Code))"; $fail++ }

# 2. full copy with mods: paths resolve, run.ps1 prints OK
$r = Run-Copy 'full' $true
if ($r.Code -eq 0 -and $r.Out -match '(?m)^OK\s*$' -and $r.Out -match 'luac -p: \d+ file') { Write-Host 'PASS full tree resolves and OK' } else { Write-Host "FAIL full tree (exit $($r.Code))`n$($r.Out)"; $fail++ }

if ($fail -gt 0) { Write-Host "FAILED: $fail check(s)"; exit 1 }
Write-Host 'OK'
exit 0
