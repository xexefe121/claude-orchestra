param([string]$TestRoot = ([IO.Path]::GetTempPath()))
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $repo 'skills/orchestra/scripts/orchestra.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'Repo launcher missing.' }
$root = Join-Path $TestRoot ('orchestra-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$savedRoot = $env:ORCHESTRA_TEST_ROOT
$savedHome = $env:USERPROFILE
$savedLocal = $env:LOCALAPPDATA
$savedCodexHome = $env:CODEX_HOME
$savedCodex = $env:ORCHESTRA_CODEX
$savedClaude = $env:ORCHESTRA_CLAUDE
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$failed = 0
try {
    $env:ORCHESTRA_TEST_ROOT = $root
    $env:USERPROFILE = Join-Path $root 'home'
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData/Local'
    $env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex'
    $env:ORCHESTRA_CODEX = $null
    $env:ORCHESTRA_CLAUDE = $null
    $env:TEMP = Join-Path $root 'temp'
    $env:TMP = $env:TEMP
    [void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
    [void][IO.Directory]::CreateDirectory($env:CODEX_HOME)
    [void][IO.Directory]::CreateDirectory($env:TEMP)
    foreach ($suite in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*-tests.ps1' -File | Sort-Object Name)) {
        $log = Join-Path $root ($suite.BaseName + '.log')
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suite.FullName 2>&1)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = 'Stop' }
        [IO.File]::WriteAllLines($log, [string[]]$output, (New-Object Text.UTF8Encoding($false)))
        if ($code -eq 0) {
            $summary = @($output | Where-Object { [string]$_ -match '^PASS:' } | Select-Object -Last 1)
            Write-Output "PASS $($suite.Name): $summary"
        } else { $failed++; Write-Output "FAIL $($suite.Name): exit=$code log=$log" }
    }
} finally {
    $env:ORCHESTRA_TEST_ROOT = $savedRoot
    $env:USERPROFILE = $savedHome
    $env:LOCALAPPDATA = $savedLocal
    $env:CODEX_HOME = $savedCodexHome
    $env:ORCHESTRA_CODEX = $savedCodex
    $env:ORCHESTRA_CLAUDE = $savedClaude
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
}
Write-Output "Fixtures and logs: $root"
if ($failed) { exit 1 }
