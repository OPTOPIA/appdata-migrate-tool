[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = 'C:\AppDataMigrateToolTests'
$source = Join-Path $testRoot 'Source'
$destinationRoot = Join-Path $testRoot 'Redirected'
$scriptPath = Join-Path $ProjectRoot 'AppDataMigrate.ps1'

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Integration test requires an elevated Windows runner.'
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Force -Recurse }
    New-Item -ItemType Directory -Path (Join-Path $source 'nested\empty') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'nested\original.txt') -Value 'original-data' -NoNewline

    & $scriptPath -SourcePath $source -DestinationRoot $destinationRoot -NonInteractive -Confirm:$false
    if ($LASTEXITCODE -ne 0) { throw "Migration command failed with exit code $LASTEXITCODE." }

    $target = Join-Path $destinationRoot 'AppDataMigrateToolTests\Source'
    $backup = "$source.bak"
    $sourceItem = Get-Item -LiteralPath $source -Force
    Assert-True ($sourceItem.LinkType -eq 'Junction') 'Migration did not create a source junction.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'nested\original.txt') -PathType Leaf) 'Migrated target file is missing.'
    Assert-True (Test-Path -LiteralPath $backup -PathType Container) 'Original backup directory is missing.'

    # Write through the junction to prove rollback restores post-migration data,
    # not merely the original .bak snapshot.
    Set-Content -LiteralPath (Join-Path $source 'nested\added-after-migration.txt') -Value 'current-data' -NoNewline

    & $scriptPath -SourcePath $source -DestinationRoot $destinationRoot -Rollback -NonInteractive -Confirm:$false
    if ($LASTEXITCODE -ne 0) { throw "Rollback command failed with exit code $LASTEXITCODE." }
    $restoredItem = Get-Item -LiteralPath $source -Force
    Assert-True (-not $restoredItem.LinkType) 'Rollback did not replace the junction with a directory.'
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'nested\added-after-migration.txt') -PathType Leaf) 'Rollback lost post-migration data.'
    Assert-True (Test-Path -LiteralPath $backup -PathType Container) 'Rollback unexpectedly removed the original backup.'
    Assert-True (Test-Path -LiteralPath $target -PathType Container) 'Rollback unexpectedly removed the migration target.'

    & $scriptPath -SourcePath $source -DestinationRoot $destinationRoot -Cleanup -NonInteractive -Confirm:$false
    if ($LASTEXITCODE -ne 0) { throw "Cleanup command failed with exit code $LASTEXITCODE." }
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'Cleanup did not delete the verified backup.'
    Assert-True (Test-Path -LiteralPath $target -PathType Container) 'Cleanup deleted the migration target.'

    $faultSource = Join-Path $testRoot 'FaultSource'
    New-Item -ItemType Directory -Path $faultSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $faultSource 'still-safe.txt') -Value 'must-survive' -NoNewline
    & $scriptPath -SourcePath $faultSource -DestinationRoot $destinationRoot -FaultInjectionStage BeforeJunction -NonInteractive -Confirm:$false
    Assert-True ($LASTEXITCODE -ne 0) 'Injected migration failure unexpectedly succeeded.'
    # The non-zero exit code is expected and asserted above; clear it so this
    # integration harness itself succeeds when all recovery assertions pass.
    $global:LASTEXITCODE = 0
    $faultTarget = Join-Path $destinationRoot 'AppDataMigrateToolTests\FaultSource'
    $faultBackup = "$faultSource.bak"
    Assert-True (Test-Path -LiteralPath $faultSource -PathType Container) 'Junction failure did not restore the original source path.'
    Assert-True (-not (Get-Item -LiteralPath $faultSource -Force).LinkType) 'Junction failure left a source junction behind.'
    Assert-True (Test-Path -LiteralPath (Join-Path $faultSource 'still-safe.txt') -PathType Leaf) 'Junction failure lost source data.'
    Assert-True (-not (Test-Path -LiteralPath $faultBackup)) 'Junction failure left an unexpected backup after source restoration.'
    Assert-True (Test-Path -LiteralPath (Join-Path $faultTarget 'still-safe.txt') -PathType Leaf) 'Junction failure lost copied target data.'
    Write-Host 'NTFS migration, rollback, and cleanup integration test passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Force -Recurse }
}
