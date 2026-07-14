<#
.SYNOPSIS
    Safely relocates a C: directory to another NTFS volume through an NTFS junction.

.DESCRIPTION
    Migration copies the source, verifies the copy, preserves the original as .bak,
    and replaces it with a junction. A manifest stored outside user data binds every
    destructive operation to the migration that created it.

    Rollback is deliberately non-destructive: it first copies the current destination
    to a new restore directory, verifies it, then switches the source path. The old
    .bak and destination are retained for manual cleanup.

.EXAMPLE
    .\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -WhatIf
    Preview a migration without modifying data.

.EXAMPLE
    .\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -VerifyHash
    Migrate with SHA-256 verification.

.EXAMPLE
    .\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Status
    Display recorded migration state without changing data.

.EXAMPLE
    .\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Rollback
    Restore the current destination data to C: without deleting retained copies.

.EXAMPLE
    .\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Cleanup -CancelBackupCleanup
    Cancel a registered delayed backup cleanup task without deleting the backup.
#>
[CmdletBinding(DefaultParameterSetName = 'Migrate', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(ParameterSetName = 'Rollback', Mandatory = $true)]
    [switch]$Rollback,

    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Cleanup', Mandatory = $true)]
    [switch]$Cleanup,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot = 'D:\C_Data_Redirect',

    [Parameter(ParameterSetName = 'Migrate')]
    [switch]$ScheduleBackupCleanup,

    [Parameter(ParameterSetName = 'Cleanup')]
    [switch]$RemoveDestination,

    [Parameter(ParameterSetName = 'Cleanup')]
    [switch]$CancelBackupCleanup,

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [switch]$VerifyHash,

    # Internal test hook: defines functions without performing preflight or I/O.
    [Parameter(DontShow = $true)]
    [switch]$NoExecute,

    # Internal integration-test hook. Never use this in normal operation.
    [Parameter(DontShow = $true)]
    [ValidateSet('AfterCopy', 'BeforeJunction')]
    [string]$FaultInjectionStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolName = 'AppDataMigrateTool'
$script:ManifestVersion = 1

function Write-Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-WarningMessage { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required.'
    }
}

function Assert-RequiredTools {
    param([switch]$NeedScheduledTasks)
    foreach ($tool in @('robocopy.exe', 'cmd.exe')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required Windows tool is unavailable: $tool" }
    }
    if ($NeedScheduledTasks) {
        foreach ($command in @('Get-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask')) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required ScheduledTasks command is unavailable: $command" }
        }
    }
}

function Get-NormalizedExistingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $item.FullName.TrimEnd('\')
}

function Get-NormalizedPathForComparison {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathEqualsOrChild {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $candidate = Get-NormalizedPathForComparison $Path
    $base = Get-NormalizedPathForComparison $BasePath
    return $candidate.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeCPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $Path.StartsWith('C:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source path must be on C:, for example C:\Users\YourName\AppData\Local.'
    }

    $relative = $Path.Substring(3)
    if ([String]::IsNullOrWhiteSpace($relative)) {
        throw 'Refusing to operate on the C: drive root.'
    }
    return $relative
}

function Assert-SafeSourcePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Source path must be an existing directory: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType) {
        throw "Source path is already a link ($($item.LinkType)): $Path"
    }
    foreach ($blocked in @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users\Default', 'C:\Users\Public')) {
        if (Test-PathEqualsOrChild -Path $Path -BasePath $blocked) {
            throw "Refusing to operate on protected system path: $blocked"
        }
    }
}

function Assert-SafeDestinationRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedRoot = Get-NormalizedPathForComparison $Root
    if ((Test-PathEqualsOrChild -Path $normalizedRoot -BasePath $Source) -or (Test-PathEqualsOrChild -Path $Source -BasePath $normalizedRoot)) {
        throw 'Destination root must not contain the source path or be contained by it.'
    }
    $drive = Split-Path -Path $normalizedRoot -Qualifier
    if (-not (Test-Path -LiteralPath $drive -PathType Container)) {
        throw "Destination drive does not exist: $drive"
    }
    $volume = Get-Volume -DriveLetter $drive.TrimEnd(':') -ErrorAction Stop
    if ($volume.FileSystem -ne 'NTFS') {
        throw "Destination drive must use NTFS for junction support; found $($volume.FileSystem)."
    }
    return $normalizedRoot
}

function Get-ManifestDirectory {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Join-Path $Root '.AppDataMigrateState'
}

function Get-MigrationId {
    param([Parameter(Mandatory = $true)][string]$Source)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Source.ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ManifestPath {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Root)
    return Join-Path (Get-ManifestDirectory $Root) ((Get-MigrationId $Source) + '.json')
}

function Save-Manifest {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$Path)

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-Manifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Assert-ManifestMatches {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Backup
    )

    if ($Manifest.ManifestVersion -ne $script:ManifestVersion -or
        -not $Manifest.SourcePath.Equals($Source, [StringComparison]::OrdinalIgnoreCase) -or
        -not $Manifest.TargetPath.Equals($Target, [StringComparison]::OrdinalIgnoreCase) -or
        -not $Manifest.BackupPath.Equals($Backup, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Migration manifest does not match the requested paths; refusing destructive operation.'
    }
}

function Get-DirectoryStats {
    param([Parameter(Mandatory = $true)][string]$Path)

    [Int64]$count = 0
    [Int64]$size = 0
    Get-ChildItem -LiteralPath $Path -File -Force -Recurse | ForEach-Object {
        $count++
        $size += $_.Length
    }
    return [PSCustomObject]@{ Count = $count; Size = $size }
}

function Assert-DestinationHasSpace {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $sourceStats = Get-DirectoryStats $Source
    $drive = Split-Path -Path $DestinationRoot -Qualifier
    $volume = Get-Volume -DriveLetter $drive.TrimEnd(':') -ErrorAction Stop
    # A small buffer covers directory metadata and files that change during preflight.
    [Int64]$required = $sourceStats.Size + 64MB
    if ($volume.SizeRemaining -lt $required) {
        throw "Insufficient destination free space. Required at least $required bytes; available $($volume.SizeRemaining) bytes."
    }
    return $sourceStats
}

function Test-DirectoryCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$VerifyHash
    )

    $sourceStats = Get-DirectoryStats $Source
    $destinationStats = Get-DirectoryStats $Destination
    if ($sourceStats.Count -ne $destinationStats.Count -or $sourceStats.Size -ne $destinationStats.Size) {
        throw "Copy verification failed. Source files/bytes=$($sourceStats.Count)/$($sourceStats.Size); destination=$($destinationStats.Count)/$($destinationStats.Size)."
    }

    Get-ChildItem -LiteralPath $Source -File -Force -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
        $peer = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $peer -PathType Leaf)) { throw "Copy verification missing file: $relative" }
        $peerItem = Get-Item -LiteralPath $peer -Force
        if ($peerItem.Length -ne $_.Length) { throw "Copy verification size mismatch: $relative" }
        if ($peerItem.LastWriteTimeUtc -ne $_.LastWriteTimeUtc) { throw "Copy verification timestamp mismatch: $relative" }
        if ($VerifyHash) {
            $sourceHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            $peerHash = (Get-FileHash -LiteralPath $peer -Algorithm SHA256).Hash
            if ($sourceHash -ne $peerHash) { throw "Copy verification hash mismatch: $relative" }
        }
    }
    Get-ChildItem -LiteralPath $Source -Directory -Force -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\\')
        $peer = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $peer -PathType Container)) { throw "Copy verification missing directory: $relative" }
    }
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $logDirectory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /LOG:$LogPath /TEE
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) { throw "robocopy failed with exit code $exitCode. See log: $LogPath" }
    return $exitCode
}

function New-Junction {
    param([Parameter(Mandatory = $true)][string]$LinkPath, [Parameter(Mandatory = $true)][string]$TargetPath)
    & cmd.exe /d /c "mklink /J `"$LinkPath`" `"$TargetPath`""
    if ($LASTEXITCODE -ne 0) { throw "mklink failed with exit code $LASTEXITCODE." }
    if ((Get-Item -LiteralPath $LinkPath -Force).LinkType -ne 'Junction') { throw "Junction verification failed: $LinkPath" }
}

function Remove-Junction {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Get-Item -LiteralPath $Path -Force).LinkType -ne 'Junction') { throw "Path is not a junction: $Path" }
    & cmd.exe /d /c "rmdir `"$Path`""
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $Path)) { throw "Failed to remove junction: $Path" }
}

function Confirm-Action {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($NonInteractive) { return $true }
    $answer = Read-Host "$Message Type Y to continue"
    return $answer -in @('Y', 'y')
}

function Invoke-TestFault {
    param([Parameter(Mandatory = $true)][string]$Stage)
    if ($FaultInjectionStage -eq $Stage) { throw "Injected test fault at stage: $Stage" }
}

function New-BackupCleanupTask {
    param([Parameter(Mandatory = $true)]$Paths, [Parameter(Mandatory = $true)]$Manifest)

    $taskName = 'AppDataMigrateCleanup_' + (Get-MigrationId $Paths.Source).Substring(0, 16)
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw "A cleanup task already exists: $taskName"
    }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { throw 'Cannot determine script path for scheduled cleanup.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SourcePath "{1}" -DestinationRoot "{2}" -Cleanup -NonInteractive -Confirm:$false' -f $scriptPath, $Paths.Source, $Paths.Root
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddDays(2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    try {
        $Manifest.CleanupTaskName = $taskName
        $Manifest.State = 'CleanupScheduled'
        $Manifest.UpdatedAt = (Get-Date).ToString('o')
        Save-Manifest $Manifest $Paths.Manifest
    }
    catch {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        throw
    }
    Write-Info "Backup cleanup task scheduled for two days from now: $taskName"
}

function Get-OperationPaths {
    # Status must remain available after an interrupted cutover, where the source
    # path can temporarily be absent. Mutating modes validate existence separately.
    $source = if (Test-Path -LiteralPath $SourcePath) { Get-NormalizedExistingPath $SourcePath } else { Get-NormalizedPathForComparison $SourcePath }
    $relative = Get-RelativeCPath $source
    $root = if ($PSCmdlet.ParameterSetName -eq 'Status') {
        Get-NormalizedPathForComparison $DestinationRoot
    }
    else {
        Assert-SafeDestinationRoot -Source $source -Root $DestinationRoot
    }
    return [PSCustomObject]@{
        Source = $source
        Root = $root
        Target = Join-Path $root $relative
        Backup = "$source.bak"
        Manifest = Get-ManifestPath -Source $source -Root $root
    }
}

function Show-Status {
    param([Parameter(Mandatory = $true)]$Paths)
    $manifest = Read-Manifest $Paths.Manifest
    Write-Host "Source: $($Paths.Source)"
    Write-Host "Target: $($Paths.Target)"
    Write-Host "Backup: $($Paths.Backup)"
    Write-Host "Manifest: $($Paths.Manifest)"
    if ($manifest) { Write-Host "Recorded state: $($manifest.State)" } else { Write-Host 'Recorded state: none' }
    if (Test-Path -LiteralPath $Paths.Source) {
        $item = Get-Item -LiteralPath $Paths.Source -Force
        Write-Host "Source type: $(if ($item.LinkType) { $item.LinkType } else { 'Directory' })"
    } else { Write-Host 'Source type: missing' }
    Write-Host "Target exists: $(Test-Path -LiteralPath $Paths.Target)"
    Write-Host "Backup exists: $(Test-Path -LiteralPath $Paths.Backup)"
    if ($manifest -and $manifest.CleanupTaskName) {
        $taskExists = $false
        try { $taskExists = [bool](Get-ScheduledTask -TaskName $manifest.CleanupTaskName -ErrorAction Stop) }
        catch { }
        Write-Host "Cleanup task: $($manifest.CleanupTaskName) (exists: $taskExists)"
    }
    else { Write-Host 'Cleanup task: none' }
}

function Invoke-Migration {
    param([Parameter(Mandatory = $true)]$Paths)
    Assert-RequiredTools -NeedScheduledTasks:$ScheduleBackupCleanup
    Assert-SafeSourcePath $Paths.Source
    $sourceStats = Assert-DestinationHasSpace -Source $Paths.Source -DestinationRoot $Paths.Root
    if (Test-Path -LiteralPath $Paths.Target) { throw "Target already exists: $($Paths.Target). Inspect status; do not delete it blindly." }
    if (Test-Path -LiteralPath $Paths.Backup) { throw "Backup already exists: $($Paths.Backup). Inspect status; do not overwrite it." }
    if (Test-Path -LiteralPath $Paths.Manifest) { throw "Manifest already exists: $($Paths.Manifest). Inspect status before retrying." }

    $manifest = [PSCustomObject]@{
        ManifestVersion = $script:ManifestVersion; Tool = $script:ToolName; State = 'Preflight';
        SourcePath = $Paths.Source; TargetPath = $Paths.Target; BackupPath = $Paths.Backup;
        CreatedAt = (Get-Date).ToString('o'); UpdatedAt = (Get-Date).ToString('o'); LogPath = $null; RobocopyExitCode = $null; CleanupTaskName = $null;
        VerificationMode = $(if ($VerifyHash) { 'SHA256' } else { 'PathSizeTimestamp' })
    }
    if (-not (Confirm-Action "Migrate '$($Paths.Source)' ($($sourceStats.Count) files, $($sourceStats.Size) bytes) to '$($Paths.Target)'?")) { throw 'Operation cancelled by user.' }
    if (-not $PSCmdlet.ShouldProcess($Paths.Source, "Copy, rename to .bak, and create junction to $($Paths.Target)")) { return }

    Save-Manifest $manifest $Paths.Manifest
    try {
        New-Item -ItemType Directory -Path $Paths.Target -Force | Out-Null
        $manifest.State = 'Copying'; $manifest.UpdatedAt = (Get-Date).ToString('o')
        $manifest.LogPath = Join-Path (Split-Path -Parent $Paths.Manifest) ((Get-MigrationId $Paths.Source) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.robocopy.log')
        Save-Manifest $manifest $Paths.Manifest
        $manifest.RobocopyExitCode = Invoke-Robocopy -Source $Paths.Source -Destination $Paths.Target -LogPath $manifest.LogPath
        Test-DirectoryCopy -Source $Paths.Source -Destination $Paths.Target -VerifyHash:$VerifyHash
        $manifest.State = 'Verified'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        Invoke-TestFault -Stage 'AfterCopy'

        Rename-Item -LiteralPath $Paths.Source -NewName (Split-Path -Leaf $Paths.Backup)
        $manifest.State = 'SourceBackedUp'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        try {
            Invoke-TestFault -Stage 'BeforeJunction'
            New-Junction -LinkPath $Paths.Source -TargetPath $Paths.Target
        }
        catch {
            if ((Test-Path -LiteralPath $Paths.Backup) -and -not (Test-Path -LiteralPath $Paths.Source)) { Rename-Item -LiteralPath $Paths.Backup -NewName (Split-Path -Leaf $Paths.Source) }
            throw
        }
        $manifest.State = 'Linked'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        Write-Success "Migration complete. Backup retained at: $($Paths.Backup)"
        if ($ScheduleBackupCleanup) {
            try { New-BackupCleanupTask -Paths $Paths -Manifest $manifest }
            catch { Write-WarningMessage "Migration succeeded but cleanup task was not created: $($_.Exception.Message)" }
        }
    }
    catch {
        $manifest.State = 'Failed'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        throw
    }
}

function Invoke-Rollback {
    param([Parameter(Mandatory = $true)]$Paths)
    Assert-RequiredTools
    $manifest = Read-Manifest $Paths.Manifest
    if (-not $manifest) { throw "No migration manifest found: $($Paths.Manifest)" }
    Assert-ManifestMatches -Manifest $manifest -Source $Paths.Source -Target $Paths.Target -Backup $Paths.Backup
    if (-not (Test-Path -LiteralPath $Paths.Backup -PathType Container)) { throw "Backup does not exist: $($Paths.Backup)" }
    if (-not (Test-Path -LiteralPath $Paths.Target -PathType Container)) { throw "Target does not exist: $($Paths.Target)" }
    if ((Get-Item -LiteralPath $Paths.Source -Force).LinkType -ne 'Junction') { throw 'Source is not a junction; refusing rollback.' }

    $restore = "$($Paths.Source).restore-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (-not (Confirm-Action "Rollback will preserve current destination data in '$restore', retain .bak and retain the D: target. Continue?")) { throw 'Operation cancelled by user.' }
    if (-not $PSCmdlet.ShouldProcess($Paths.Source, "Create verified restore copy from $($Paths.Target) and remove junction")) { return }

    $manifest.State = 'RollbackCopying'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
    try {
        New-Item -ItemType Directory -Path $restore -Force | Out-Null
        $rollbackLog = Join-Path (Split-Path -Parent $Paths.Manifest) ((Get-MigrationId $Paths.Source) + '-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.robocopy.log')
        Invoke-Robocopy -Source $Paths.Target -Destination $restore -LogPath $rollbackLog | Out-Null
        Test-DirectoryCopy -Source $Paths.Target -Destination $restore -VerifyHash:$VerifyHash
        $manifest.State = 'RollbackVerified'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        Remove-Junction $Paths.Source
        Rename-Item -LiteralPath $restore -NewName (Split-Path -Leaf $Paths.Source)
        $manifest.State = 'RolledBack'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        Write-Success "Rollback complete. Current data restored to: $($Paths.Source)"
        Write-WarningMessage "Retained for safety: $($Paths.Backup) and $($Paths.Target)"
    }
    catch {
        $manifest.State = 'RollbackFailed'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        throw
    }
}

function Invoke-Cleanup {
    param([Parameter(Mandatory = $true)]$Paths)
    $manifest = Read-Manifest $Paths.Manifest
    if (-not $manifest) { throw "No migration manifest found: $($Paths.Manifest)" }
    Assert-ManifestMatches -Manifest $manifest -Source $Paths.Source -Target $Paths.Target -Backup $Paths.Backup
    if ($CancelBackupCleanup) {
        if (-not $manifest.CleanupTaskName) { Write-Info 'No cleanup task is recorded; nothing to cancel.'; return }
        if (-not $manifest.CleanupTaskName.StartsWith('AppDataMigrateCleanup_', [StringComparison]::Ordinal)) { throw 'Recorded cleanup task name is invalid; refusing to unregister it.' }
        Assert-RequiredTools -NeedScheduledTasks
        if (-not (Confirm-Action "Cancel cleanup task '$($manifest.CleanupTaskName)' without deleting backup?")) { throw 'Operation cancelled by user.' }
        if ($PSCmdlet.ShouldProcess($manifest.CleanupTaskName, 'Cancel scheduled backup cleanup')) {
            $existingTask = Get-ScheduledTask -TaskName $manifest.CleanupTaskName -ErrorAction SilentlyContinue
            if ($existingTask) { Unregister-ScheduledTask -TaskName $manifest.CleanupTaskName -Confirm:$false -ErrorAction Stop }
            $manifest.CleanupTaskName = $null
            if ($manifest.State -eq 'CleanupScheduled') { $manifest.State = 'Linked' }
            $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
            Write-Success 'Scheduled backup cleanup cancelled.'
        }
        return
    }
    if ($manifest.State -notin @('Linked', 'CleanupScheduled', 'RolledBack')) { throw "Cleanup is not allowed from recorded state: $($manifest.State)" }
    if ($RemoveDestination) { throw 'Destination deletion is intentionally disabled until a dedicated verified cleanup implementation is available.' }
    if (-not (Test-Path -LiteralPath $Paths.Backup -PathType Container)) { Write-Info 'No backup exists; nothing to clean.'; return }
    if ((Get-Item -LiteralPath $Paths.Backup -Force).LinkType) { throw 'Backup is a link; refusing deletion.' }
    if (-not (Confirm-Action "Delete only verified backup '$($Paths.Backup)'?")) { throw 'Operation cancelled by user.' }
    if ($PSCmdlet.ShouldProcess($Paths.Backup, 'Delete verified backup')) {
        $manifest.State = 'BackupCleaning'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        Remove-Item -LiteralPath $Paths.Backup -Recurse -Force
        $manifest.State = 'BackupCleaned'; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        if ($manifest.CleanupTaskName -and $manifest.CleanupTaskName.StartsWith('AppDataMigrateCleanup_', [StringComparison]::Ordinal)) {
            $existingTask = Get-ScheduledTask -TaskName $manifest.CleanupTaskName -ErrorAction SilentlyContinue
            if ($existingTask) { Unregister-ScheduledTask -TaskName $manifest.CleanupTaskName -Confirm:$false -ErrorAction Stop }
            $manifest.CleanupTaskName = $null; $manifest.UpdatedAt = (Get-Date).ToString('o'); Save-Manifest $manifest $Paths.Manifest
        }
        Write-Success "Backup deleted: $($Paths.Backup)"
    }
}

if ($NoExecute) { return }

function Get-ToolExitCode {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)
    $message = $Exception.Message
    if ($message -match 'Administrator|Source path|protected system path|Destination root|must use NTFS|drive does not exist') { return 2 }
    if ($message -match 'Required Windows tool|ScheduledTasks command|Insufficient destination') { return 3 }
    if ($message -match 'manifest|already exists|not a junction|Backup does not exist|Target does not exist|Cleanup is not allowed') { return 4 }
    if ($message -match 'robocopy') { return 5 }
    if ($message -match 'verification|hash mismatch|timestamp mismatch') { return 6 }
    if ($message -match 'cancelled') { return 7 }
    return 1
}

try {
    Assert-Administrator
    $paths = Get-OperationPaths
    switch ($PSCmdlet.ParameterSetName) {
        'Status' { Show-Status $paths }
        'Rollback' { Invoke-Rollback $paths }
        'Cleanup' { Invoke-Cleanup $paths }
        default { Invoke-Migration $paths }
    }
}
catch {
    $exitCode = Get-ToolExitCode $_.Exception
    Write-Host ''
    Write-Host "ERROR [$exitCode]" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $exitCode
}
