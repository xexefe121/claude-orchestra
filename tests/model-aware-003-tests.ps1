$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'
$fixture = Join-Path $env:ORCHESTRA_TEST_ROOT ('model-aware-unit-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$null = . $launcher status -Project $fixture
# Native readiness has its own mocked suite; never inspect the installed desktop/config here.
function Assert-NativeComputerUseReady { }
$script:assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:assertions++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($caught -and $caught -match $Pattern) "Expected error '$Pattern', got '$caught'"
}
Assert ($Model -eq 'sol') 'Default workhorse shorthand'
Assert ($Cli -eq 'auto') 'Default CLI policy'

$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'PowerShell 5.1 parser'
foreach ($pair in @(@('sol','gpt-6.1-sol'), @('sol6','gpt-6-sol'), @('astra','gpt-6-astra'), @('luna','gpt-6-luna'))) {
    Assert ((Normalize-Model $pair[0]) -eq $pair[1]) "Normalize $($pair[0])"
    Assert ((Get-ModelPrefix $pair[1]) -eq $pair[0]) "Prefix $($pair[1])"
}
Assert ((Normalize-Model 'gpt-future/custom') -eq 'gpt-future/custom') 'Full slug passes through'
Assert ((Get-ModelPrefix 'gpt-future/custom') -eq 'gpt-future-custom') 'Unknown slug sanitized'
Assert ((Get-ModelPrefix '/._') -eq 'worker') 'Empty sanitized prefix fallback'

# Real cache read/write with a tiny local CLI, including timestamp invalidation.
$fake = Join-Path $fixture 'cache-cli.ps1'
$counter = Join-Path $fixture 'model-probes.txt'
Write-Utf8 $counter ''
$source = @'
if ($args[0] -eq '--version') { 'codex-cli 0.999.0'; return }
if ($args[0] -eq 'debug' -and $args[1] -eq 'models') {
    [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'model-probes.txt'), "probe`n")
    $global:LASTEXITCODE = 0
    '{"models":[{"slug":"gpt-6.1-sol"},{"slug":"gpt-6-sol"}]}'
}
'@
Write-Utf8 $fake $source
$info = Get-CodexInfo $fake
Assert ('gpt-6.1-sol' -in @(Get-CodexModels $info)) 'Cold model probe'
Assert ([IO.File]::Exists($info.Cache)) 'Cache file created'
$firstCache = $info.Cache
$script:codexInfo = @{}
$info = Get-CodexInfo $fake
Assert ('gpt-6.1-sol' -in @(Get-CodexModels $info)) 'Cached models'
Assert ([IO.File]::ReadAllLines($counter).Count -eq 1) 'Cache skips debug models'
[IO.File]::SetLastWriteTimeUtc($fake, [DateTime]::UtcNow.AddSeconds(2))
$script:codexInfo = @{}
$info = Get-CodexInfo $fake
$null = @(Get-CodexModels $info)
Assert ($info.Cache -ne $firstCache) 'Cache key changes with executable timestamp'
Assert ([IO.File]::ReadAllLines($counter).Count -eq 2) 'Changed executable reprobed'
Write-Utf8 $info.Cache 'invalid json'
$script:codexInfo = @{}
$info = Get-CodexInfo $fake
$null = @(Get-CodexModels $info)
Assert ([IO.File]::ReadAllLines($counter).Count -eq 3) 'Corrupt cache recovered'

# Controlled candidates let us cover updates and unavailable models without live sessions.
$desktopPath = Join-Path $fixture 'desktop.ps1'
$npmPath = Join-Path $fixture 'npm.ps1'
Write-Utf8 $desktopPath ''
Write-Utf8 $npmPath ''
$script:desktop = [pscustomobject]@{
    Path = $desktopPath; Family = 'desktop'; VersionText = '0.158.0-alpha.2.1'
    Models = @('gpt-6-sol','gpt-6-astra','gpt-6-luna'); ModelError = $null
}
$script:npm = [pscustomobject]@{
    Path = $npmPath; Family = 'path'; VersionText = '0.159.2'
    Models = @('gpt-6.1-sol','gpt-6-sol','gpt-6-astra','gpt-6-luna'); ModelError = $null
}
function Get-CodexCandidates([bool]$IncludePath) {
    if ($IncludePath) { $script:npm; $script:desktop } else { $script:desktop }
}
function Get-CodexInfo([string]$Path) {
    if ($Path -eq $desktopPath) { return $script:desktop }
    if ($Path -eq $npmPath) { return $script:npm }
    throw "Unknown mock CLI: $Path"
}
$overrideBefore = $env:ORCHESTRA_CODEX
try {
    $env:ORCHESTRA_CODEX = $null
    $Cli = 'auto'
    $selection = Resolve-Codex 'gpt-6.1-sol' $false $null
    Assert ($selection.Info.Family -eq 'path') 'Auto sol uses supported npm CLI'
    $selection = Resolve-Codex 'gpt-6-sol' $false $null
    Assert ($selection.Info.Family -eq 'path') 'Auto prefers supported PATH/npm'
    Assert ((Resolve-Codex 'gpt-6-sol' $true $null).Info.Family -eq 'desktop') 'ComputerUse retains desktop-first'
    $script:desktop.Models += 'desktop-only-model'
    Assert ((Resolve-Codex 'desktop-only-model' $false $null).Info.Family -eq 'desktop') 'Auto falls back to supported desktop'
    Assert-Throws { Resolve-Codex 'gpt-missing' $false $null } "gpt-missing.*CLIs checked:.*npm.ps1.*desktop.ps1"
    $Cli = 'newest'
    Assert ((Resolve-Codex 'anything' $false $null).Info.Family -eq 'path') 'Explicit newest unchanged'
    $Cli = 'desktop'
    Assert ((Resolve-Codex 'anything' $false $null).Info.Family -eq 'desktop') 'Explicit desktop unchanged'
    $Cli = 'auto'
    $selection = Resolve-Codex 'gpt-6.1-sol' $true $null
    Assert ($selection.Model -eq 'gpt-6.1-sol' -and -not $selection.Fallback -and $selection.Info.Family -eq 'path') 'ComputerUse uses normal auto resolution'
    $script:desktop.Models += 'gpt-6.10-sol'
    Assert-Throws { Resolve-Codex 'gpt-missing' $true $null } 'No Codex CLI lists model'
    $script:desktop.Models += 'gpt-6.1-sol'
    $selection = Resolve-Codex 'gpt-6.1-sol' $true $null
    Assert ($selection.Model -eq 'gpt-6.1-sol' -and -not $selection.Fallback) 'Desktop update stops fallback'
    $previous = [pscustomobject]@{cli_path = $npmPath; cli_family = 'path'; cli_rule = 'auto'}
    Assert ((Resolve-Codex 'gpt-6-sol' $false $previous).Info.Path -eq $npmPath) 'Resume prefers saved npm path'
    $previous.cli_path = Join-Path $fixture 'removed-hash.exe'
    Assert ((Resolve-Codex 'gpt-6-sol' $false $previous).Info.Family -eq 'path') 'Missing npm path keeps family'
    $previous.cli_family = 'desktop'
    Assert ((Resolve-Codex 'gpt-6-sol' $false $previous).Info.Family -eq 'desktop') 'Removed desktop hash re-resolves desktop'
    $previous.cli_path = $npmPath; $previous.cli_family = 'path'
    Assert ((Resolve-Codex 'gpt-6-sol' $true $previous).Info.Family -eq 'path') 'ComputerUse resume retains npm'
    Assert-Throws { Resolve-Codex 'gpt-missing' $false $previous } 'Saved session CLI.*gpt-missing'
    $env:ORCHESTRA_CODEX = $npmPath
    $Cli = 'desktop'
    Assert ((Resolve-Codex 'gpt-6-sol' $false $null).Info.Path -eq $npmPath) 'ORCHESTRA_CODEX wins explicit selector'
    Assert ((Resolve-Codex 'gpt-6-sol' $true $null).Info.Family -eq 'path') 'ComputerUse honors explicit path override'
    $env:ORCHESTRA_CODEX = Join-Path $fixture 'missing.exe'
    Assert-Throws { Resolve-Codex 'gpt-6-sol' $false $null } 'ORCHESTRA_CODEX not found'
    $env:ORCHESTRA_CODEX = $null
    $Cli = 'auto'
    $script:desktop.Models = @('gpt-6-sol','gpt-6-astra','gpt-6-luna')
    Ensure-State $false
    function Invoke-Codex([string]$Exe, [string[]]$Arguments, [string]$Prompt, [string]$Stdout, [string]$Stderr) {
        Write-Utf8 $Stdout '{"type":"thread.started","thread_id":"sandbox-session"}'
        Write-Utf8 $Stderr ''
        if ($script:writeFresh) { Write-Utf8 (Join-Path $state 'reports\lifecycle.md') 'Status: DONE' }
        return 0
    }
    function Get-Context($Events, [string]$SessionId) { return @{tokens = 0; window = 0; source = 'approx'} }
    Write-Utf8 $workersFile '[]'
    Write-Utf8 (Join-Path $state 'reports\lifecycle.md') 'old report'
    $script:writeFresh = $false
    $ComputerUse = $false
    $result = Invoke-WorkerRun 'lifecycle' 'gpt-6.1-sol' 'low' 'test-worker' $false $true $true $null
    Assert ($result.Status -eq 'failed' -and -not $result.ReportFresh) 'Old report never counts as done'
    $worker = @(Read-Workers)[0]
    Assert ($worker.cli_path -eq $npmPath -and $worker.cli_version -eq '0.159.2') 'Worker saves CLI provenance'
    $worker.status = 'running'; $worker.launcher_pid = 2147483647
    Save-Workers @($worker)
    $script:writeFresh = $true
    $result = Invoke-WorkerRun 'lifecycle' 'gpt-6.1-sol' 'low' 'test-worker' $true $false $false $null
    Assert ($result.Status -eq 'done' -and $result.ReportFresh) 'Stale running recovery and fresh report'
    $worker = @(Read-Workers)[0]
    $worker.status = 'running'; $worker.launcher_pid = $PID
    Save-Workers @($worker)
    Assert-Throws { Invoke-WorkerRun 'lifecycle' 'gpt-6.1-sol' 'low' 'test-worker' $true $false $false $null } 'already running'
    $worker.status = 'done'; Save-Workers @($worker)
    Assert-Throws { Invoke-WorkerRun 'lifecycle' 'gpt-6.1-sol' 'low' 'test-worker' $false $true $true $null } 'already exists'
    $ComputerUse = $true
    $result = Invoke-WorkerRun 'lifecycle' 'gpt-6.1-sol' 'low' $null $false $true $true $null
    Assert ($result.Line -match '^\[orchestra\] sol-01 ' -and $result.Line -notmatch 'model-fallback=') 'Requested-model name without fallback suffix'
    $worker = @(Read-Workers | Where-Object { $_.name -eq 'sol-01' })[0]
    Assert ($worker.model -eq 'gpt-6.1-sol' -and $worker.requested_model -eq 'gpt-6.1-sol' -and
        -not $worker.model_fallback -and $worker.cli_family -eq 'path') 'Native npm provenance saved'
    $script:desktop.Models += 'gpt-6.1-sol'
    $ComputerUse = $false
    $result = Invoke-WorkerRun 'lifecycle' 'gpt-6.1-sol' 'low' 'sol-01' $true $false $false $null
    $worker = @(Read-Workers | Where-Object { $_.name -eq 'sol-01' })[0]
    Assert ($worker.model -eq 'gpt-6.1-sol' -and -not $worker.model_fallback -and $worker.computer_use) 'Resume retains ComputerUse and adopts supported requested model'
    Assert ($result.Line -notmatch 'model-fallback=') 'Updated desktop omits fallback suffix'
    $script:desktop.Models = @('gpt-6-luna')
    Assert ((Resolve-Codex 'gpt-6.1-sol' $true $null).Info.Family -eq 'path') 'Unavailable desktop model selects npm'
} finally { $env:ORCHESTRA_CODEX = $overrideBefore }
"PASS: $script:assertions assertions; parser, cache, selection, resume, overrides, lifecycle"
