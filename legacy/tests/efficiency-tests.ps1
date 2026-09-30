param([string]$Launcher = (Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'))
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:ORCHESTRA_TEST_ROOT ('eff-unit-' + [guid]::NewGuid().ToString('N'))
$null = . $Launcher init -Project $fixture
$script:checks = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw "FAIL: $Message" }; $script:checks++ }
function Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''; try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected $Pattern; got $message"
}
Assert ($TimeoutMin -eq 90 -and $ReviewTimeoutMin -eq 30 -and -not $NoDigest) 'Worker/reviewer timeout defaults and digest default'
function Resolve-Codex($RequestedModel, $NeedsComputer, $Previous) {
    return [pscustomobject]@{Info=[pscustomobject]@{Path='mock';VersionText='1';Family='path'};Model=$RequestedModel;Fallback=$null;Rule='auto'}
}
function Resolve-Claude($Previous) { return [pscustomobject]@{Path='mock';VersionText='1';Family='claude'} }
$script:calls = 0
function Invoke-Codex($Exe, $Arguments, $Prompt, $Stdout, $Stderr) {
    $script:calls++; $script:prompt = $Prompt
    $id = [regex]::Match($Prompt, '\.orchestra/tasks/([^\s]+)\.md').Groups[1].Value
    Write-Utf8 (Join-Path $state "reports/$id.md") "Status: DONE`n## Summary`nMock completed.`n## Open issues and risks`n- None."
    Write-Utf8 $Stdout '{"type":"thread.started","thread_id":"mock-session"}'
    Write-Utf8 $Stderr ''
    return 0
}
function Get-Context($Events, $SessionId) { return @{tokens=1000;window=200000;source='mock'} }
function Get-ClaudeResult($Events) { return @{session='mock-session';model='claude-sonnet-5-5';context=@{tokens=1000;window=200000;source='mock'};text='';failed=$false} }
foreach ($case in @(
    @('codex70','gpt-6-luna',140000,200000,70,$true),
    @('codex69','gpt-6-luna',138000,200000,69,$false),
    @('claude200k','claude-sonnet-5-5',200000,1000000,20,$true),
    @('claude199k','claude-sonnet-5-5',199999,1000000,20,$false),
    @('claude70','claude-sonnet-5-5',140000,200000,70,$true),
    @('claude69','claude-sonnet-5-5',139999,200000,70,$false))) {
    $Force = $false
    $name = $case[0]
    $first = Invoke-WorkerRun "$name-first" $case[1] 'low' $name $false $true $true $null
    Assert ($first.Status -eq 'done') "$name seeded"
    $all = @(Read-Workers); $worker = @($all | Where-Object { $_.name -eq $name })[0]
    $worker.context_tokens=$case[2]; $worker.context_window=$case[3]; $worker.context_pct=$case[4]
    Save-Workers $all
    $before = $script:calls
    if ($case[5]) {
        Throws { Invoke-WorkerRun "$name-blocked" $case[1] 'low' $name $true $false $false $null } 'handoff threshold.*-Force'
        Assert ($script:calls -eq $before) "$name blocked before invocation"
        Assert (@(Read-Workers | Where-Object { $_.name -eq $name })[0].status -eq 'done') "$name state not mutated"
        $Force = $true
    }
    $resumed = Invoke-WorkerRun "$name-next" $case[1] 'low' $name $true $false $false $null
    Assert ($resumed.Status -eq 'done') "$name allowed resume"
    if ($case[1] -like 'gpt-*') { Assert ($script:prompt.Contains('Shell is Windows PowerShell 5.1: no && or ||.')) 'Codex resume shell rules' }
    else { Assert (-not $script:prompt.Contains('Shell is Windows PowerShell')) 'Claude prompt excludes Codex shell rules' }
}
$Force = $false
Update-Board
$board = [IO.File]::ReadAllText((Join-Path $state 'board.md'), $utf8)
Assert (($board -split '\r?\n' | Where-Object { $_ -match '^\| (codex|claude)' }).Count -eq 12) 'One row per historical task after resumes'
Assert ($board -match 'Totals: DONE=12; running workers: none') 'Report status totals'
Assert (@($board -split '\r?\n' | Where-Object { $_ -match '^\| (codex|claude)' -and ($_ -split '\|').Count -ne 10 }).Count -eq 0) 'All eight columns retained with empty verdict'
Assert ([IO.File]::ReadAllBytes((Join-Path $state 'board.md'))[0] -ne 239) 'Board UTF8 without BOM'
Lock-Workers { Save-TaskRun ([pscustomobject]@{
    task='fractional';worker='fixture';model='gpt-6-luna';effort='low';status='done'
    started=[DateTime]::UtcNow.AddSeconds(-45).ToString('o');finished=[DateTime]::UtcNow.ToString('o');context_pct=7
}) }
Update-Board
$fractional = [IO.File]::ReadAllText((Join-Path $state 'board.md'), $utf8)
Assert ($fractional -match '\| fractional \|.*\| 0\.8 \|') 'Board minutes preserve fractional duration'
$digest = Join-Path $fixture 'digest.md'
$content = "Status: PARTIAL`n## Summary`n" + ('x' * 250) + "`nsecond`nthird`nfourth`n## Open issues and risks`n"
foreach ($i in 1..6) { $content += "- issue $i`n" }
Write-Utf8 $digest $content
$lines = @(Write-ReportDigest $digest $false)
Assert ($lines.Count -eq 9) 'Worker digest status + three summary + five risks'
Assert (@($lines | Where-Object { $_.Length -gt 200 -or -not $_.StartsWith('  | ') }).Count -eq 0) 'Digest prefix/200-character limit'
Assert ($lines[1].Length -eq 200 -and $lines[1].EndsWith('...')) 'Long digest truncated'
Write-Utf8 $digest "Verdict: NEEDS-WORK`nBlocking: yes`n## Issues`n- one`n- two`n## Other`n- excluded"
$lines = @(Write-ReportDigest $digest $true)
Assert ($lines.Count -eq 3 -and $lines[0] -eq '  | Verdict: NEEDS-WORK Blocking: yes') 'Reviewer digest'
$NoDigest = $true; Assert (@(Write-ReportDigest $digest $true).Count -eq 0) 'NoDigest suppresses'
$NoDigest = $false; Write-Utf8 $digest '# No sections'; Assert (@(Write-ReportDigest $digest $false).Count -eq 0) 'Missing sections silent'
Assert (@(Write-ReportDigest "$fixture/missing.md" $false).Count -eq 0) 'Missing report silent'
foreach ($invalid in @(-1,1.5,'1',$true,2147483648)) {
    $Plan = "$fixture/invalid.json"
    Write-Utf8 "$state/tasks/invalid.md" '# invalid'
    Write-Utf8 $Plan (ConvertTo-Json -InputObject @(@{task='invalid';model='luna';effort='low';timeoutMin=$invalid}))
    Throws { Read-BatchPlan } 'nonnegative integer'
}
$Plan = "$fixture/invalid.json"
Write-Utf8 $Plan '[{"task":"invalid","model":"luna","effort":"low","force":"true"}]'
Throws { Read-BatchPlan } 'force must be boolean'
Write-Utf8 $Plan '[{"task":"invalid","model":"luna","effort":"low","force":true,"timeoutMin":0,"reviewTimeoutMin":1}]'
Assert (@(Read-BatchPlan).Count -eq 1) 'New plan fields accepted'
# Simulate temporarily inaccessible rollout after a kill. Terminal status must survive.
function Get-Context($Events, $SessionId) { throw 'rollout temporarily locked' }
$result = Invoke-WorkerRun 'context-lock' 'gpt-6-luna' 'low' 'context-lock' $false $true $true $null
Assert ($result.Status -eq 'done' -and @(Read-Workers | Where-Object { $_.name -eq 'context-lock' })[0].context_source -eq 'approx') 'Rollout read failure cannot strand worker as running'
$shared = Join-Path $fixture 'shared.jsonl'
Write-Utf8 $shared "{`"token_count`":1}`nignored"
$stream = [IO.File]::Open($shared, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
try { Assert (@(Get-RolloutTokenLines $shared).Count -eq 1) 'Read/write-shared rollout works and filters telemetry' }
finally { $stream.Dispose() }
$sharedReport = Join-Path $fixture 'shared-report.md'
Write-Utf8 $sharedReport 'Status: DONE'
$stream = [IO.File]::Open($sharedReport, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
try { Assert ((Read-ReportText $sharedReport) -eq 'Status: DONE') 'Concurrent report writer permits shared board read' }
finally { $stream.Dispose() }
$stream = [IO.File]::Open($sharedReport, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert ((Read-ReportText $sharedReport) -eq '') 'Exclusively locked report skipped without breaking launcher' }
finally { $stream.Dispose() }
$token=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($Launcher,[ref]$token,[ref]$errors)
Assert ($errors.Count -eq 0 -and $PSVersionTable.PSVersion.Major -eq 5) 'Actual PS5.1 parse/runtime'
Write-Output "PASS: $script:checks checks; fixture=$fixture"
