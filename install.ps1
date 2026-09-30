param([switch]$AddAgentsRule)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$downloadRoot = $null

function Backup-Skill([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.bak-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')
        Move-Item -LiteralPath $Path -Destination $backup
        Write-Output "Backup: $backup"
    }
}

function Show-Prerequisite([string]$Name, [bool]$Found, [string]$Fix, [string]$Detail = '') {
    if ($Found) { Write-Output "[OK] $Name $Detail" }
    else { Write-Output "[MISSING] $Name. Fix: $Fix" }
}

try {
    $sourceRoot = $PSScriptRoot
    if (-not $sourceRoot -or -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'skills/orchestra/scripts/orchestra.ps1'))) {
        $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('orchestra-install-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($downloadRoot)
        $archive = Join-Path $downloadRoot 'main.zip'
        # Older Windows PowerShell sessions may otherwise negotiate obsolete TLS.
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/xexefe121/claude-orchestra/archive/refs/heads/main.zip' -OutFile $archive
        } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
        Expand-Archive -LiteralPath $archive -DestinationPath $downloadRoot
        $sourceRoot = Join-Path $downloadRoot 'claude-orchestra-main'
    }
    foreach ($required in @('skills/orchestra/scripts/orchestra.ps1', 'skills/orchestra-claude/SKILL.md', 'docs/AGENTS-snippet.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required))) { throw "Package file missing: $required" }
    }
    $claudeRoot = Join-Path $env:USERPROFILE '.claude'
    $skillsRoot = Join-Path $claudeRoot 'skills'
    [void][IO.Directory]::CreateDirectory($skillsRoot)
    foreach ($name in @('orchestra', 'orchestra-claude')) {
        $destination = Join-Path $skillsRoot $name
        Backup-Skill $destination
        Copy-Item -LiteralPath (Join-Path $sourceRoot "skills/$name") -Destination $destination -Recurse
        Write-Output "Installed: $destination"
    }
    if ($AddAgentsRule) {
        $rulePath = Join-Path $claudeRoot 'AGENTS.md'
        $claudePath = Join-Path $claudeRoot 'CLAUDE.md'
        if (-not (Test-Path -LiteralPath $rulePath) -and (Test-Path -LiteralPath $claudePath)) { $rulePath = $claudePath }
        $current = ''
        if (Test-Path -LiteralPath $rulePath) { $current = [IO.File]::ReadAllText($rulePath, $utf8) }
        if (-not ($current -match '(?m)^<!-- orchestra:start -->\s*$')) {
            $snippetText = [IO.File]::ReadAllText((Join-Path $sourceRoot 'docs/AGENTS-snippet.md'), $utf8)
            $snippetMatch = [regex]::Match($snippetText, '(?ms)^<!-- orchestra:start -->\r?\n.*?^<!-- orchestra:end -->')
            if (-not $snippetMatch.Success) { throw 'Activation snippet markers missing.' }
            $snippet = $snippetMatch.Value
            $eol = "`n"
            if ($current.Contains("`r`n")) { $eol = "`r`n" }
            $snippet = ($snippet -replace "`r?`n", $eol)
            if ($current.Length -gt 0) { $current = $current.TrimEnd("`r", "`n") + $eol + $eol }
            [IO.File]::WriteAllText($rulePath, $current + $snippet + $eol, $utf8)
            Write-Output "Rule added: $rulePath"
        } else { Write-Output "Rule already present: $rulePath" }
    } else {
        Write-Output 'Opt-in rule: run .\install.ps1 -AddAgentsRule, or append docs/AGENTS-snippet.md to ~/.claude/AGENTS.md (CLAUDE.md if used).'
    }
    Write-Output 'Prerequisites (nothing is installed automatically):'
    $claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
    Show-Prerequisite 'Claude CLI (optional for Claude workers)' ([bool]$claudeCommand) 'irm https://claude.ai/install.ps1 | iex'
    $loggedIn = $false
    if ($claudeCommand) {
        try { $global:LASTEXITCODE = 1; $null = & $claudeCommand.Source auth status 2>&1; $loggedIn = ($LASTEXITCODE -eq 0) }
        catch { $loggedIn = $false }
    }
    Show-Prerequisite 'Claude CLI login (optional for Claude workers)' $loggedIn 'claude auth login'
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    $codexVersion = ''
    if ($codexCommand) {
        try { $codexVersion = ((& $codexCommand.Source --version 2>$null) -join ' ').Trim() }
        catch { $codexVersion = 'version check failed' }
    }
    Show-Prerequisite 'Codex CLI' ([bool]$codexCommand) 'npm install -g @openai/codex; codex login' $codexVersion
    Write-Output '[CHECK] Codex login: run codex login status; if needed run codex login.'
    $desktopFound = $false
    if ($env:LOCALAPPDATA) {
        foreach ($relative in @('OpenAI/Codex/app/ChatGPT.exe', 'OpenAI/Codex/app/Codex.exe', 'OpenAI/Codex/ChatGPT.exe', 'OpenAI/Codex/Codex.exe')) {
            if ([IO.File]::Exists((Join-Path $env:LOCALAPPDATA $relative))) { $desktopFound = $true; break }
        }
    }
    if (-not $desktopFound -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        try { $desktopFound = (@(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue).Count -gt 0) } catch { }
    }
    Show-Prerequisite 'Codex desktop app (optional for computer use)' $desktopFound 'Start-Process https://chatgpt.com/codex; install and open the Windows desktop app'
    foreach ($name in @('node', 'npx')) {
        Show-Prerequisite "$name (optional for Playwright profile)" ([bool](Get-Command $name -ErrorAction SilentlyContinue)) 'winget install OpenJS.NodeJS.LTS; reopen PowerShell'
    }
    Write-Output 'Computer use also needs the native node_repl/Sky service configured; see skills/orchestra/computer-use.md.'
} finally {
    if ($downloadRoot -and (Test-Path -LiteralPath $downloadRoot)) {
        $resolved = [IO.Path]::GetFullPath($downloadRoot)
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
            ([IO.Path]::GetFileName($resolved) -notmatch '^orchestra-install-[0-9a-f]{32}$')) { throw 'Unexpected installer temp path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output 'Usage: /orchestra <project> <goal>'
Write-Output 'Usage: /orchestra-claude <project> <goal>'
