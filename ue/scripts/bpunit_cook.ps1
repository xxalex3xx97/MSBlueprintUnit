# Cook /Game/BlueprintUnitUI (own pak pakchunk102-BPUnitUI_P) loose for Windows. Same as cook.ps1, but adds this folder to
# DirectoriesToAlwaysCook on the command line (DefaultGame.ini only lists /Game/MiningUnitUI). Commandlet, no editor GUI.
# Usage: .\bpunit_cook.ps1 [-EngineRoot <UE 5.7 dir>] [-Versioned]   (default: $env:UE_ROOT, else F:\UE_5.7)
param(
    [string]$EngineRoot = $(if ($env:UE_ROOT) { $env:UE_ROOT } else { 'F:\UE_5.7' }),
    [string]$Uproject = (Join-Path $PSScriptRoot '..\MiningUnitUI.uproject'),
    [switch]$Versioned  # default -unversioned, same as cook.ps1; pass -Versioned if retoc rejects unversioned cook
)
$ErrorActionPreference = 'Stop'

$editor = Join-Path $EngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
if (-not (Test-Path $editor)) { throw "UnrealEditor-Cmd.exe not found: $editor" }
$Uproject = (Resolve-Path $Uproject).Path

$cookArgs = @('-run=cook', '-targetplatform=Windows', '-iterate', '-stdout', '-unattended', '-NoLogTimes',
    '-ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:+DirectoriesToAlwaysCook=(Path=\"/Game/BlueprintUnitUI\")')
if (-not $Versioned) { $cookArgs += '-unversioned' }

& $editor $Uproject @cookArgs
if ($LASTEXITCODE -ne 0) { throw "cook failed (exit $LASTEXITCODE)" }

$cooked = Join-Path (Split-Path $Uproject) 'Saved\Cooked\Windows\MiningUnitUI'
if (-not (Test-Path (Join-Path $cooked 'Content\BlueprintUnitUI'))) { throw "no cooked Content\BlueprintUnitUI under $cooked" }
"cooked: $cooked\Content\BlueprintUnitUI"
