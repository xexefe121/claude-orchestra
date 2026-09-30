$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'
$fixture = Join-Path $env:ORCHESTRA_TEST_ROOT ('unit-' + [guid]::NewGuid().ToString('N'))
$null = . $launcher init -Project $fixture
$script:checks = 0
function Assert($Value, [string]$Message) {
    if (-not $Value) { throw "FAIL: $Message" }
    $script:checks++
}
function Throws([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected $Pattern, got $message"
}
function Workers {
    $items = Get-Content -LiteralPath "$fixture/.orchestra/workers.json" -Raw | ConvertFrom-Json
    foreach ($item in $items) { $item }
}
function MakePlan($Entries) {
    Write-Utf8 "$fixture/plan.json" (ConvertTo-Json -InputObject @($Entries) -Depth 8)
}
$mock = @'
$utf8=New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding=$utf8
[Console]::OutputEncoding=$utf8
if($args[0] -eq '--version') {'2.1.285 (Claude Code)';return}
$prompt=[Console]::In.ReadToEnd()
$id=[regex]::Match($prompt,'\.orchestra/tasks/([^\s]+)\.md').Groups[1].Value
$root=(Get-Location).Path
[IO.File]::WriteAllText("$root/$id.args.json",(ConvertTo-Json -InputObject @($args)),$utf8)
[IO.File]::WriteAllText("$root/$id.begin",[DateTime]::UtcNow.ToString('o'),$utf8)
Start-Sleep -Milliseconds 1500
$tokens=150000
if($id -eq 'cap'){$tokens=210000}
@{type='system';subtype='init';session_id='fixture-session';model='claude-sonnet-5-5'}|ConvertTo-Json -Compress
@{type='assistant';message=@{model='claude-sonnet-5-5';usage=@{input_tokens=$tokens;cache_creation_input_tokens=0;cache_read_input_tokens=0};content=@()}}|ConvertTo-Json -Depth 8 -Compress
@{type='result';is_error=($id -eq 'fail');modelUsage=@{'claude-sonnet-5-5'=@{contextWindow=1000000}};result='DONE'}|ConvertTo-Json -Depth 8 -Compress
if($id -ne 'fail') {[IO.File]::WriteAllText("$root/.orchestra/reports/$id.md","Status: DONE`nVerdict: PASS",$utf8)}
[IO.File]::WriteAllText("$root/$id.end",[DateTime]::UtcNow.ToString('o'),$utf8)
exit 0
'@
Write-Utf8 "$fixture/claude.ps1" $mock
foreach ($id in @('cap','below','front','full','resume','legacy','a','b','c','fail','skip','transitive','invalid','reviewed','independent')) {
    Write-Utf8 "$fixture/.orchestra/tasks/$id.md" "# $id"
}
$oldClaude = $env:ORCHESTRA_CLAUDE
try {
    $testPrefix = [IO.Path]::GetFullPath($env:ORCHESTRA_TEST_ROOT).TrimEnd('\') + '\'
    if (-not [IO.Path]::GetFullPath($env:USERPROFILE).StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run through tests/run.ps1; isolated fake home required.'
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $env:USERPROFILE '.claude'))
    Write-Utf8 (Join-Path $env:USERPROFILE '.claude/AGENTS.md') 'fixture-global-rule'
    Write-Utf8 (Join-Path $env:USERPROFILE '.claude/CLAUDE.md') "@AGENTS.md`nfixture-secondary-rule"
    $env:ORCHESTRA_CLAUDE = "$fixture/claude.ps1"
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'PS5.1 parser'
    Assert (Test-Handoff 'claude' 210000 1000000 21) '210k Claude cap'
    Assert (-not (Test-Handoff 'claude' 150000 1000000 15)) '150k Claude no cap'
    Assert (Test-Handoff 'claude' 200000 1000000 20) '200k inclusive cap'
    Assert (Test-Handoff 'claude' 140000 200000 70) 'Claude 70% inclusive'
    Assert (-not (Test-Handoff 'claude' 139999 200000 70)) 'Claude exact ratio before rounded 70%'
    Assert (-not (Test-Handoff 'codex' 210000 1000000 21)) 'Codex no absolute cap'
    Assert (Test-Handoff 'codex' 140000 200000 70) 'Codex unchanged 70%'
    $line=& $launcher run -NoDigest -Project $fixture -Task cap -Model sonnet -Effort low
    Assert ($line.EndsWith(' HANDOFF-RECOMMENDED')) 'Integrated 210k suffix'
    Assert ((Workers)[0].profile -eq 'lean') 'Lean default saved'
    $captured=Get-Content -LiteralPath "$fixture/cap.args.json" -Raw|ConvertFrom-Json
    Assert ('--setting-sources' -in $captured -and '--strict-mcp-config' -in $captured -and '--safe-mode' -notin $captured) 'Lean isolation flags preserve explicit MCP'
    Assert ('--tools' -notin $captured -and '--disallowedTools' -notin $captured -and '--allowedTools' -notin $captured) 'No tool restriction'
    $rules=$captured[[Array]::IndexOf($captured,'--append-system-prompt')+1]
    Assert ($rules -match 'fixture-global-rule' -and $rules -match 'fixture-secondary-rule' -and $rules -notmatch '@AGENTS.md') 'Fixture global rules injected; import removed'
    $settings=Get-Content -LiteralPath "$fixture/.orchestra/runs/cap.sonnet-01.settings.json" -Raw|ConvertFrom-Json
    Assert ($settings.disableAllHooks -and $settings.enabledPlugins.'cc-plugin-agents-md@builtin' -eq $false) 'Hooks and built-in plugins disabled'
    $line=& $launcher run -NoDigest -Project $fixture -Task below -Model sonnet -Effort low
    Assert ($line -notmatch 'HANDOFF') 'Integrated 150k no suffix'
    $null=& $launcher run -NoDigest -Project $fixture -Task front -Model sonnet -Effort low -Profile frontend
    $front=@(Workers|Where-Object {$_.current_task -eq 'front'})[0]
    Assert ($front.profile -eq 'frontend') 'Frontend saved'
    $mcp=Get-Content -LiteralPath "$fixture/.orchestra/runs/front.$($front.name).mcp.json" -Raw|ConvertFrom-Json
    Assert ($mcp.mcpServers.playwright.command -eq 'npx' -and '@playwright/mcp@latest' -in $mcp.mcpServers.playwright.args) 'Playwright only configured'
    $null=& $launcher run -NoDigest -Project $fixture -Task resume -Resume -Name $front.name
    Assert (@(Workers|Where-Object {$_.name -eq $front.name})[0].profile -eq 'frontend') 'Resume preserves profile'
    $null=& $launcher run -NoDigest -Project $fixture -Task full -Model sonnet -Effort low -Profile full
    $captured=Get-Content -LiteralPath "$fixture/full.args.json" -Raw|ConvertFrom-Json
    Assert ('--safe-mode' -notin $captured -and '--strict-mcp-config' -notin $captured -and '--settings' -in $captured) 'Full retains normal loading with attribution override'
    $registry=Workers
    $legacy=@($registry|Where-Object {$_.current_task -eq 'full'})[0]
    $legacy.PSObject.Properties.Remove('profile')
    Write-Utf8 "$fixture/.orchestra/workers.json" (ConvertTo-Json -InputObject @($registry) -Depth 10)
    $null=& $launcher run -NoDigest -Project $fixture -Task legacy -Resume -Name $legacy.name
    Assert (@(Workers|Where-Object {$_.name -eq $legacy.name})[0].profile -eq 'full') 'Legacy resume preserves full behavior'
    $before=(Workers).Count
    MakePlan @(@{task='invalid';model='sonnet';effort='low';dependsOn=@('missing')})
    Throws {& $launcher batch -NoDigest -Project $fixture -Plan plan.json} 'Unknown dependency'
    MakePlan @(@{task='a';model='sonnet';effort='low';dependsOn=@('b')},@{task='b';model='sonnet';effort='low';dependsOn=@('a')})
    Throws {& $launcher batch -NoDigest -Project $fixture -Plan plan.json} 'cycle'
    MakePlan @(@{task='a';model='sonnet';effort='low'},@{task='a';model='sonnet';effort='low'})
    Throws {& $launcher batch -NoDigest -Project $fixture -Plan plan.json} 'Duplicate task'
    MakePlan @(@{task='missing';model='sonnet';effort='low'})
    Throws {& $launcher batch -NoDigest -Project $fixture -Plan plan.json} 'brief missing'
    MakePlan @(@{task='invalid';model='sonnet';effort='low';dependsOn='a'})
    Throws {& $launcher batch -NoDigest -Project $fixture -Plan plan.json} 'must be an array'
    MakePlan @(@{task='invalid';model='sonnet';effort='low';review='false'})
    Throws {& $launcher batch -NoDigest -Project $fixture -Plan plan.json} 'must be boolean'
    Assert ((Workers).Count -eq $before) 'All invalid plans launch nothing'
    $entriesForBatch=@(
        @{task='c';model='sonnet';effort='low';dependsOn=@('a')},
        @{task='a';model='sonnet';effort='low';profile='full'},
        @{task='b';model='sonnet';effort='low';profile='frontend'},
        @{task='skip';model='sonnet';effort='low';dependsOn=@('fail')},
        @{task='fail';model='sonnet';effort='low'},
        @{task='transitive';model='sonnet';effort='low';dependsOn=@('skip')},
        @{task='reviewed';model='sonnet';effort='low';review=$true;reviewModel='sonnet';reviewEffort='low'}
    )
    MakePlan $entriesForBatch
    $lines=@(& $launcher batch -NoDigest -Project $fixture -Plan plan.json)
    Assert ($lines.Count -eq 9) 'One line each plus review and summary'
    Assert ($lines[0] -match ' c done ' -and $lines[1] -match ' a done ' -and $lines[2] -match ' b done ') 'Plan-order output despite reversed dependency order'
    Assert ($lines[3] -eq '[orchestra] - skip skipped dep=fail') 'Failure skips dependent'
    Assert ($lines[5] -eq '[orchestra] - transitive skipped dep=skip') 'Transitive skips'
    Assert ($lines[7] -match 'reviewed-review done .*verdict=PASS') 'Batch reuses review path'
    Assert ($lines[8] -eq '[orchestra] batch done=4 failed=1 skipped=2') 'Batch summary'
    $aBegin=[DateTime]::Parse([IO.File]::ReadAllText("$fixture/a.begin"))
    $aEnd=[DateTime]::Parse([IO.File]::ReadAllText("$fixture/a.end"))
    $bBegin=[DateTime]::Parse([IO.File]::ReadAllText("$fixture/b.begin"))
    $bEnd=[DateTime]::Parse([IO.File]::ReadAllText("$fixture/b.end"))
    $cBegin=[DateTime]::Parse([IO.File]::ReadAllText("$fixture/c.begin"))
    Assert ($aBegin -lt $bEnd -and $bBegin -lt $aEnd) 'Independent tasks overlap'
    Assert ($cBegin -ge $aEnd) 'Dependent starts after done'
    Assert (-not [IO.File]::Exists("$fixture/skip.begin")) 'Skipped task never launched'
    Assert (@(Workers|Where-Object {$_.current_task -eq 'b'})[0].profile -eq 'frontend') 'Batch profile passed through'
    MakePlan @()
    Assert ((& $launcher batch -NoDigest -Project $fixture -Plan plan.json) -eq '[orchestra] batch done=0 failed=0 skipped=0') 'Empty batch'
    Write-Output "PASS: $script:checks checks; fixture=$fixture"
} finally { $env:ORCHESTRA_CLAUDE=$oldClaude }
