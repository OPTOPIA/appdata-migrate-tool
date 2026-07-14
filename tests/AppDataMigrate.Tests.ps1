$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AppDataMigrate.ps1'

Describe 'AppDataMigrate safety baseline' {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    $content = Get-Content -LiteralPath $scriptPath -Raw

    It 'parses as PowerShell' {
        $parseErrors.Count | Should Be 0
    }

    It 'exposes the intended operation modes' {
        $content | Should Match "'Migrate'"
        $content | Should Match "'Rollback'"
        $content | Should Match "'Status'"
        $content | Should Match "'Cleanup'"
    }

    It 'records migration state outside the migrated user directory' {
        $content | Should Match '\.AppDataMigrateState'
        $content | Should Match 'Save-Manifest'
        $content | Should Match 'Assert-ManifestMatches'
    }

    It 'verifies the current destination before removing the junction during rollback' {
        $rollback = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Rollback' }, $true)
        $rollback.Extent.Text.IndexOf('Test-DirectoryCopy') | Should BeGreaterThan -1
        $rollback.Extent.Text.IndexOf('Remove-Junction') | Should BeGreaterThan $rollback.Extent.Text.IndexOf('Test-DirectoryCopy')
    }

    It 'does not delete the destination as part of rollback' {
        $rollback = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Rollback' }, $true)
        $rollback.Extent.Text | Should Not Match 'Remove-Item.*Target'
    }
}

Describe 'AppDataMigrate pure path and manifest rules' {
    . $scriptPath -SourcePath $TestDrive -NoExecute

    It 'derives a relative path only for C drive paths' {
        Get-RelativeCPath 'C:\Users\Alice\AppData\Local' | Should Be 'Users\Alice\AppData\Local'
        { Get-RelativeCPath 'D:\Data' } | Should Throw
    }

    It 'distinguishes path boundaries instead of using a loose prefix' {
        Test-PathEqualsOrChild -Path 'C:\Windows\System32' -BasePath 'C:\Windows' | Should Be $true
        Test-PathEqualsOrChild -Path 'C:\Windows.old' -BasePath 'C:\Windows' | Should Be $false
    }

    It 'generates a stable manifest identity regardless of source path casing' {
        $first = Get-MigrationId 'C:\Users\Alice\AppData\Local'
        $second = Get-MigrationId 'c:\users\alice\appdata\local'
        $first | Should Be $second
        $first.Length | Should Be 64
    }

    It 'keeps manifest state outside migrated content' {
        Get-ManifestPath -Source 'C:\Users\Alice\AppData\Local' -Root 'D:\C_Data_Redirect' | Should Match '^D:\\C_Data_Redirect\\.AppDataMigrateState\\[a-f0-9]{64}\.json$'
    }

    It 'verifies file paths, timestamps, empty directories, and optional hashes' {
        $source = Join-Path $TestDrive 'source'
        $destination = Join-Path $TestDrive 'destination'
        New-Item -ItemType Directory -Path (Join-Path $source 'empty') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $destination 'empty') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'same data' -NoNewline
        Set-Content -LiteralPath (Join-Path $destination 'file.txt') -Value 'same data' -NoNewline
        $timestamp = [DateTime]::UtcNow.AddMinutes(-10)
        (Get-Item -LiteralPath (Join-Path $source 'file.txt')).LastWriteTimeUtc = $timestamp
        (Get-Item -LiteralPath (Join-Path $destination 'file.txt')).LastWriteTimeUtc = $timestamp

        { Test-DirectoryCopy -Source $source -Destination $destination -VerifyHash } | Should Not Throw
        Set-Content -LiteralPath (Join-Path $destination 'file.txt') -Value 'changed!!' -NoNewline
        (Get-Item -LiteralPath (Join-Path $destination 'file.txt')).LastWriteTimeUtc = $timestamp
        { Test-DirectoryCopy -Source $source -Destination $destination -VerifyHash } | Should Throw
    }
}
