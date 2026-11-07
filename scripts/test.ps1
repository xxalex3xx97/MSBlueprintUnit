# Run all local checks. Same as: powershell -File tests/run.ps1
& (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'tests' 'run.ps1'))
exit $LASTEXITCODE
