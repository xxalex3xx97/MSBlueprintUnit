# Run all local checks. Same as: powershell -File tests\run.ps1
& (Join-Path $PSScriptRoot '..\tests\run.ps1')
exit $LASTEXITCODE
