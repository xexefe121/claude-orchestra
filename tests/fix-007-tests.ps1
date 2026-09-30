$ErrorActionPreference='Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'
$fixture=Join-Path $env:ORCHESTRA_TEST_ROOT ('unit-' + [guid]::NewGuid().ToString('N'))
$null=. $launcher init -Project $fixture
$script:checks=0
function Assert($Value,[string]$Message) {
    if(-not $Value){throw "FAIL: $Message"}
    $script:checks++
}
function SameBytes([byte[]]$Left,[byte[]]$Right) {
    return [Convert]::ToBase64String($Left) -eq [Convert]::ToBase64String($Right)
}
$payload='caf'+[char]0xe9+' '+[char]0x2014+' na'+[char]0xef+'ve'
$cases=@{
    ascii=[byte[]](65,83,67,73,73,13,10)
    empty=[byte[]]@()
    unicode=$utf8.GetBytes($payload+"`r`n")
    utf8bom=[byte[]](@(239,187,191)+@($utf8.GetBytes($payload)))
    utf16le=[byte[]](255,254,233,0)
    utf16be=[byte[]](254,255,0,233)
    utf32le=[byte[]](255,254,0,0,233,0,0,0)
    utf32be=[byte[]](0,0,254,255,0,0,0,233)
}
foreach($name in $cases.Keys) {
    $path=Join-Path $fixture "$name.md"
    [IO.File]::WriteAllBytes($path,$cases[$name])
    $stamp=[DateTime]::UtcNow.AddHours(-1)
    [IO.File]::SetLastWriteTimeUtc($path,$stamp)
    Ensure-Utf8Bom $path
    $expected=$cases[$name]
    if($name -eq 'unicode'){$expected=[byte[]](@(239,187,191)+@($cases[$name]))}
    Assert (SameBytes ([IO.File]::ReadAllBytes($path)) $expected) "$name exact bytes"
    if($name -ne 'unicode'){Assert ([IO.File]::GetLastWriteTimeUtc($path) -eq $stamp) "$name untouched mtime"}
    $firstStamp=[IO.File]::GetLastWriteTimeUtc($path)
    Ensure-Utf8Bom $path
    Assert (SameBytes ([IO.File]::ReadAllBytes($path)) $expected) "$name idempotent bytes"
    Assert ([IO.File]::GetLastWriteTimeUtc($path) -eq $firstStamp) "$name idempotent mtime"
}
Assert ((Get-Content -LiteralPath "$fixture/unicode.md" -Raw).TrimEnd("`r","`n") -eq $payload) 'PS5.1 default Get-Content decodes Unicode'
foreach($profileName in @('lean','frontend','full')) {
    $argsForProfile=@(Get-ClaudeProfileArguments $profileName "settings-$profileName")
    $settings=Get-Content -LiteralPath "$fixture/.orchestra/runs/settings-$profileName.settings.json" -Raw|ConvertFrom-Json
    Assert ('--settings' -in $argsForProfile) "$profileName settings supplied"
    Assert ($settings.attribution.commit -ceq '' -and $settings.attribution.pr -ceq '' -and
        $settings.attribution.sessionUrl -eq $false) "$profileName attribution disabled"
    if($profileName -eq 'full') {
        Assert ($settings.PSObject.Properties.Count -eq 1 -and -not $settings.PSObject.Properties['disableAllHooks']) 'Full attribution-only override'
        Assert ('--strict-mcp-config' -notin $argsForProfile -and '--setting-sources' -notin $argsForProfile) 'Full loading retained'
    } else {Assert ($settings.disableAllHooks -eq $true -and '--strict-mcp-config' -in $argsForProfile) "$profileName isolation retained"}
}
foreach($path in @("$fixture/.orchestra/WORKER.md","$fixture/.orchestra/context.md","$fixture/.orchestra/tasks/main.md")) {
    Write-Utf8 $path $payload
}
$script:before=@{}
foreach($name in @('WORKER.md','context.md','tasks/main.md')) {$script:before[$name]=[IO.File]::ReadAllBytes("$fixture/.orchestra/$name")}
function Resolve-Claude($Previous) {return [pscustomobject]@{Path='fixture';VersionText='2.1.285';Family='claude'}}
function Invoke-Codex([string]$Exe,[string[]]$Arguments,[string]$Prompt,[string]$Stdout,[string]$Stderr) {
    foreach($name in @('WORKER.md','context.md','tasks/main.md')) {
        $expected=[byte[]](@(239,187,191)+@($script:before[$name]))
        Assert (SameBytes ([IO.File]::ReadAllBytes("$fixture/.orchestra/$name")) $expected) "Dispatch prepared $name"
    }
    $taskId=[regex]::Match($Prompt,'\.orchestra/tasks/([^\s]+)\.md').Groups[1].Value
    if($taskId.EndsWith('-review')) {
        $bytes=[IO.File]::ReadAllBytes("$fixture/.orchestra/tasks/$taskId.md")
        Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Generated Unicode review brief BOM before dispatch'
        $template=Join-Path (Split-Path (Split-Path $launcher -Parent) -Parent) 'templates/review.md'
        $expected=[byte[]](@(239,187,191)+@($utf8.GetBytes([IO.File]::ReadAllText($template,$utf8).Replace('{{TASK}}',$Task))))
        Assert (SameBytes $bytes $expected) 'Generated review content unchanged beyond BOM'
    }
    Write-Utf8 "$fixture/.orchestra/reports/$taskId.md" "Status: DONE`nVerdict: PASS"
    Write-Utf8 $Stdout '{"type":"result","session_id":"fixture","result":"DONE","is_error":false}'
    Write-Utf8 $Stderr ''
    return 0
}
$null=Invoke-WorkerRun 'main' 'claude-sonnet-5-5' 'low' 'mock-main' $false $true $true $null
# Use the real review template and a Unicode task id, avoiding template mutations.
$Task='review-'+[char]0xe9
$reviewTask="$Task-review"
$template=Join-Path (Split-Path (Split-Path $launcher -Parent) -Parent) 'templates/review.md'
Write-Utf8 "$fixture/.orchestra/tasks/$reviewTask.md" ([IO.File]::ReadAllText($template,$utf8).Replace('{{TASK}}',$Task))
$null=Invoke-WorkerRun $reviewTask 'claude-sonnet-5-5' 'low' 'mock-review' $false $true $true 'rev'
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'PS5.1 parser'
"PASS: $script:checks checks; fixture=$fixture"
