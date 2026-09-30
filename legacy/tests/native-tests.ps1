$ErrorActionPreference='Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'
$fixture=Join-Path $env:ORCHESTRA_TEST_ROOT ('native-unit-'+[guid]::NewGuid().ToString('N'))
$null=. $launcher init -Project $fixture
$script:checks=0
function Assert($Value,[string]$Message) {if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Throws([scriptblock]$Action,[string]$Pattern) {
    $message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Assert ($message -match $Pattern) "Expected $Pattern, got $message"
}
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'PS5.1 parser zero errors'
Assert ($PSVersionTable.PSVersion.Major -eq 5) 'Actual PS5.1 runtime'
function Get-Process {param($Name,$ErrorAction);foreach($p in $script:mockProcesses){$p}}
foreach($case in @(
    @('\Program Files\WindowsApps\OpenAI.Codex_99_x64__pkg\app\ChatGPT.exe',$true),
    @('\Users\test\AppData\Local\OpenAI\Codex\app\Codex.exe',$true),
    @('\Users\test\AppData\Local\OpenAI\Codex\Codex.exe',$true),
    @('\Users\test\AppData\Local\OpenAI\Codex\bin\hash\codex.exe',$false),
    @('\Program Files\WindowsApps\OpenAI.ChatGPT_99\app\ChatGPT.exe',$false),
    @('\npm\codex.exe',$false))) {
    $script:mockProcesses=@([pscustomobject]@{Path=$case[0]})
    Assert ((Test-CodexDesktopRunning) -eq $case[1]) "App detection $($case[0])"
}
$script:mockProcesses=@();Assert (-not (Test-CodexDesktopRunning)) 'App absent'
Remove-Item Function:\Get-Process
$configPath=Join-Path $fixture 'config.toml'
function Config([string]$Value){Write-Utf8 $configPath $Value}
$valid=@'
[mcp_servers.node_repl]
command = 'not-executed'
[mcp_servers.node_repl.env]
NODE_REPL_TRUSTED_SERVICES = '{"sky":"@oai/sky/service"}'
'@
Assert (-not (Test-NativeSkyConfig $configPath)) 'Config file absent'
Config $valid;Assert (Test-NativeSkyConfig $configPath) 'Literal JSON service registration'
Config ($valid.Replace("'{`"sky`":`"@oai/sky/service`"}'",'"{\"sky\":\"@oai/sky/service\"}"'))
Assert (Test-NativeSkyConfig $configPath) 'Basic TOML JSON string'
Config ($valid.Replace("'{`"sky`":`"@oai/sky/service`"}'", "'''`n{`"sky`":`"@oai/sky/service`"}`n'''"))
Assert (Test-NativeSkyConfig $configPath) 'Multiline literal string'
Config ($valid.Replace("'{`"sky`":`"@oai/sky/service`"}'",'"""{\"sky\":\"@oai/sky/service\"}"""'))
Assert (Test-NativeSkyConfig $configPath) 'Multiline basic string'
foreach($bad in @('', '[mcp_servers.other]', $valid.Replace('[mcp_servers.node_repl]','[mcp_servers.other]'),
    $valid.Replace('[mcp_servers.node_repl.env]','[mcp_servers.other.env]'),
    $valid.Replace('[mcp_servers.node_repl]',"[mcp_servers.node_repl]`nenabled = false"),
    $valid.Replace('"sky"','"browser"'),$valid.Replace('@oai/sky/service','untrusted'),
    $valid.Replace('{"sky":"@oai/sky/service"}','invalid json'),
    $valid.Replace('NODE_REPL_TRUSTED_SERVICES','# NODE_REPL_TRUSTED_SERVICES'))) {
    Config $bad;Assert (-not (Test-NativeSkyConfig $configPath)) 'Missing/disabled/invalid native config rejected'
}
Config ($valid+"`n[mcp_servers.other.env]`nNODE_REPL_TRUSTED_SERVICES = 'wrong'`n")
Assert (Test-NativeSkyConfig $configPath) 'Other server does not override node_repl'
$homeBefore=$env:CODEX_HOME
try {
    $env:CODEX_HOME=$fixture
    function Test-CodexDesktopRunning {return $script:appReady}
    $script:appReady=$false
    Throws {Assert-NativeComputerUseReady} 'BLOCKED: native CUA unavailable; Codex desktop app is not running'
    $script:appReady=$true;Config ''
    Throws {Assert-NativeComputerUseReady} 'BLOCKED: native CUA unavailable; config requires'
    Config $valid;Assert-NativeComputerUseReady
    Assert $true 'Ready preflight without model invocation'
    $cliPath=Join-Path $fixture 'fake.ps1';Write-Utf8 $cliPath ''
    $script:cliCalls=0;$script:runCalls=0;$script:lastPrompt=''
    function Resolve-Codex($RequestedModel,$NeedsComputer,$Previous) {
        $script:cliCalls++
        return [pscustomobject]@{Info=[pscustomobject]@{Path=$cliPath;VersionText='0.159.2';Family='path'};Model=$RequestedModel;Fallback=$null;Rule='auto'}
    }
    function Invoke-Codex($Exe,$Arguments,$Prompt,$Stdout,$Stderr) {
        $script:runCalls++;$script:lastPrompt=$Prompt
        Write-Utf8 $Stdout '{"type":"thread.started","thread_id":"mock-native"}'
        Write-Utf8 $Stderr ''
        $id=[regex]::Match($Prompt,'\.orchestra/tasks/([^\s]+)\.md').Groups[1].Value
        Write-Utf8 (Join-Path $state "reports/$id.md") 'Status: DONE'
        return 0
    }
    function Get-Context($Events,$SessionId){return @{tokens=0;window=0;source='approx'}}
    $ComputerUse=$true
    $script:appReady=$false
    Throws {Invoke-WorkerRun 'absent-app' 'gpt-6.1-sol' 'low' 'no-app' $false $true $true $null} 'app is not running'
    Assert ($script:cliCalls -eq 0 -and $script:runCalls -eq 0) 'Missing app fails before CLI/model calls'
    $script:appReady=$true;Config ''
    Throws {Invoke-WorkerRun 'absent-config' 'gpt-6.1-sol' 'low' 'no-config' $false $true $true $null} 'config requires'
    Assert ($script:cliCalls -eq 0 -and $script:runCalls -eq 0) 'Missing config fails before CLI/model calls'
    Assert (@(Read-Workers).Count -eq 0) 'Preflight failure does not register running worker'
    Config $valid
    $result=Invoke-WorkerRun 'fresh' 'gpt-6.1-sol' 'low' 'native' $false $true $true $null
    Assert ($result.Status -eq 'done') 'Mock native lifecycle'
    foreach($needle in @('mcp__node_repl__js',"const {sky} = await import('@oai/sky')",'sky.list_windows()','Never use browser-only cua_repl','BLOCKED: native CUA unavailable')) {
        Assert ($script:lastPrompt.Contains($needle)) "Native prompt $needle"
    }
    Assert ($result.Line -notmatch 'model-fallback=') 'No model fallback output'
    $ComputerUse=$false
    $result=Invoke-WorkerRun 'resumed' 'gpt-6.1-sol' 'low' 'native' $true $false $false $null
    Assert ($script:lastPrompt.Contains('Native desktop control:')) 'Resume inherits native instruction'
    $script:appReady=$false
    Throws {Invoke-WorkerRun 'resumed' 'gpt-6.1-sol' 'low' 'native' $true $false $false $null} 'app is not running'
    $result=Invoke-WorkerRun 'normal' 'gpt-6.1-sol' 'low' 'normal' $false $true $true $null
    Assert ($result.Status -eq 'done' -and -not $script:lastPrompt.Contains('Native desktop control:')) 'Non-GUI bypasses unavailable preflight'
} finally {$env:CODEX_HOME=$homeBefore}
Throws {Lock-DesktopWorker {throw 'action-failed'}} 'action-failed'
Assert ((Lock-DesktopWorker {'released'} 20) -eq 'released') 'Lock released after exception'
$marker=Join-Path $fixture 'held.txt'
$job=Start-Job -ScriptBlock {
    param($Marker)
    $m=New-Object Threading.Mutex($false,'Global\orchestra-desktop')
    $null=$m.WaitOne();[IO.File]::WriteAllText($Marker,'held')
    Start-Sleep -Seconds 2
    $m.ReleaseMutex();$m.Dispose()
} -ArgumentList $marker
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Assert ([IO.File]::Exists($marker)) 'Separate process holds global desktop mutex'
    Throws {Lock-DesktopWorker {'must-not-run'} 50} 'Timed out waiting for native CUA desktop lock'
    $result=Invoke-WorkerRun 'normal-while-held' 'gpt-6.1-sol' 'low' 'normal-while-held' $false $true $true $null
    Assert ($result.Status -eq 'done') 'Non-GUI worker completes while desktop lock held'
    $null=Wait-Job $job;Receive-Job $job|Out-Null
    Assert ((Lock-DesktopWorker {'released'} 100) -eq 'released') 'Lock available after holder finishes'
} finally {Stop-Job $job;Remove-Job $job}
# Keep an open handle so the named object survives the owner process exiting.
$survivor=New-Object Threading.Mutex($false,'Global\orchestra-desktop')
$abandonedMarker=Join-Path $fixture 'abandoned.txt'
$job=Start-Job -ScriptBlock {
    param($Marker)
    $m=New-Object Threading.Mutex($false,'Global\orchestra-desktop')
    $null=$m.WaitOne();[IO.File]::WriteAllText($Marker,'held')
    [Environment]::Exit(0)
} -ArgumentList $abandonedMarker
try {
    $null=Wait-Job $job
    Assert ([IO.File]::Exists($abandonedMarker)) 'Owner exits while holding desktop mutex'
    Assert ((Lock-DesktopWorker {'recovered'} 100) -eq 'recovered') 'Abandoned desktop mutex recovered'
} finally {$survivor.Dispose();Remove-Job $job -Force}
"PASS: $script:checks checks; fixture=$fixture"
