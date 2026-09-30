$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $env:ORCHESTRA_TEST_ROOT ('install-unit-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$utf8 = New-Object Text.UTF8Encoding($false)
$script:checks = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw "FAIL: $Message" }; $script:checks++ }
function Read([string]$Path) { return [IO.File]::ReadAllText($Path, $utf8) }
function Write-TestFile([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
$mock = Join-Path $fixture 'cli.ps1'
Write-TestFile $mock @'
if ($args[0] -eq 'auth') { $global:LASTEXITCODE = 0; return }
if ($args[0] -eq '--version') { 'codex-cli mock-version'; $global:LASTEXITCODE = 0; return }
throw 'Unexpected mock CLI call'
'@
function Get-Command {
    param([string]$Name, $ErrorAction)
    if ($Name -in @('claude', 'codex', 'node', 'npx')) {
        if (-not $global:orchestraMockMissingPrereqs) { return [pscustomobject]@{ Source = $mock } }
        return
    }
    return Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction SilentlyContinue
}
function Get-AppxPackage { param($Name, $ErrorAction) }
$installer = Join-Path $repo 'install.ps1'
$uninstaller = Join-Path $repo 'uninstall.ps1'
$oldHome = $env:USERPROFILE
$oldLocal = $env:LOCALAPPDATA
try {
    # This suite is already a child process of run.ps1; override home before any install.
    $env:USERPROFILE = Join-Path $fixture 'fresh-home'
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData/Local'
    $output = @(& $installer)
    $skillRoot = Join-Path $env:USERPROFILE '.claude/skills'
    $agents = Join-Path $env:USERPROFILE '.claude/AGENTS.md'
    foreach ($name in @('orchestra', 'orchestra-claude')) {
        Assert (Test-Path -LiteralPath (Join-Path $skillRoot "$name/SKILL.md")) "Fresh $name install"
    }
    Assert (-not (Test-Path -LiteralPath $agents)) 'Default install does not add rule'
    Assert ($output[-2] -eq 'Usage: /orchestra <project> <goal>' -and $output[-1] -eq 'Usage: /orchestra-claude <project> <goal>') 'Two usage lines last'
    Assert (@($output | Where-Object { $_ -match '\[OK\].*mock-version' }).Count -eq 1) 'Codex version reported'
    Assert (@($output | Where-Object { $_ -match '\[OK\] Claude CLI login' }).Count -eq 1) 'Auth status checked'
    Write-TestFile (Join-Path $skillRoot 'orchestra/local-marker.txt') 'preserve backup'
    Write-TestFile $agents "Existing rules.`r`n"
    $null = & $installer -AddAgentsRule
    $null = & $installer -AddAgentsRule
    $rules = Read $agents
    Assert (([regex]::Matches($rules, '(?m)^<!-- orchestra:start -->')).Count -eq 1) 'AddAgentsRule twice has one block'
    Assert ($rules.StartsWith("Existing rules.`r`n")) 'Existing rules preserved'
    Assert (-not $rules.Contains('orchestra:git:start')) 'Optional git block not installed automatically'
    Assert (-not ($rules -match '(?<!\r)\n')) 'CRLF rule file stays CRLF'
    foreach ($name in @('orchestra', 'orchestra-claude')) {
        Assert (@(Get-ChildItem -LiteralPath $skillRoot -Directory -Filter "$name.bak-*").Count -eq 2) "$name reinstall backups"
    }
    $backup = Get-ChildItem -LiteralPath $skillRoot -Directory -Filter 'orchestra.bak-*' | Sort-Object Name | Select-Object -First 1
    Assert ((Read (Join-Path $backup.FullName 'local-marker.txt')) -eq 'preserve backup') 'Backup content intact'
    $optional = [regex]::Match((Read (Join-Path $repo 'docs/AGENTS-snippet.md')), '(?ms)^<!-- orchestra:git:start -->.*?^<!-- orchestra:git:end -->').Value
    Write-TestFile $agents ($rules + ($optional -replace "`r?`n", "`r`n") + "`r`n")
    $null = & $uninstaller
    Assert (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'orchestra'))) 'Uninstall orchestra'
    Assert (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'orchestra-claude'))) 'Uninstall orchestra-claude'
    $rules = Read $agents
    Assert (-not $rules.Contains('orchestra:start') -and -not $rules.Contains('orchestra:git:start')) 'Both marked blocks removed'
    Assert ($rules.StartsWith('Existing rules.')) 'Uninstall preserves unrelated rules'
    Assert (@(Get-ChildItem -LiteralPath $skillRoot -Directory -Filter 'orchestra.bak-*').Count -eq 3) 'Uninstall backup made'
    $null = & $uninstaller
    Assert (@(Get-ChildItem -LiteralPath $skillRoot -Directory -Filter 'orchestra.bak-*').Count -eq 3) 'Uninstall idempotent'

    $env:USERPROFILE = Join-Path $fixture 'claude-home'
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData/Local'
    $claudeRules = Join-Path $env:USERPROFILE '.claude/CLAUDE.md'
    Write-TestFile $claudeRules "Keep this rule.`n"
    $global:orchestraMockMissingPrereqs = $true
    $output = @(& $installer -AddAgentsRule)
    Assert ((Read $claudeRules).Contains('orchestra:start')) 'Existing CLAUDE.md fallback'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude/AGENTS.md'))) 'Fallback does not create AGENTS.md'
    $missingCount = @($output | Where-Object { $_ -match '^\[MISSING\]' }).Count
    Assert ($missingCount -eq 6) "All missing prerequisites listed (count=$missingCount)"
    [void][IO.Directory]::CreateDirectory((Join-Path $env:LOCALAPPDATA 'OpenAI/Codex'))
    $output = @(& $installer)
    Assert (@($output | Where-Object { $_ -match '^\[MISSING\] Codex desktop app' }).Count -eq 1) 'Empty desktop directory is not an installed app'
    Write-TestFile (Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/app/ChatGPT.exe') ''
    $output = @(& $installer)
    Assert (@($output | Where-Object { $_ -match '^\[OK\] Codex desktop app' }).Count -eq 1) 'Desktop executable found'
    $null = & $uninstaller
    Assert ((Read $claudeRules).StartsWith('Keep this rule.') -and -not (Read $claudeRules).Contains('orchestra:start')) 'CLAUDE.md cleanup'

    # Exercise the exact raw-script pipeline offline, using a zip of this repo's payload.
    $payload = Join-Path $fixture 'payload/claude-orchestra-main'
    [void][IO.Directory]::CreateDirectory($payload)
    Copy-Item -LiteralPath (Join-Path $repo 'skills') -Destination $payload -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'docs') -Destination $payload -Recurse
    $global:orchestraFixtureArchive = Join-Path $fixture 'main.zip'
    Compress-Archive -LiteralPath $payload -DestinationPath $global:orchestraFixtureArchive
    $global:orchestraDownloadCalls = 0
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
        if ($Uri -notmatch '^https://github\.com/[^/]+/claude-orchestra/archive/refs/heads/main\.zip$') { throw 'Unexpected archive URL' }
        Copy-Item -LiteralPath $global:orchestraFixtureArchive -Destination $OutFile
        $global:orchestraDownloadCalls++
    }
    function Invoke-RestMethod { param([string]$Uri); return Read $installer }
    $env:USERPROFILE = Join-Path $fixture 'download-home'
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData/Local'
    $tls = [Net.ServicePointManager]::SecurityProtocol
    $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'orchestra-install-*').Count
    $null = Invoke-RestMethod 'mock-raw-install' | Invoke-Expression
    Assert (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude/skills/orchestra/scripts/orchestra.ps1')) 'Raw pipeline installed from downloaded zip'
    Assert ($global:orchestraDownloadCalls -eq 1) 'Zip route used once'
    Assert ([Net.ServicePointManager]::SecurityProtocol -eq $tls) 'TLS setting restored'
    Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'orchestra-install-*').Count -eq $before) 'Download temp cleaned'
    $null = & ([scriptblock]::Create((Invoke-RestMethod 'mock-raw-install'))) -AddAgentsRule
    Assert ((Read (Join-Path $env:USERPROFILE '.claude/AGENTS.md')).Contains('orchestra:start')) 'Raw script switch works'
    $null = & $uninstaller
} finally {
    $env:USERPROFILE = $oldHome
    $env:LOCALAPPDATA = $oldLocal
}
"PASS: $script:checks checks; mock prerequisites, clone/raw install, backups, rules, uninstall"
