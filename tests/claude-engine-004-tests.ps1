$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'
$fixture = Join-Path $env:ORCHESTRA_TEST_ROOT ('claude-unit-004-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$null = . $launcher init -Project $fixture
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected '$Pattern'; got '$message'"
}
function Brief([string]$Id) {
    Write-Utf8 (Join-Path $fixture ".orchestra\tasks\$Id.md") "# $Id`nTrivial fixture."
}
function Registry { return @(Get-Content -LiteralPath (Join-Path $fixture '.orchestra\workers.json') -Raw | ConvertFrom-Json) }
function Worker([string]$WorkerName) { return @(Registry | Where-Object { $_.name -eq $WorkerName })[0] }

$mock = @'
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
if ($env:MOCK_ARGS) { $args = $env:MOCK_ARGS | ConvertFrom-Json }
if ($args[0] -eq '--version') {
    if ((Split-Path $PSCommandPath -Leaf) -eq 'codex.ps1') { 'codex-cli 0.999.0' } else { '2.1.285 (Claude Code)' }
    $global:LASTEXITCODE = 0
    return
}
$prompt = [Console]::In.ReadToEnd()
$root = (Get-Location).Path
[IO.File]::WriteAllText((Join-Path $root 'arguments.json'), (ConvertTo-Json -InputObject @($args)), $utf8)
[IO.File]::WriteAllText((Join-Path $root 'prompt.txt'), $prompt, $utf8)
$id = [regex]::Match($prompt, '\.orchestra/tasks/([^\s]+)\.md').Groups[1].Value
$task = [IO.File]::ReadAllText((Join-Path $root ".orchestra/tasks/$id.md"), $utf8)
$review = $id.EndsWith('-review')
$text = "DONE`n.orchestra/reports/$id.md"
if ($review) { $report = "# Review`nVerdict: PASS`n" } else { $report = "# $id report`nStatus: DONE`n" }
if ($id -ne 'stale') { [IO.File]::WriteAllText((Join-Path $root ".orchestra/reports/$id.md"), $report, $utf8) }
if ($args[0] -eq 'exec') {
    $session = 'mock-codex-session'
    if ($args[1] -eq 'resume') { $session = $args[2] }
    @{ type='thread.started'; thread_id=$session } | ConvertTo-Json -Compress
    @{ type='turn.completed'; usage=@{input_tokens=4567;model_context_window=200000} } | ConvertTo-Json -Compress
    $last = $args[[Array]::IndexOf($args, '-o') + 1]
    [IO.File]::WriteAllText($last, $text, $utf8)
} else {
    $model = $args[[Array]::IndexOf($args, '--model') + 1]
    $session = [guid]::NewGuid().ToString()
    $resume = [Array]::IndexOf($args, '--resume')
    if ($resume -ge 0) { $session = $args[$resume + 1] }
    if ($id -ne 'result-session') {
        @{type='system';subtype='init';session_id=$session;model=$model} | ConvertTo-Json -Compress
    }
    $tokens = 1000
    if ($resume -ge 0) { $tokens = 2000 }
    @{type='assistant';message=@{model=$model;usage=@{input_tokens=$tokens;cache_creation_input_tokens=2000;cache_read_input_tokens=3000};content=@(@{type='text';text=$text})}} | ConvertTo-Json -Depth 8 -Compress
    # Ignore side-agent context and model evidence.
    @{type='assistant';parent_tool_use_id='side';message=@{model='side-model';usage=@{input_tokens=999999}}} | ConvertTo-Json -Depth 8 -Compress
    $usage = @{}
    $usage[$model] = @{inputTokens=999999;contextWindow=10000}
    if ($id -eq 'approx') { $usage = $null }
    if ($id -eq 'model-evidence') {
        $usage = @{'claude-actual-model'=@{contextWindow=10000}}
    }
    @{type='result';session_id=$session;result=$text;is_error=($id -eq 'result-error');modelUsage=$usage} | ConvertTo-Json -Depth 8 -Compress
}
[Console]::Error.WriteLine('fixture stderr')
exit 0
'@
$claude = Join-Path $fixture 'claude.ps1'
$codex = Join-Path $fixture 'codex.ps1'
Write-Utf8 $claude $mock
Write-Utf8 $codex $mock
$codexExe = Join-Path $fixture 'codex.exe'
$wrapper = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;
public class MockCodex {
    public static int Main(string[] args) {
        var start = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "codex.ps1") + "\"");
        start.UseShellExecute = false;
        start.EnvironmentVariables["MOCK_ARGS"] = new JavaScriptSerializer().Serialize(args);
        using (var process = Process.Start(start)) { process.WaitForExit(); return process.ExitCode; }
    }
}
'@
Add-Type -TypeDefinition $wrapper -ReferencedAssemblies 'System.Web.Extensions' -OutputAssembly $codexExe -OutputType ConsoleApplication
$oldClaude = $env:ORCHESTRA_CLAUDE
$oldCodex = $env:ORCHESTRA_CODEX
try {
    $env:ORCHESTRA_CLAUDE = $claude
    $env:ORCHESTRA_CODEX = $codexExe
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'PS5.1 parser'
    foreach ($pair in @(@('sonnet','claude-sonnet-5-5'),@('opus','claude-opus-5-5'),@('fable','claude-fable-5-1'),@('haiku','claude-haiku-4-5-20251001'))) {
        Assert ((Normalize-Model $pair[0]) -eq $pair[1]) "Pin $($pair[0])"
        Assert ((Get-ModelPrefix $pair[1]) -eq $pair[0]) "Name $($pair[0])"
        Assert ((Get-Engine $pair[0]) -eq 'claude') "Engine $($pair[0])"
    }
    Assert ((Normalize-Model 'claude-future-id') -eq 'claude-future-id') 'Full Claude slug unchanged'
    Assert ((Get-Engine 'gpt-6.1-sol') -eq 'codex') 'Codex engine unchanged'
    foreach ($id in @('first','resume','opus','fable','haiku','full','approx','result-session','model-evidence','stale','result-error','cross','reverse','same','codex','legacy')) { Brief $id }
    $env:MOCK_ENGINE = 'claude'
    $line = & $launcher run -NoDigest -Project $fixture -Task first -Model sonnet -Effort medium -Cli desktop
    Assert ($line -match '^\[orchestra\] sonnet-01 first done exit=0 ctx=6k/10k \(60%\) report=') 'Claude output contract'
    $first = Worker 'sonnet-01'
    Assert ($first.engine -eq 'claude' -and $first.resolved_model -eq 'claude-sonnet-5-5') 'Engine and actual model saved'
    Assert ($first.context_tokens -eq 6000 -and $first.context_source -eq 'stream-json') 'Last assistant cache-aware context'
    $session = $first.session_id
    $capturedArgs = Get-Content -LiteralPath (Join-Path $fixture 'arguments.json') -Raw | ConvertFrom-Json
    Assert ('--verbose' -in $capturedArgs -and '--dangerously-skip-permissions' -in $capturedArgs) 'Verbose/full permissions'
    Assert ($capturedArgs[0] -eq '-p' -and 'stream-json' -in $capturedArgs) 'Print stream-json'
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'prompt.txt') -Raw) -match 'Before anything else read .orchestra/WORKER.md') 'Same fresh worker prompt via stdin'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture '.orchestra/runs/first.sonnet-01.last.md')) -eq "DONE`n.orchestra/reports/first.md") 'Final result persisted'
    Assert ((Get-Content -LiteralPath (Join-Path $fixture '.orchestra/runs/first.sonnet-01.err.log') -Raw) -match 'fixture stderr') 'Stderr separated'
    $line = & $launcher run -NoDigest -Project $fixture -Task resume -Resume -Name sonnet-01
    $resumed = Worker 'sonnet-01'
    Assert ($resumed.session_id -eq $session -and $resumed.context_tokens -eq 7000) 'Resume session/context growth'
    Assert ($line.EndsWith(' HANDOFF-RECOMMENDED')) '70% handoff'
    Assert ($resumed.effort -eq 'medium' -and $resumed.cli_family -eq 'claude') 'Resume retains settings'
    foreach ($model in @('opus','fable','haiku')) {
        $line = & $launcher run -NoDigest -Project $fixture -Task $model -Model $model -Effort ultra
        Assert ($line -match "\[orchestra\] $model-01 $model done") "Dry-run $model"
        Assert ((Worker "$model-01").resolved_effort -eq 'max') "Ultra maps max $model"
    }
    $line = & $launcher run -NoDigest -Project $fixture -Task full -Model claude-future-id -Effort xhigh
    Assert ($line -match 'done exit=0') 'Full Claude id launch'
    $line = & $launcher run -NoDigest -Project $fixture -Task approx -Model sonnet -Effort low
    $approx = Worker 'sonnet-02'
    Assert ($approx.context_window -eq 200000 -and $approx.context_source -eq 'approx') 'Missing window fallback'
    $line = & $launcher run -NoDigest -Project $fixture -Task result-session -Model sonnet -Effort low
    Assert ([bool](Worker 'sonnet-03').session_id) 'Result session id fallback'
    $line = & $launcher run -NoDigest -Project $fixture -Task model-evidence -Model sonnet -Effort low
    Assert ((Worker 'sonnet-04').resolved_model -eq 'claude-actual-model') 'Model usage evidence beats request'
    Write-Utf8 (Join-Path $fixture '.orchestra/reports/stale.md') 'Old report'
    $line = & $launcher run -NoDigest -Project $fixture -Task stale -Model sonnet -Effort low
    Assert ($line -match 'failed exit=0') 'Stale report fails'
    $line = & $launcher run -NoDigest -Project $fixture -Task result-error -Model sonnet -Effort low
    Assert ($line -match 'failed exit=1') 'CLI result is_error fails'
    Throws { & $launcher run -NoDigest -Project $fixture -Task first -Model sonnet -ComputerUse } 'ComputerUse applies only to Codex'
    Throws { & $launcher run -NoDigest -Project $fixture -Task resume -Resume -Name sonnet-01 -Model sol } 'cannot change worker engine'
    $lines = @(& $launcher run -NoDigest -Project $fixture -Task cross -Model sonnet -Effort low -Review -ReviewModel luna -ReviewEffort low)
    Assert ($lines.Count -eq 2 -and $lines[1] -match 'done exit=0.*verdict=PASS') 'Claude worker/Codex reviewer'
    $lines = @(& $launcher run -NoDigest -Project $fixture -Task reverse -Model luna -Effort low -Review -ReviewModel haiku -ReviewEffort low)
    Assert ($lines.Count -eq 2 -and $lines[1] -match 'done exit=0.*verdict=PASS') 'Codex worker/Claude reviewer'
    Assert ((Worker 'rev-02').engine -eq 'claude') 'Reviewer engine saved'
    $lines = @(& $launcher run -NoDigest -Project $fixture -Task same -Model haiku -Effort low -Review -ReviewModel haiku -ReviewEffort low)
    Assert ($lines.Count -eq 2 -and $lines[1] -match 'done exit=0.*verdict=PASS') 'Claude worker/Claude reviewer'
    $unicodeId = 'utf8-caf' + [char]0xe9 + '-' + [char]::ConvertFromUtf32(0x1f600)
    Brief $unicodeId
    $line = & $launcher run -NoDigest -Project $fixture -Task $unicodeId -Model sonnet -Effort low
    Assert ($line -match 'done exit=0') 'UTF-8 stdin/log/report paths'
    $unicodeLast = Join-Path $fixture ".orchestra/runs/$unicodeId.sonnet-08.last.md"
    Assert ([IO.File]::ReadAllText($unicodeLast) -eq "DONE`n.orchestra/reports/$unicodeId.md") 'UTF-8 final text preserved'
    $lastBytes = [IO.File]::ReadAllBytes($unicodeLast)
    Assert (-not ($lastBytes[0] -eq 0xef -and $lastBytes[1] -eq 0xbb -and $lastBytes[2] -eq 0xbf)) 'Final text has no BOM'
    $line = & $launcher run -NoDigest -Project $fixture -Task codex -Model sol -Effort high
    Assert ($line -match 'sol-01 codex done') 'Codex launch regression'
    Assert ((Worker 'sol-01').engine -eq 'codex') 'Codex metadata'
    $workers = Registry
    $legacy = @($workers | Where-Object { $_.name -eq 'sol-01' })[0]
    $legacy.PSObject.Properties.Remove('engine')
    Write-Utf8 (Join-Path $fixture '.orchestra/workers.json') (ConvertTo-Json -InputObject @($workers) -Depth 10)
    $line = & $launcher run -NoDigest -Project $fixture -Task legacy -Resume -Name sol-01
    Assert ($line -match 'done exit=0' -and (Worker 'sol-01').engine -eq 'codex') 'Legacy worker resume'
    Write-Output "PASS: $script:checks checks; fixture=$fixture"
} finally {
    $env:ORCHESTRA_CLAUDE = $oldClaude
    $env:ORCHESTRA_CODEX = $oldCodex
    $env:MOCK_ENGINE = $null
}
