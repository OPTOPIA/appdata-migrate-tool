[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'AppDataMigrate.ps1'
$testsPath = Join-Path $root 'tests'

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error "Parse error at $($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber): $($_.Message)" }
    throw 'PowerShell syntax validation failed.'
}
Write-Host 'PowerShell syntax validation passed.' -ForegroundColor Green

$analyzer = Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue
if ($analyzer) {
    $findings = Invoke-ScriptAnalyzer -Path $scriptPath -Severity Error,Warning
    if ($findings) {
        $findings | Format-Table -AutoSize | Out-String | Write-Error
        throw 'PSScriptAnalyzer reported findings.'
    }
    Write-Host 'PSScriptAnalyzer validation passed.' -ForegroundColor Green
}
else {
    Write-Warning 'PSScriptAnalyzer is not installed; static analyzer step skipped.'
}

$pester = Get-Command Invoke-Pester -ErrorAction SilentlyContinue
if (-not $pester) { throw 'Pester is required to run tests. Install-Module Pester -Scope CurrentUser.' }
Invoke-Pester -Script $testsPath -EnableExit
