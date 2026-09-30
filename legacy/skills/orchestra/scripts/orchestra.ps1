param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('init', 'run', 'status', 'batch', 'board')][string]$Command,
    [string]$Project = (Get-Location).Path,
    [string]$Task,
    [string]$Model = 'sol',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Effort = 'high',
    [string]$Name,
    [switch]$Resume,
    [switch]$Force,
    [ValidateRange(0, 2147483647)][int]$TimeoutMin = 90,
    [ValidateRange(0, 2147483647)][int]$ReviewTimeoutMin = 30,
    [switch]$NoDigest,
    [switch]$Review,
    [string]$ReviewModel = 'astra',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$ReviewEffort = 'high',
    [switch]$ComputerUse,
    [ValidateSet('lean', 'frontend', 'full')][string]$Profile = 'lean',
    [string]$Plan,
    # 'auto': prefer PATH/npm for supported models; ComputerUse keeps desktop-first.
    # 'desktop': the Codex app's bundled CLI.
    # 'newest': highest version among bundled and PATH CLIs.
    [ValidateSet('auto', 'desktop', 'newest')][string]$Cli = 'auto'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$Project = [IO.Path]::GetFullPath($Project)
$state = Join-Path $Project '.orchestra'
$workersFile = Join-Path $state 'workers.json'
$runsFile = Join-Path $state 'runs.json'

function Write-Utf8([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, $utf8)
}

function Ensure-Utf8Bom([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    $bytes = [IO.File]::ReadAllBytes($Path)
    # Preserve files with an existing UTF-8, UTF-16, or UTF-32 BOM verbatim.
    if (($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) -or
        ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) -or
            ($bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff))) -or
        ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and
            $bytes[2] -eq 0xfe -and $bytes[3] -eq 0xff)) { return }
    foreach ($byte in $bytes) {
        if ($byte -gt 0x7f) {
            # Add only the BOM; never decode/re-encode or change line endings.
            $marked = New-Object byte[] ($bytes.Length + 3)
            $marked[0] = 0xef; $marked[1] = 0xbb; $marked[2] = 0xbf
            [Array]::Copy($bytes, 0, $marked, 3, $bytes.Length)
            [IO.File]::WriteAllBytes($Path, $marked)
            return
        }
    }
}

function Get-Mutex {
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $utf8.GetBytes($state.ToLowerInvariant())
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    return New-Object Threading.Mutex($false, "Global\orchestra-$hash")
}

function Lock-Workers([scriptblock]$Action) {
    $mutex = Get-Mutex
    $held = $false
    try {
        try { $held = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out waiting for workers.json lock.' }
        & $Action
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-CodexDesktopRunning {
    # The packaged desktop app is ChatGPT.exe; codex.exe under bin is only a CLI.
    foreach ($process in @(Get-Process -Name ChatGPT, Codex -ErrorAction SilentlyContinue)) {
        try { $path = $process.Path } catch { continue }
        if ($path -match '(?i)[\\/]WindowsApps[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/](ChatGPT|Codex)\.exe$' -or
            $path -match '(?i)[\\/]OpenAI[\\/]Codex[\\/](?:app[\\/])?(ChatGPT|Codex)\.exe$') {
            return $true
        }
    }
    return $false
}

function Test-NativeSkyConfig([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $false }
    # Read only MCP sections; never emit config contents or unrelated values.
    $config = [IO.File]::ReadAllText($Path, $utf8)
    $server = [regex]::Match($config, '(?ms)^\s*\[mcp_servers\.node_repl\][^\r\n]*\r?\n(.*?)(?=^\s*\[|\z)')
    if (-not $server.Success -or $server.Groups[1].Value -match '(?m)^\s*enabled\s*=\s*false\s*(?:#.*)?$') {
        return $false
    }
    $environment = [regex]::Match($config, '(?ms)^\s*\[mcp_servers\.node_repl\.env\][^\r\n]*\r?\n(.*?)(?=^\s*\[|\z)')
    if (-not $environment.Success) { return $false }
    $value = [regex]::Match($environment.Groups[1].Value,
        '(?ms)^\s*NODE_REPL_TRUSTED_SERVICES\s*=\s*(''\x27\x27.*?''\x27\x27|""".*?"""|''[^''\r\n]*''|"(?:\\.|[^"\\\r\n])*")\s*(?:#.*)?$')
    if (-not $value.Success) { return $false }
    $encoded = $value.Groups[1].Value
    try {
        if ($encoded.StartsWith("'''")) { $json = $encoded.Substring(3, $encoded.Length - 6) }
        elseif ($encoded.StartsWith('"""')) { $json = ConvertFrom-Json ('"' + $encoded.Substring(3, $encoded.Length - 6).TrimStart("`r", "`n").Replace("`r", '\r').Replace("`n", '\n') + '"') }
        elseif ($encoded.StartsWith("'")) { $json = $encoded.Substring(1, $encoded.Length - 2) }
        else { $json = ConvertFrom-Json $encoded }
        $services = ConvertFrom-Json $json
        return $services.sky -ceq '@oai/sky/service'
    } catch { return $false }
}

function Assert-NativeComputerUseReady {
    if (-not (Test-CodexDesktopRunning)) {
        throw 'BLOCKED: native CUA unavailable; Codex desktop app is not running.'
    }
    $configRoot = $env:CODEX_HOME
    if (-not $configRoot) { $configRoot = Join-Path $env:USERPROFILE '.codex' }
    if (-not (Test-NativeSkyConfig (Join-Path $configRoot 'config.toml'))) {
        throw 'BLOCKED: native CUA unavailable; config requires enabled [mcp_servers.node_repl] with NODE_REPL_TRUSTED_SERVICES sky=@oai/sky/service.'
    }
}

function Lock-DesktopWorker([scriptblock]$Action, [int]$TimeoutMilliseconds = 1800000) {
    $mutex = New-Object Threading.Mutex($false, 'Global\orchestra-desktop')
    $held = $false
    try {
        try { $held = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out waiting for native CUA desktop lock (another ComputerUse worker is running).' }
        & $Action
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-Workers {
    if (-not [IO.File]::Exists($workersFile)) { return }
    $json = [IO.File]::ReadAllText($workersFile, $utf8)
    if ([string]::IsNullOrWhiteSpace($json)) { return }
    $parsed = ConvertFrom-Json -InputObject $json
    foreach ($item in $parsed) { Write-Output $item }
}

function Save-Workers($Workers) {
    $json = ConvertTo-Json -InputObject @($Workers) -Depth 10
    Write-Utf8 $workersFile ($json + "`n")
}

function Assert-ResumeAllowed($Worker, [bool]$AllowFull) {
    if ($AllowFull) { return }
    $engine = 'codex'
    if ($Worker.engine) { $engine = $Worker.engine }
    elseif ((Get-Engine $Worker.model) -eq 'claude') { $engine = 'claude' }
    if (Test-Handoff $engine $Worker.context_tokens $Worker.context_window $Worker.context_pct) {
        throw "Worker $($Worker.name) is at its handoff threshold ($($Worker.context_pct)%, $($Worker.context_tokens) tokens). Start a fresh worker, or use -Force with -Resume."
    }
}

function Get-ReportField([string]$Text, [string]$Field) {
    $match = [regex]::Match($Text, '(?mi)^' + [regex]::Escape($Field) + ':[ \t]*([^\r\n]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
}

function Get-ReportSection([string]$Text, [string]$Section) {
    $match = [regex]::Match($Text, '(?mi)^#{1,6}\s+' + [regex]::Escape($Section) + '\s*\r?$')
    if (-not $match.Success) { return }
    $tail = $Text.Substring($match.Index + $match.Length)
    foreach ($line in ($tail -split '\r?\n')) {
        if ($line -match '^#{1,6}\s+') { break }
        if (-not [string]::IsNullOrWhiteSpace($line)) { $line.Trim() }
    }
}

function Read-ReportText([string]$Path) {
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, $utf8, $true)
        return $reader.ReadToEnd()
    } catch [IO.IOException] {
        # Another worker can be creating its report during a board refresh.
        return ''
    } finally { if ($reader) { $reader.Dispose() } }
}

function Write-ReportDigest([string]$Path, [bool]$Reviewer) {
    if ($NoDigest -or -not [IO.File]::Exists($Path)) { return }
    $text = Read-ReportText $Path
    $lines = @()
    if ($Reviewer) {
        $verdict = Get-ReportField $text 'Verdict'
        $blocking = Get-ReportField $text 'Blocking'
        if ($verdict -or $blocking) {
            $fields = @()
            if ($verdict) { $fields += "Verdict: $verdict" }
            if ($blocking) { $fields += "Blocking: $blocking" }
            $lines += $fields -join ' '
        }
        $lines += @(Get-ReportSection $text 'Issues' | Where-Object { $_ -match '^[-*+]\s+' } | Select-Object -First 5)
    } else {
        $status = Get-ReportField $text 'Status'
        if ($status) { $lines += "Status: $status" }
        $lines += @(Get-ReportSection $text 'Summary' | Select-Object -First 3)
        $lines += @(Get-ReportSection $text 'Open issues and risks' | Where-Object { $_ -match '^[-*+]\s+' } | Select-Object -First 5)
    }
    foreach ($line in @($lines | Select-Object -First 10)) {
        $value = '  | ' + $line
        if ($value.Length -gt 200) { $value = $value.Substring(0, 197) + '...' }
        Write-Output $value
    }
}

function Read-TaskRuns {
    if (-not [IO.File]::Exists($runsFile)) { return }
    foreach ($item in (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($runsFile, $utf8)))) { $item }
}

# Called only while holding the project mutex; latest record per task survives worker resumes.
function Save-TaskRun($Run) {
    $records = @(Read-TaskRuns | Where-Object { $_.task -ne $Run.task }) + @($Run)
    Write-Utf8 $runsFile ((ConvertTo-Json -InputObject @($records) -Depth 8) + "`n")
}

function Get-BoardDate($Value) {
    if (-not $Value) { return $null }
    try { return [DateTime]::Parse([string]$Value).ToUniversalTime() } catch { return $null }
}

function Format-BoardCell($Value) {
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Update-Board {
    Lock-Workers {
        $workers = @(Read-Workers)
        $records = @{}
        foreach ($record in @(Read-TaskRuns)) { $records[$record.task] = $record }
        # Old projects have only last-run worker state. Infer prior task times from files.
        foreach ($worker in $workers) {
            foreach ($id in @(@($worker.tasks) + @($worker.current_task) | Select-Object -Unique)) {
                if (-not $id -or $records.ContainsKey($id)) { continue }
                $current = $id -eq $worker.current_task
                $record = [pscustomobject]@{
                    task = $id; worker = $worker.name; model = $worker.model; effort = $worker.effort
                    status = 'unknown'; started = $null; finished = $null; context_pct = $null
                }
                if ($current) {
                    $record.status = $worker.status; $record.started = $worker.started
                    $record.finished = $worker.finished; $record.context_pct = $worker.context_pct
                }
                $records[$id] = $record
            }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $state 'reports') -File -Filter '*.md')) {
            if (-not $records.ContainsKey($file.BaseName)) {
                $records[$file.BaseName] = [pscustomobject]@{
                    task = $file.BaseName; worker = '-'; model = '-'; effort = '-'; status = 'unknown'
                    started = $null; finished = $null; context_pct = $null
                }
            }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $state 'runs') -File -Filter '*.jsonl')) {
            if ($file.BaseName -match '^(.*)\.([^.]+)$') {
                $id = $Matches[1]; $workerName = $Matches[2]
                if (-not $records.ContainsKey($id)) {
                    $records[$id] = [pscustomobject]@{
                        task = $id; worker = $workerName; model = '-'; effort = '-'; status = 'unknown'
                        started = $file.CreationTimeUtc.ToString('o'); finished = $file.LastWriteTimeUtc.ToString('o'); context_pct = $null
                    }
                } elseif ($records[$id].worker -eq '-') {
                    $records[$id].worker = $workerName
                }
            }
        }
        $rows = @()
        foreach ($record in $records.Values) {
            $report = Join-Path $state "reports/$($record.task).md"
            $status = $record.status
            $started = Get-BoardDate $record.started
            $finished = Get-BoardDate $record.finished
            $verdict = ''
            if ([IO.File]::Exists($report)) {
                $reportText = Read-ReportText $report
                $reportedStatus = Get-ReportField $reportText 'Status'
                if ($reportedStatus) { $status = $reportedStatus }
                $verdict = Get-ReportField $reportText 'Verdict'
                if (-not $finished -and $record.status -ne 'running') { $finished = [IO.File]::GetLastWriteTimeUtc($report) }
            }
            $review = Join-Path $state "reports/$($record.task)-review.md"
            if ([IO.File]::Exists($review)) { $verdict = Get-ReportField (Read-ReportText $review) 'Verdict' }
            $log = Join-Path $state "runs/$($record.task).$($record.worker).jsonl"
            if ([IO.File]::Exists($log)) {
                if (-not $started) { $started = [IO.File]::GetCreationTimeUtc($log) }
                if (-not $finished -and $record.status -ne 'running') { $finished = [IO.File]::GetLastWriteTimeUtc($log) }
            }
            $minutes = '-'; $finishLabel = '-'; $sortTime = [DateTime]::MinValue
            if ($started) {
                $end = [DateTime]::UtcNow
                if ($finished) { $end = $finished }
                $minutes = [Math]::Round([Math]::Max([double]0, ($end - $started).TotalMinutes), 1).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                $sortTime = $started
            }
            if ($finished) { $finishLabel = $finished.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'); $sortTime = $finished }
            $pct = '-'
            if ($null -ne $record.context_pct) { $pct = [string]$record.context_pct }
            $rows += [pscustomobject]@{
                Task = $record.task; Worker = $record.worker; Model = "$($record.model) $($record.effort)"
                Status = $status; Verdict = $verdict; Percent = $pct; Minutes = $minutes; Finished = $finishLabel; Sort = $sortTime
            }
        }
        $lines = @('# Task board', '', '| task | worker | model+effort | status | review verdict | ctx % | minutes | finished (local time) |',
            '| --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($row in @($rows | Sort-Object -Property @{Expression='Sort'; Descending=$true}, Task)) {
            $cells = @([string]$row.Task, [string]$row.Worker, [string]$row.Model, [string]$row.Status, [string]$row.Verdict, [string]$row.Percent, [string]$row.Minutes, [string]$row.Finished)
            $lines += '| ' + (($cells | ForEach-Object { Format-BoardCell $_ }) -join ' | ') + ' |'
        }
        $totals = @($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
        $running = @()
        foreach ($worker in @($workers | Where-Object { $_.status -eq 'running' })) {
            if ($worker.launcher_pid -and -not (Get-Process -Id $worker.launcher_pid -ErrorAction SilentlyContinue)) { continue }
            $start = Get-BoardDate $worker.started
            $elapsed = '?'
            if ($start) { $elapsed = [Math]::Round(([DateTime]::UtcNow - $start).TotalMinutes, 1).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }
            $running += "$($worker.name) (${elapsed}m)"
        }
        $runningText = 'none'
        if ($running.Count -gt 0) { $runningText = $running -join ', ' }
        $lines += ''
        $lines += ('Totals: ' + ($totals -join ', ') + '; running workers: ' + $runningText)
        Write-Utf8 (Join-Path $state 'board.md') (($lines -join "`n") + "`n")
    }
}

function Ensure-State([bool]$Notes) {
    foreach ($folder in @($state, (Join-Path $state 'tasks'), (Join-Path $state 'reports'), (Join-Path $state 'runs'))) {
        if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }
    }
    $templates = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates'
    foreach ($file in @('context.md', 'progress.md', 'WORKER.md')) {
        $source = Join-Path $templates $file
        $target = Join-Path $state $file
        if (-not [IO.File]::Exists($target)) {
            if ([IO.File]::Exists($source)) {
                Write-Utf8 $target ([IO.File]::ReadAllText($source, $utf8))
            } elseif ($Notes) {
                Write-Output "Template missing; skipped $file"
            }
        }
    }
    Lock-Workers {
        if (-not [IO.File]::Exists($workersFile)) { Write-Utf8 $workersFile "[]`n" }
    }
    Write-Utf8 (Join-Path $state '.gitignore') "runs/`n"
}

$script:codexInfo = @{}

function Get-CliFamily([string]$Path) {
    $bundleRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin')) + '\'
    if ([IO.Path]::GetFullPath($Path).StartsWith($bundleRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return 'desktop'
    }
    return 'path'
}

function Get-CodexInfo([string]$Path) {
    $Path = [IO.Path]::GetFullPath($Path)
    if ($script:codexInfo.ContainsKey($Path)) { return $script:codexInfo[$Path] }
    $stamp = [IO.File]::GetLastWriteTimeUtc($Path).Ticks
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $key = [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes("$Path|$stamp"))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $cache = Join-Path ([IO.Path]::GetTempPath()) "orchestra-models-$key.json"
    $saved = $null
    # The model catalog can change server-side without a new executable; expire after 24 h.
    if ([IO.File]::Exists($cache) -and
        ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($cache)).TotalHours -lt 24) {
        try {
            $saved = [IO.File]::ReadAllText($cache, $utf8) | ConvertFrom-Json
            if ($saved.path -ne $Path -or $saved.stamp -ne $stamp -or -not $saved.version -or
                $null -eq $saved.models) { $saved = $null }
        } catch { $saved = $null }
    }
    $raw = $null
    if ($saved) { $raw = 'codex-cli ' + $saved.version }
    else {
        try { $raw = (& $Path --version 2>$null | Select-Object -First 1) } catch { }
    }
    $version = [version]'0.0.0'
    $versionText = 'unknown'
    $release = $false
    if ($raw -match '^codex-cli\s+(\d+)\.(\d+)\.(\d+)(-\S+)?') {
        $version = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        $versionText = "$($Matches[1]).$($Matches[2]).$($Matches[3])$($Matches[4])"
        $release = -not $Matches[4]
    }
    $models = $null
    if ($saved) { $models = @($saved.models) }
    $info = [pscustomobject]@{
        Path = $Path; Version = $version; VersionText = $versionText; Release = $release
        Native = [IO.Path]::GetExtension($Path) -eq '.exe'; Family = (Get-CliFamily $Path)
        Models = $models; Cache = $cache; Stamp = $stamp; ModelError = $null
    }
    $script:codexInfo[$Path] = $info
    return $info
}

function Get-CodexModels($Info) {
    if ($null -ne $Info.Models) { return $Info.Models }
    if ($Info.ModelError) { return }
    try {
        $raw = (& $Info.Path debug models 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "debug models exited $LASTEXITCODE" }
        $data = ConvertFrom-Json -InputObject $raw
        if ($null -eq $data.models) { throw 'debug models returned no models array' }
        $Info.Models = @($data.models | ForEach-Object { $_.slug } | Where-Object { $_ })
        $saved = [pscustomobject]@{
            path = $Info.Path; stamp = $Info.Stamp; version = $Info.VersionText; models = @($Info.Models)
        }
        # Unique temporary files keep concurrent launchers from reading partial JSON.
        $temporary = $Info.Cache + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            Write-Utf8 $temporary (ConvertTo-Json -InputObject $saved -Depth 4)
            Move-Item -LiteralPath $temporary -Destination $Info.Cache -Force
        } catch {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            # Cache failure must not prevent a supported model from launching.
        }
        return $Info.Models
    } catch { $Info.ModelError = $_.Exception.Message }
}

function Get-CodexCandidates([bool]$IncludePath) {
    $candidates = New-Object System.Collections.ArrayList
    $bundleRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    foreach ($folder in @(Get-ChildItem -LiteralPath $bundleRoot -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $folder.FullName 'codex.exe'
        if ([IO.File]::Exists($exe)) { [void]$candidates.Add($exe) }
    }
    $onPath = $null
    if ($IncludePath -or $candidates.Count -eq 0) { $onPath = Get-Command codex -ErrorAction SilentlyContinue }
    if ($onPath) {
        $shim = $onPath.Source
        $parent = Split-Path $shim -Parent
        $real = Join-Path $parent 'codex.exe'
        if (-not [IO.File]::Exists($real)) {
            $package = Join-Path $parent 'node_modules\@openai\codex'
            $real = @(Get-ChildItem -LiteralPath $package -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName)[0]
        }
        if ($real -and [IO.File]::Exists($real)) { [void]$candidates.Add($real) }
        else { [void]$candidates.Add($shim) }
    }
    $versions = @()
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $info = Get-CodexInfo $candidate
        if ($info.VersionText -ne 'unknown') { $versions += $info }
    }
    if ($versions.Count -eq 0) { throw 'Codex CLI not found. Set ORCHESTRA_CODEX or install codex.' }
    return ($versions | Sort-Object -Property @{Expression = 'Version'; Descending = $true},
        @{Expression = 'Release'; Descending = $true}, @{Expression = 'Native'; Descending = $true})
}

function Resolve-Codex([string]$RequestedModel, [bool]$NeedsComputer, $Previous) {
    $rule = $Cli
    if ($Previous -and $Previous.cli_rule) { $rule = $Previous.cli_rule }
    $selected = $null
    $fallback = $null
    $candidates = @()
    if ($env:ORCHESTRA_CODEX) {
        if (-not [IO.File]::Exists($env:ORCHESTRA_CODEX)) { throw "ORCHESTRA_CODEX not found: $env:ORCHESTRA_CODEX" }
        $selected = Get-CodexInfo $env:ORCHESTRA_CODEX
    } elseif ($Previous -and $Previous.cli_path -and [IO.File]::Exists($Previous.cli_path)) {
        $selected = Get-CodexInfo $Previous.cli_path
    } else {
        $includePath = ($rule -ne 'desktop') -or
            ($Previous -and $Previous.cli_family -eq 'path')
        $candidates = @(Get-CodexCandidates $includePath)
        if ($Previous -and $Previous.cli_family) {
            $candidates = @($candidates | Where-Object { $_.Family -eq $Previous.cli_family })
        }
        if ($candidates.Count -eq 0) { throw 'No Codex CLI found in the required session family.' }
        if ($rule -ne 'auto') { $selected = $candidates[0] }
        else {
            # Ordinary workers prefer PATH/npm; native CUA retains desktop-first selection.
            $preferredFamily = 'path'
            if ($NeedsComputer) { $preferredFamily = 'desktop' }
            $ordered = @($candidates | Where-Object { $_.Family -eq $preferredFamily }) +
                @($candidates | Where-Object { $_.Family -ne $preferredFamily })
            foreach ($candidate in $ordered) {
                if ($RequestedModel -in @(Get-CodexModels $candidate)) { $selected = $candidate; break }
            }
        }
    }
    if (-not $selected) {
        $checked = ($candidates | ForEach-Object {
            $detail = ''
            if ($_.ModelError) { $detail = "; $($_.ModelError)" }
            "$($_.Path) ($($_.VersionText)$detail)"
        }) -join ', '
        throw "No Codex CLI lists model '$RequestedModel'. CLIs checked: $checked"
    }
    if ($Previous -and -not $env:ORCHESTRA_CODEX -and $rule -eq 'auto' -and
        $RequestedModel -notin @(Get-CodexModels $selected)) {
        throw "Saved session CLI $($selected.Path) ($($selected.VersionText)) does not list model '$RequestedModel'. Resume must reuse its CLI family."
    }
    $resolvedModel = $RequestedModel
    if ($fallback) { $resolvedModel = $fallback }
    return [pscustomobject]@{ Info = $selected; Model = $resolvedModel; Fallback = $fallback; Rule = $rule }
}

# CreateProcess quoting: backslashes before a quote or final quote need doubling.
function Quote-Argument([string]$Value) {
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $result = '"'
    $slashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') { $slashes++; continue }
        if ($char -eq '"') {
            $result += ('\' * ($slashes * 2 + 1)) + '"'
        } else {
            $result += ('\' * $slashes) + $char
        }
        $slashes = 0
    }
    return $result + ('\' * ($slashes * 2)) + '"'
}

function Initialize-WorkerJob {
    if ('OrchestraJobProcess011' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;

public sealed class OrchestraJobProcess011 : IDisposable {
    public Process Process;
    public AnonymousPipeServerStream Input, Output, Error;
    private IntPtr job;
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct Startup {
        public int cb; public string reserved, desktop, title;
        public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
        public ushort show, reservedSize; public IntPtr reservedData, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo {
        public IntPtr process, thread; public uint pid, tid;
    }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimit {
        public long processTime, jobTime; public uint flags;
        public UIntPtr minWorkingSet, maxWorkingSet; public uint activeProcesses;
        public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
        public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit {
        public BasicLimit basic; public IoCounters io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttrs,
        IntPtr threadAttrs, bool inherit, uint flags, IntPtr environment, string cwd,
        ref Startup startup, out ProcessInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimit limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    private static void Check(bool okay) { if (!okay) throw new Win32Exception(Marshal.GetLastWin32Error()); }

    public static OrchestraJobProcess011 Start(string exe, string commandLine, string cwd) {
        var child = new OrchestraJobProcess011(); var info = new ProcessInfo();
        try {
            child.job = CreateJobObject(IntPtr.Zero, null); Check(child.job != IntPtr.Zero);
            var limits = new ExtendedLimit(); limits.basic.flags = 0x2000; // KILL_ON_JOB_CLOSE
            Check(SetInformationJobObject(child.job, 9, ref limits, (uint)Marshal.SizeOf(limits)));
            child.Input = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
            child.Output = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
            child.Error = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
            var startup = new Startup(); startup.cb = Marshal.SizeOf(startup); startup.flags = 0x100;
            startup.stdin = new IntPtr(long.Parse(child.Input.GetClientHandleAsString()));
            startup.stdout = new IntPtr(long.Parse(child.Output.GetClientHandleAsString()));
            startup.stderr = new IntPtr(long.Parse(child.Error.GetClientHandleAsString()));
            // Suspend before any worker code runs: even immediate/detached children inherit this job.
            Check(CreateProcess(exe, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true,
                0x08000004, IntPtr.Zero, cwd, ref startup, out info)); // NO_WINDOW | SUSPENDED
            Check(AssignProcessToJobObject(child.job, info.process));
            child.Process = Process.GetProcessById((int)info.pid);
            child.Process.Handle.ToInt64(); // Retain exit-code access even if the parent exits immediately.
            child.Input.DisposeLocalCopyOfClientHandle(); child.Output.DisposeLocalCopyOfClientHandle();
            child.Error.DisposeLocalCopyOfClientHandle();
            if (ResumeThread(info.thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            return child;
        } catch {
            if (info.process != IntPtr.Zero) TerminateProcess(info.process, 1);
            child.Dispose(); throw;
        } finally {
            if (info.thread != IntPtr.Zero) CloseHandle(info.thread);
            if (info.process != IntPtr.Zero) CloseHandle(info.process);
        }
    }
    public void Kill(uint exitCode) { Check(TerminateJobObject(job, exitCode)); }
    public void Dispose() {
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        if (Input != null) Input.Dispose(); if (Output != null) Output.Dispose(); if (Error != null) Error.Dispose();
        if (Process != null) Process.Dispose();
    }
}
'@
}

function Invoke-Codex([string]$Exe, [string[]]$Arguments, [string]$Prompt,
                      [string]$Stdout, [string]$Stderr, [int]$LimitMin = $TimeoutMin) {
    if ([IO.Path]::GetExtension($Exe) -eq '.ps1') {
        $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Exe) + $Arguments
        $Exe = (Get-Command powershell.exe).Source
    }
    Initialize-WorkerJob
    if ([IO.Path]::IsPathRooted($Exe)) { $Exe = [IO.Path]::GetFullPath($Exe) }
    $commandLine = (Quote-Argument $Exe) + ' ' + (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $child = $null; $outFile = $null; $errFile = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $expired = $false; $parentExited = $false; $parentExitMs = 0
    try {
        $child = [OrchestraJobProcess011]::Start($Exe, $commandLine, $Project)
        $process = $child.Process
        $outFile = [IO.File]::Create($Stdout); $errFile = [IO.File]::Create($Stderr)
        $outTask = $child.Output.CopyToAsync($outFile); $errTask = $child.Error.CopyToAsync($errFile)
        $bytes = $utf8.GetBytes($Prompt + "`n")
        try { $child.Input.Write($bytes, 0, $bytes.Length) }
        catch [IO.IOException] { } # An early native crash can close stdin before prompt delivery.
        finally { $child.Input.Dispose() }
        while ($true) {
            if (-not $parentExited) {
                $parentExited = $process.WaitForExit(100)
                if ($parentExited) { $parentExitMs = $timer.Elapsed.TotalMilliseconds }
            } else { [Threading.Thread]::Sleep(100) }
            if ($parentExited -and $outTask.IsCompleted -and $errTask.IsCompleted) { break }
            $expired = $LimitMin -gt 0 -and $timer.Elapsed.TotalMinutes -ge $LimitMin
            $drainCapped = $LimitMin -eq 0 -and $parentExited -and
                ($timer.Elapsed.TotalMilliseconds - $parentExitMs) -ge 30000
            if ($expired -or $drainCapped) {
                if ($expired) { $script:workerTimedOut = $true }
                # Job ownership survives parent exit; PID snapshots/taskkill cannot guarantee this.
                $child.Kill(124)
                if (-not $process.WaitForExit(5000)) { throw 'Worker did not exit after job termination.' }
                if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 5000)) {
                    throw 'Worker streams did not close after job termination.'
                }
                break
            }
        }
        [void]$outTask.GetAwaiter().GetResult(); [void]$errTask.GetAwaiter().GetResult()
        if ($expired) { return 124 }
        return $process.ExitCode
    } finally {
        if ($child) { $child.Dispose() }
        if ($outFile) { $outFile.Dispose() }; if ($errFile) { $errFile.Dispose() }
    }
}

function Get-CrashReason([long]$ExitCode, [string]$ErrorLog) {
    if (($ExitCode -ge 0 -and $ExitCode -le 2147483648) -or -not [IO.File]::Exists($ErrorLog)) { return }
    $tail = @(Get-Content -LiteralPath $ErrorLog -Encoding UTF8 -Tail 20) -join "`n"
    if ($tail -match '(?i)(memory allocation.*failed|failed to allocate|allocation.*fail|out of memory)') { return 'alloc-failure' }
    if ($tail -match '(?i)(panic|panicked)') { return 'panic' }
}
function Get-RunEvents([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    foreach ($line in [IO.File]::ReadLines($Path)) {
        try { Write-Output (ConvertFrom-Json -InputObject $line) } catch { }
    }
}

function Get-RolloutTokenLines([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream, $utf8, $true)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line.IndexOf('"token_count"') -ge 0) { $line }
        }
    } finally { $reader.Dispose() }
}

function Get-Context($Events, [string]$SessionId) {
    $result = @{ tokens = 0; window = 0; source = 'approx' }
    if ($SessionId) {
        $sessions = Join-Path $env:USERPROFILE '.codex\sessions'
        $file = Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter "rollout-*-$SessionId.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($file) {
            foreach ($line in (Get-RolloutTokenLines $file.FullName)) {
                # Rollouts get large; only parse token_count lines.
                if ($line.IndexOf('"token_count"') -lt 0) { continue }
                try {
                    $event = $line | ConvertFrom-Json
                    if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count' -and
                        $null -ne $event.payload.info.last_token_usage.input_tokens) {
                        $result.tokens = [long]$event.payload.info.last_token_usage.input_tokens
                        $result.window = [long]$event.payload.info.model_context_window
                        $result.source = 'rollout'
                    }
                } catch { }
            }
        }
    }
    if ($result.source -eq 'approx') {
        foreach ($event in $Events) {
            if ($event.type -eq 'turn.completed' -and $event.usage) {
                $result.tokens = [long]$event.usage.input_tokens
                if ($event.usage.model_context_window) {
                    $result.window = [long]$event.usage.model_context_window
                }
            }
        }
    }
    return $result
}

function Get-Engine([string]$Value) {
    if ($Value -match '^(sonnet|opus|fable|haiku)$' -or $Value -like 'claude-*') { return 'claude' }
    return 'codex'
}

function Resolve-Claude($Previous) {
    $path = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if ($env:ORCHESTRA_CLAUDE) { $path = $env:ORCHESTRA_CLAUDE }
    elseif ($Previous -and $Previous.cli_path -and [IO.File]::Exists($Previous.cli_path)) {
        $path = $Previous.cli_path
    } elseif (-not [IO.File]::Exists($path)) {
        $command = Get-Command claude -ErrorAction SilentlyContinue
        if ($command) { $path = $command.Source }
    }
    if (-not [IO.File]::Exists($path)) { throw 'Claude CLI not found. Set ORCHESTRA_CLAUDE or install Claude Code.' }
    $LASTEXITCODE = 0
    $version = (& $path --version 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "Cannot run Claude CLI: $path" }
    return [pscustomobject]@{ Path = $path; VersionText = [string]$version; Family = 'claude' }
}

function Get-ClaudeResult($Events) {
    $data = @{ session = $null; model = $null; text = ''; failed = $false
        context = @{ tokens = 0; window = 200000; source = 'approx' } }
    $modelUsage = $null
    foreach ($event in $Events) {
        if ($event.parent_tool_use_id) { continue }
        if ($event.type -eq 'system' -and $event.subtype -eq 'init') {
            if ($event.session_id) { $data.session = [string]$event.session_id }
            if ($event.model) { $data.model = [string]$event.model }
        } elseif ($event.type -eq 'assistant' -and $event.message) {
            if ($event.message.model) { $data.model = [string]$event.message.model }
            if ($event.message.usage) {
                $usage = $event.message.usage
                $data.context.tokens = [long]$usage.input_tokens +
                    [long]$usage.cache_creation_input_tokens + [long]$usage.cache_read_input_tokens
            }
            $data.text = (@($event.message.content | Where-Object { $_.type -eq 'text' } |
                ForEach-Object { $_.text }) -join "`n")
        } elseif ($event.type -eq 'result') {
            if ($event.session_id) { $data.session = [string]$event.session_id }
            if ($null -ne $event.result) { $data.text = [string]$event.result }
            $data.failed = [bool]$event.is_error
            if ($event.modelUsage) { $modelUsage = $event.modelUsage }
        }
    }
    if ($modelUsage) {
        $models = @($modelUsage.PSObject.Properties)
        $selected = @($models | Where-Object { $_.Name -eq $data.model })
        if ($selected.Count -eq 0 -and $models.Count -eq 1) { $selected = @($models[0]) }
        if ($selected.Count -gt 0) {
            $data.model = $selected[0].Name
            if ([long]$selected[0].Value.contextWindow -gt 0) {
                $data.context.window = [long]$selected[0].Value.contextWindow
                $data.context.source = 'stream-json'
            }
        }
    }
    return $data
}

function Get-ClaudeProfileArguments([string]$RunProfile, [string]$Base) {
    # Attribution is disabled for every profile without changing user settings.
    $settings = @{ attribution = @{ commit = ''; pr = ''; sessionUrl = $false } }
    $settingsPath = Join-Path $state "runs/$Base.settings.json"
    if ($RunProfile -eq 'full') {
        Write-Utf8 $settingsPath (ConvertTo-Json -InputObject $settings -Depth 8)
        return @('--settings', $settingsPath)
    }
    # Keep OAuth and every built-in tool. Bare/restricted remove capabilities;
    # safe mode also suppresses explicit MCP servers, breaking frontend.
    # Explicitly disable built-in plugins as well as installed plugins.
    $settings.disableAllHooks = $true
    $settings.enabledPlugins = @{
        'cc-plugin-agents-md@builtin' = $false; 'cc-plugin-telemetry@builtin' = $false
    }
    $installedPath = Join-Path $env:USERPROFILE '.claude/plugins/installed_plugins.json'
    if ([IO.File]::Exists($installedPath)) {
        $installed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($installedPath, $utf8))
        foreach ($plugin in $installed.plugins.PSObject.Properties) { $settings.enabledPlugins[$plugin.Name] = $false }
    }
    $mcp = @{ mcpServers = @{} }
    if ($RunProfile -eq 'frontend') {
        $mcp.mcpServers.playwright = @{ command = 'npx'; args = @('--yes', '@playwright/mcp@latest',
            '--headless', '--isolated', '--allow-unrestricted-file-access') }
    }
    $mcpPath = Join-Path $state "runs/$Base.mcp.json"
    Write-Utf8 $settingsPath (ConvertTo-Json -InputObject $settings -Depth 8)
    Write-Utf8 $mcpPath (ConvertTo-Json -InputObject $mcp -Depth 8)
    # Restore global instructions explicitly, expanding the user's AGENTS.md
    # import rather than relying on disabled plugin discovery.
    $globalRoot = Join-Path $env:USERPROFILE '.claude'
    $rules = ''
    $agentsPath = Join-Path $globalRoot 'AGENTS.md'
    if ([IO.File]::Exists($agentsPath)) { $rules = [IO.File]::ReadAllText($agentsPath, $utf8) }
    $claudePath = Join-Path $globalRoot 'CLAUDE.md'
    if ([IO.File]::Exists($claudePath)) {
        $claudeRules = [IO.File]::ReadAllText($claudePath, $utf8)
        $claudeRules = [regex]::Replace($claudeRules, '(?m)^\s*@AGENTS\.md\s*$', '')
        $rules = $claudeRules + "`n" + $rules
    }
    $result = @('--setting-sources', '', '--settings', $settingsPath,
        '--strict-mcp-config', '--mcp-config', $mcpPath)
    if (-not [string]::IsNullOrWhiteSpace($rules)) { $result += @('--append-system-prompt', $rules) }
    return $result
}

function Test-Handoff([string]$Engine, [long]$Tokens, [long]$Window, [int]$Percent) {
    if ($Engine -eq 'claude') {
        return ($Tokens -ge 200000 -or ($Window -gt 0 -and $Tokens -ge 0.7 * $Window))
    }
    return ($Percent -ge 70)
}

function Normalize-Model([string]$Value) {
    switch ($Value) {
        'sol' { return 'gpt-6.1-sol' }
        'sol6' { return 'gpt-6-sol' }
        'astra' { return 'gpt-6-astra' }
        'luna' { return 'gpt-6-luna' }
        'luna56' { return 'gpt-5.6-luna' }
        'sonnet' { return 'claude-sonnet-5-5' }
        'opus' { return 'claude-opus-5-5' }
        'fable' { return 'claude-fable-5-1' }
        'haiku' { return 'claude-haiku-4-5-20251001' }
    }
    return $Value
}

function Get-ModelPrefix([string]$Value) {
    switch ($Value) {
        'gpt-6.1-sol' { return 'sol' }
        'gpt-6-sol' { return 'sol6' }
        'gpt-6-astra' { return 'astra' }
        'gpt-6-luna' { return 'luna' }
        'gpt-5.6-luna' { return 'luna56' }
        'claude-sonnet-5-5' { return 'sonnet' }
        'claude-opus-5-5' { return 'opus' }
        'claude-fable-5-1' { return 'fable' }
        'claude-haiku-4-5-20251001' { return 'haiku' }
    }
    $prefix = ($Value -replace '[^A-Za-z0-9_-]', '-').Trim('-', '_')
    if (-not $prefix) { $prefix = 'worker' }
    return $prefix
}

function Invoke-WorkerRun([string]$RunTask, [string]$RunModel, [string]$RunEffort,
                          [string]$RunName, [bool]$RunResume, [bool]$ModelSpecified,
                          [bool]$EffortSpecified, [string]$NamePrefix) {
    $parameters = @($RunTask, $RunModel, $RunEffort, $RunName, $RunResume, $ModelSpecified, $EffortSpecified, $NamePrefix)
    $desktop = [pscustomobject]@{ Needed = [bool]$ComputerUse; Model = $RunModel }
    if ($RunResume) {
        Lock-Workers {
            $saved = @(Read-Workers | Where-Object { $_.name -eq $RunName })
            if ($saved.Count -gt 0) {
                $desktop.Needed = $desktop.Needed -or [bool]$saved[0].computer_use
                if (-not $ModelSpecified) { $desktop.Model = $saved[0].model }
            }
        }
    }
    if (-not $desktop.Needed) { return Invoke-WorkerRunCore @parameters }
    if ((Get-Engine $desktop.Model) -eq 'claude') {
        throw '-ComputerUse applies only to Codex workers; Claude engine does not support it.'
    }
    Assert-NativeComputerUseReady
    # Wait without holding a project lock; unrelated workers remain free to run.
    return Lock-DesktopWorker {
        Assert-NativeComputerUseReady
        Invoke-WorkerRunCore @parameters
    }
}

function Invoke-WorkerRunCore([string]$RunTask, [string]$RunModel, [string]$RunEffort,
                              [string]$RunName, [bool]$RunResume, [bool]$ModelSpecified,
                              [bool]$EffortSpecified, [string]$NamePrefix) {
        # Batch workers share these inputs. Serialize BOM preparation with the
        # project mutex so no worker can read another launcher's partial write.
        Lock-Workers {
            foreach ($inputPath in @((Join-Path $state "tasks/$RunTask.md"),
                (Join-Path $state 'context.md'), (Join-Path $state 'WORKER.md'))) {
                Ensure-Utf8Bom $inputPath
            }
        }
        $run = [pscustomobject]@{
            Task = $RunTask; Model = $RunModel; Effort = $RunEffort; Name = $RunName
            SessionId = $null; Cli = $null; Fallback = $null; Engine = $null; ResolvedEffort = $null
            Profile = $Profile
            ComputerUse = $false
        }
        $started = [DateTime]::UtcNow.ToString('o')
        Lock-Workers {
            $workers = @(Read-Workers)
            if (-not $run.Name) {
                $prefix = $NamePrefix
                if (-not $prefix) {
                    $prefix = Get-ModelPrefix $run.Model
                }
                $number = 1
                do { $candidate = '{0}-{1:d2}' -f $prefix, $number; $number++ }
                while (@($workers | Where-Object { $_.name -eq $candidate }).Count -gt 0)
                $run.Name = $candidate
            }
            $existing = @($workers | Where-Object { $_.name -eq $run.Name })
            if ($RunResume -and ($existing.Count -eq 0 -or -not $existing[0].session_id)) {
                throw "No saved session for worker $($run.Name)."
            }
            if ($existing.Count -gt 0 -and $existing[0].status -eq 'running') {
                # A launcher killed mid-run (e.g. its Claude session closed) leaves a stale 'running'.
                $ownerPid = $existing[0].launcher_pid
                if ($ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
                    throw "Worker $($run.Name) is already running."
                }
                $existing[0].status = 'failed'
            }
            if ($existing.Count -gt 0 -and -not $RunResume) {
                throw "Worker $($run.Name) already exists; use -Resume."
            }
            $previous = $null
            $needsComputer = [bool]$ComputerUse
            if ($RunResume) {
                $previous = $existing[0]
                if (-not $ModelSpecified) { $run.Model = $previous.model }
                if (-not $ModelSpecified -and $previous.model_fallback -and $previous.requested_model) {
                    $run.Model = $previous.requested_model
                }
                if (-not $EffortSpecified) { $run.Effort = $previous.effort }
                $needsComputer = $needsComputer -or [bool]$previous.computer_use
            }
            $run.ComputerUse = $needsComputer
            $requestedModel = $run.Model
            $run.Engine = Get-Engine $requestedModel
            if ($RunResume) {
                $previousEngine = 'codex'
                if ($previous.engine) { $previousEngine = $previous.engine }
                if ($previousEngine -ne $run.Engine) { throw 'Resume cannot change worker engine.' }
            }
            if ($RunResume) { Assert-ResumeAllowed $previous ([bool]$Force) }
            $run.ResolvedEffort = $run.Effort
            $cliRule = $null
            if ($run.Engine -eq 'claude') {
                if ($needsComputer) { throw '-ComputerUse applies only to Codex workers; Claude engine does not support it.' }
                if ($RunResume -and -not $script:profileSpecified) {
                    $run.Profile = 'full'
                    if ($previous.profile) { $run.Profile = $previous.profile }
                }
                $run.Cli = Resolve-Claude $previous
                # Claude Code 2.1.285 accepts low, medium, high, xhigh, max.
                if ($run.Effort -eq 'ultra') { $run.ResolvedEffort = 'max' }
            } else {
                $selection = Resolve-Codex $requestedModel $needsComputer $previous
                $run.Cli = $selection.Info
                $run.Model = $selection.Model
                $run.Fallback = $selection.Fallback
                $cliRule = $selection.Rule
            }
            if ($RunResume) {
                $worker = $existing[0]
                if ($worker.current_task -and $worker.current_task -ne $run.Task -and
                    @(Read-TaskRuns | Where-Object { $_.task -eq $worker.current_task }).Count -eq 0) {
                    Save-TaskRun ([pscustomobject]@{
                        task = $worker.current_task; worker = $worker.name; model = $worker.model; effort = $worker.effort
                        status = $worker.status; started = $worker.started; finished = $worker.finished; context_pct = $worker.context_pct
                    })
                }
                $worker.model = $run.Model
                $worker.effort = $run.Effort
                $worker.status = 'running'
                $worker.current_task = $run.Task
                $worker.tasks = @($worker.tasks) + @($run.Task)
                $worker.started = $started
                $worker.finished = $null
                $worker.exit_code = $null
                $worker | Add-Member -NotePropertyName launcher_pid -NotePropertyValue $PID -Force
                $run.SessionId = $worker.session_id
            } else {
                $worker = [pscustomobject]@{
                    name = $run.Name; model = $run.Model; effort = $run.Effort; session_id = $null
                    status = 'running'; current_task = $run.Task; tasks = @($run.Task)
                    context_tokens = 0; context_window = 0; context_pct = 0
                    context_source = 'approx'; exit_code = $null
                    started = $started; finished = $null; report = $null; launcher_pid = $PID
                }
                $workers += $worker
            }
            $worker | Add-Member -NotePropertyName cli_path -NotePropertyValue $run.Cli.Path -Force
            $worker | Add-Member -NotePropertyName cli_version -NotePropertyValue $run.Cli.VersionText -Force
            $worker | Add-Member -NotePropertyName cli_family -NotePropertyValue $run.Cli.Family -Force
            $worker | Add-Member -NotePropertyName cli_rule -NotePropertyValue $cliRule -Force
            $worker | Add-Member -NotePropertyName engine -NotePropertyValue $run.Engine -Force
            $savedProfile = $null
            if ($run.Engine -eq 'claude') { $savedProfile = $run.Profile }
            $worker | Add-Member -NotePropertyName profile -NotePropertyValue $savedProfile -Force
            $worker | Add-Member -NotePropertyName resolved_effort -NotePropertyValue $run.ResolvedEffort -Force
            $resolvedModel = $null
            if ($run.Engine -eq 'codex') { $resolvedModel = $run.Model }
            $worker | Add-Member -NotePropertyName resolved_model -NotePropertyValue $resolvedModel -Force
            $worker | Add-Member -NotePropertyName computer_use -NotePropertyValue $needsComputer -Force
            $worker | Add-Member -NotePropertyName requested_model -NotePropertyValue $requestedModel -Force
            $worker | Add-Member -NotePropertyName model_fallback -NotePropertyValue $run.Fallback -Force
            Save-Workers $workers
            Save-TaskRun ([pscustomobject]@{
                task = $run.Task; worker = $run.Name; model = $run.Model; effort = $run.Effort
                status = 'running'; started = $started; finished = $null; context_pct = 0
            })
        }
        $base = "$($run.Task).$($run.Name)"
        $runs = Join-Path $state 'runs'
        $jsonl = Join-Path $runs "$base.jsonl"
        $stderr = Join-Path $runs "$base.err.log"
        $last = Join-Path $runs "$base.last.md"
        $reportRelative = ".orchestra/reports/$($run.Task).md"
        $report = Join-Path (Join-Path $state 'reports') "$($run.Task).md"
        # A report left by an earlier attempt must not count as this run's result.
        $reportBefore = $null
        if ([IO.File]::Exists($report)) { $reportBefore = [IO.File]::GetLastWriteTimeUtc($report) }
        $setting = 'model_reasoning_effort="' + $run.Effort + '"'
        # Usage guards: standard tier (Fast tier bills about 2.5x), capped tool output, earlier compaction.
        $usageGuards = @('-c', 'service_tier="default"', '-c', 'tool_output_token_limit=8000', '-c', 'model_auto_compact_token_limit=200000')
        if ($RunResume) {
            $prompt = "You are still GPT worker $($run.Name). New brief: .orchestra/tasks/$($run.Task).md. Re-read .orchestra/context.md if it changed. Same rules. Report to .orchestra/reports/$($run.Task).md."
            $arguments = @('exec', 'resume', $run.SessionId, '--json', '-m', $run.Model, '-c', $setting) + $usageGuards +
                @('--dangerously-bypass-approvals-and-sandbox', '--skip-git-repo-check', '-o', $last, '-')
        } else {
            $prompt = "You are GPT worker $($run.Name) (model $($run.Model), effort $($run.Effort)). Before anything else read .orchestra/WORKER.md (your rules), .orchestra/context.md (project context), then your brief .orchestra/tasks/$($run.Task).md. Do the task. When finished, write your report to .orchestra/reports/$($run.Task).md in the format WORKER.md specifies. Your final message: one line status, then the report path."
            $arguments = @('exec', '--json', '-m', $run.Model, '-c', $setting) + $usageGuards + @('-s', 'danger-full-access',
                '--skip-git-repo-check', '-C', $Project, '-o', $last, '-')
        }
        $prompt += "`nKeep tool output small: never print whole large files or logs. Read line ranges, filter with a search, or pipe through a first/last-N filter; send long command output to a file and read only the part you need."
        if ($run.Engine -eq 'codex' -and $env:OS -eq 'Windows_NT') {
            $prompt += "`nShell is Windows PowerShell 5.1: no && or ||. Write scripts longer than 3 lines to a .py/.ps1 file and run the file; no inline here-strings. rg/findstr exit 1 means no match, not an error. Do not use wsl."
        }
        if ($run.ComputerUse) {
            $prompt += "`nNative desktop control: use mcp__node_repl__js through functions.exec as tools.mcp__node_repl__js (discover that exact name in ALL_TOOLS if deferred). Import with const {sky} = await import('@oai/sky'); call sky.list_windows() first as native preflight. Never use browser-only cua_repl for desktop apps. If the tool, import, or native preflight fails, stop and write Status: BLOCKED with BLOCKED: native CUA unavailable in the report."
        }
        if ($run.Engine -eq 'claude') {
            $arguments = @('-p', '--model', $run.Model, '--effort', $run.ResolvedEffort,
                '--output-format', 'stream-json', '--verbose', '--dangerously-skip-permissions')
            $arguments += @(Get-ClaudeProfileArguments $run.Profile $base)
            if ($RunResume) { $arguments += @('--resume', $run.SessionId) }
        }
        $exitCode = -1
        $script:workerTimedOut = $false
        try { $exitCode = Invoke-Codex $run.Cli.Path $arguments $prompt $jsonl $stderr }
        catch { Write-Utf8 $stderr ($_ | Out-String) }
        $events = @(Get-RunEvents $jsonl)
        if ($run.Engine -eq 'claude') {
            $claudeResult = Get-ClaudeResult $events
            if ($claudeResult.session) { $run.SessionId = $claudeResult.session }
            $resolvedModel = $claudeResult.model
            $context = $claudeResult.context
            Write-Utf8 $last $claudeResult.text
            if ($claudeResult.failed -and $exitCode -eq 0) { $exitCode = 1 }
        } else {
            foreach ($event in $events) {
                if ($event.type -eq 'thread.started' -and $event.thread_id) {
                    $run.SessionId = [string]$event.thread_id
                    break
                }
            }
            $resolvedModel = $run.Model
            try { $context = Get-Context $events $run.SessionId }
            catch {
                # A killed worker may leave a temporarily locked/truncated rollout.
                # Context telemetry must not prevent persisting its terminal status.
                $context = @{tokens = 0; window = 0; source = 'approx'}
            }
        }
        $pct = 0
        if ($context.window -gt 0) { $pct = [int][Math]::Round(100.0 * $context.tokens / $context.window) }
        $reportFresh = [IO.File]::Exists($report) -and
            ($null -eq $reportBefore -or [IO.File]::GetLastWriteTimeUtc($report) -gt $reportBefore)
        $status = 'failed'
        if ($exitCode -eq 0 -and $reportFresh) { $status = 'done' }
        if ($script:workerTimedOut) { $status = 'timeout' }
        $finished = [DateTime]::UtcNow.ToString('o')
        Lock-Workers {
            $workers = @(Read-Workers)
            $worker = @($workers | Where-Object { $_.name -eq $run.Name })[0]
            $worker.session_id = $run.SessionId
            $worker.resolved_model = $resolvedModel
            $worker.status = $status
            $worker.context_tokens = [long]$context.tokens
            $worker.context_window = [long]$context.window
            $worker.context_pct = $pct
            $worker.context_source = $context.source
            $worker.exit_code = $exitCode
            $worker.finished = $finished
            if ([IO.File]::Exists($report)) { $worker.report = $reportRelative } else { $worker.report = $null }
            Save-Workers $workers
            Save-TaskRun ([pscustomobject]@{
                task = $run.Task; worker = $run.Name; model = $run.Model; effort = $run.Effort
                status = $status; started = $started; finished = $finished; context_pct = $pct
            })
        }
        $reportText = 'MISSING'
        if ([IO.File]::Exists($report)) { $reportText = $reportRelative }
        $tokensK = [Math]::Round($context.tokens / 1000.0)
        $windowK = [Math]::Round($context.window / 1000.0)
        $line = "[orchestra] $($run.Name) $($run.Task) $status exit=$exitCode ctx=${tokensK}k/${windowK}k ($pct%) report=$reportText"
        if (Test-Handoff $run.Engine $context.tokens $context.window $pct) { $line += ' HANDOFF-RECOMMENDED' }
        if ($run.Fallback) { $line += " model-fallback=$($run.Fallback)" }
        if ($run.Engine -eq 'codex' -and -not $script:workerTimedOut) {
            $crashReason = Get-CrashReason $exitCode $stderr
            if ($crashReason) { $line += " crash=$crashReason" }
        }
        return [pscustomobject]@{ Line = $line; Status = $status; Report = $report; ReportFresh = $reportFresh }
}

$script:profileSpecified = $PSBoundParameters.ContainsKey('Profile')

function Read-BatchPlan {
    if (-not $Plan) { throw 'batch requires -Plan <path to plan.json>.' }
    $planPath = $Plan
    if (-not [IO.Path]::IsPathRooted($planPath)) { $planPath = Join-Path $Project $planPath }
    $json = [IO.File]::ReadAllText($planPath, $utf8)
    if ($json.TrimStart() -notmatch '^\[') { throw 'Plan must be a JSON array.' }
    $parsed = ConvertFrom-Json -InputObject $json
    $entries = @($parsed)
    $known = @{}
    $allowed = @('task','model','effort','name','resume','review','reviewModel','reviewEffort','profile','computerUse','dependsOn','force','timeoutMin','reviewTimeoutMin')
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) { throw 'Each plan entry must be an object.' }
        foreach ($property in $entry.PSObject.Properties) {
            if ($property.Name -notin $allowed) { throw "Unknown plan field: $($property.Name)" }
        }
        if ($entry.task -isnot [string] -or -not $entry.task -or
            $entry.task -ne [IO.Path]::GetFileName($entry.task) -or $entry.task -match '[\\/]') {
            throw 'Each plan task must be a file name without a path.'
        }
        if ($known.ContainsKey($entry.task)) { throw "Duplicate task: $($entry.task)" }
        $known[$entry.task] = $entry
        foreach ($field in @('model','effort')) {
            if ($entry.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.$field)) {
                throw "Task $($entry.task) requires $field."
            }
        }
        foreach ($field in @('effort','reviewEffort')) {
            if ($entry.PSObject.Properties[$field] -and $entry.$field -notin @('low','medium','high','xhigh','max','ultra')) {
                throw "Invalid $field for task $($entry.task)."
            }
        }
        if ($entry.PSObject.Properties['profile'] -and $entry.profile -notin @('lean','frontend','full')) {
            throw "Invalid profile for task $($entry.task)."
        }
        foreach ($field in @('resume','review','computerUse','force')) {
            if ($entry.PSObject.Properties[$field] -and $entry.$field -isnot [bool]) {
                throw "Task $($entry.task): $field must be boolean."
            }
        }
        foreach ($field in @('timeoutMin','reviewTimeoutMin')) {
            if ($entry.PSObject.Properties[$field] -and
                ($entry.$field -isnot [int] -and $entry.$field -isnot [long] -or
                 $entry.$field -lt 0 -or $entry.$field -gt 2147483647)) {
                throw "Task $($entry.task): $field must be a nonnegative integer."
            }
        }
        if ($entry.PSObject.Properties['name'] -and ($entry.name -isnot [string] -or
            $entry.name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$')) { throw "Invalid name for task $($entry.task)." }
        if ($entry.resume -and -not $entry.name) { throw "Task $($entry.task): resume requires name." }
        if ($entry.PSObject.Properties['reviewModel'] -and ($entry.reviewModel -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entry.reviewModel))) { throw "Invalid reviewModel for task $($entry.task)." }
        $brief = Join-Path $state "tasks/$($entry.task).md"
        if (-not [IO.File]::Exists($brief)) { throw "Task brief missing: $brief" }
        if ($entry.PSObject.Properties['dependsOn'] -and $entry.dependsOn -isnot [array]) {
            throw "Task $($entry.task): dependsOn must be an array."
        }
        foreach ($dep in @($entry.dependsOn)) {
            if ($null -ne $dep -and ($dep -isnot [string] -or -not $dep)) {
                throw "Invalid dependency for task $($entry.task)."
            }
            if ($null -eq $dep -and $entry.PSObject.Properties['dependsOn']) {
                throw "Invalid dependency for task $($entry.task)."
            }
        }
    }
    foreach ($entry in $entries) {
        foreach ($dep in @($entry.dependsOn)) {
            if ($dep -and -not $known.ContainsKey($dep)) { throw "Unknown dependency $dep for task $($entry.task)." }
        }
        if ($entry.review -and $known.ContainsKey("$($entry.task)-review")) {
            throw "Review brief collides with plan task: $($entry.task)-review"
        }
    }
    # Kahn's algorithm validates every component, including cycles with no roots.
    $visited = @{}
    do {
        $changed = $false
        foreach ($entry in $entries) {
            if ($visited.ContainsKey($entry.task)) { continue }
            $waiting = @($entry.dependsOn | Where-Object { $null -ne $_ -and -not $visited.ContainsKey($_) })
            if ($waiting.Count -eq 0) { $visited[$entry.task] = $true; $changed = $true }
        }
    } while ($changed)
    if ($visited.Count -ne $entries.Count) { throw 'Dependency cycle in plan.' }
    return $entries
}

function Invoke-Batch {
    $entries = @(Read-BatchPlan)
    Ensure-State $false
    $statuses = @{}; $outputs = @{}; $active = @{}
    $launcher = $PSCommandPath
    try {
        while ($statuses.Count -lt $entries.Count) {
            foreach ($entry in $entries) {
                $id = $entry.task
                if ($statuses.ContainsKey($id) -or $active.ContainsKey($id)) { continue }
                $failedDep = @($entry.dependsOn | Where-Object {
                    $null -ne $_ -and $statuses.ContainsKey($_) -and $statuses[$_] -in @('failed','skipped')
                } | Select-Object -First 1)
                if ($failedDep.Count -gt 0) {
                    $statuses[$id] = 'skipped'
                    $outputs[$id] = @("[orchestra] - $id skipped dep=$($failedDep[0])")
                    Lock-Workers {
                        Save-TaskRun ([pscustomobject]@{
                            task = $id; worker = '-'; model = (Normalize-Model $entry.model); effort = $entry.effort
                            status = 'skipped'; started = $null; finished = [DateTime]::UtcNow.ToString('o'); context_pct = 0
                        })
                    }
                    continue
                }
                $waiting = @($entry.dependsOn | Where-Object { $null -ne $_ -and -not $statuses.ContainsKey($_) })
                if ($waiting.Count -gt 0) { continue }
                $parameters = @{ Project = $Project; Task = $id; Model = $entry.model; Effort = $entry.effort; Cli = $Cli; TimeoutMin = $TimeoutMin; ReviewTimeoutMin = $ReviewTimeoutMin; NoDigest = [bool]$NoDigest }
                foreach ($field in @('name','resume','review','reviewModel','reviewEffort','profile','computerUse','force','timeoutMin','reviewTimeoutMin')) {
                    if ($entry.PSObject.Properties[$field]) { $parameters[$field] = $entry.$field }
                }
                if (-not $parameters.ContainsKey('profile') -and $script:profileSpecified) { $parameters.profile = $Profile }
                $active[$id] = Start-Job -ScriptBlock {
                    param($Path, $Parameters)
                    $ErrorActionPreference = 'Stop'
                    try { & $Path run @Parameters }
                    catch {
                        [Console]::Error.WriteLine($_.Exception.Message)
                        $label = '-'
                        if ($Parameters.name) { $label = $Parameters.name }
                        "[orchestra] $label $($Parameters.Task) failed exit=-1 ctx=0k/0k (0%) report=MISSING"
                    }
                } -ArgumentList $launcher, $parameters
            }
            if ($active.Count -eq 0) { continue }
            # Block on any completion, then collect all finished jobs. No status polling.
            $null = Wait-Job -Job @($active.Values) -Any
            foreach ($id in @($active.Keys)) {
                $job = $active[$id]
                if ($job.State -notin @('Completed','Failed','Stopped')) { continue }
                $lines = @(Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
                $resultLines = @($lines | Where-Object { $_ -match '^\[orchestra\] ' })
                $statuses[$id] = 'failed'
                if ($resultLines.Count -gt 0 -and $resultLines[0] -match ' done exit=0 ' -and
                    @($resultLines | Where-Object { $_ -match ' (failed|timeout) exit=' }).Count -eq 0) { $statuses[$id] = 'done' }
                if ($resultLines.Count -eq 0) {
                    $resultLines = @("[orchestra] - $id failed exit=-1 ctx=0k/0k (0%) report=MISSING")
                    $lines = $resultLines
                }
                if ($lines.Count -gt 0 -and $resultLines.Count -gt 0) {
                    $outputs[$id] = @($lines | Where-Object { $_ -match '^\[orchestra\] |^  \| ' })
                } else { $outputs[$id] = $resultLines }
                # Validation/launch failures never registered a worker; retain a board row.
                Lock-Workers {
                    if (@(Read-TaskRuns | Where-Object { $_.task -eq $id }).Count -eq 0) {
                        Save-TaskRun ([pscustomobject]@{
                            task = $id; worker = '-'; model = (Normalize-Model (@($entries | Where-Object { $_.task -eq $id })[0].model))
                            effort = (@($entries | Where-Object { $_.task -eq $id })[0].effort)
                            status = 'failed'; started = $null; finished = [DateTime]::UtcNow.ToString('o'); context_pct = 0
                        })
                    }
                }
                Remove-Job -Job $job
                $active.Remove($id)
            }
        }
    } finally {
        foreach ($job in @($active.Values)) { Stop-Job -Job $job; Remove-Job -Job $job }
    }
    foreach ($entry in $entries) { foreach ($line in $outputs[$entry.task]) { Write-Output $line } }
    $done = @($statuses.Values | Where-Object { $_ -eq 'done' }).Count
    $failed = @($statuses.Values | Where-Object { $_ -eq 'failed' }).Count
    $skipped = @($statuses.Values | Where-Object { $_ -eq 'skipped' }).Count
    Update-Board
    Write-Output "[orchestra] batch done=$done failed=$failed skipped=$skipped"
}

switch ($Command) {
    'batch' { try { Invoke-Batch } finally { if ([IO.Directory]::Exists($state)) { Update-Board } }; break }
    'board' { Ensure-State $false; Update-Board; break }
    'init' {
        Ensure-State $true
        break
    }
    'status' {
        if (-not [IO.File]::Exists($workersFile)) { break }
        Lock-Workers { $script:statusWorkers = Read-Workers }
        foreach ($worker in $script:statusWorkers) {
            Write-Output ('{0} {1} {2} {3} {4}% {5}' -f $worker.name, $worker.model,
                $worker.effort, $worker.status, $worker.context_pct, $worker.current_task)
        }
        break
    }
    'run' {
        if (-not $Task) { throw 'run requires -Task <id>.' }
        if ($Task -ne [IO.Path]::GetFileName($Task) -or $Task -match '[\\/]') {
            throw 'Task must be a file name without a path.'
        }
        if ($Name -and $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
            throw 'Name may contain only letters, digits, underscores, and hyphens.'
        }
        $brief = Join-Path (Join-Path $state 'tasks') "$Task.md"
        if (-not [IO.File]::Exists($brief)) { throw "Task brief missing: $brief" }
        if ($Resume -and -not $Name) { throw '-Resume requires -Name of an existing worker.' }
        Ensure-State $false
        try {
        $workerRun = Invoke-WorkerRun $Task (Normalize-Model $Model) $Effort $Name ([bool]$Resume) `
            $PSBoundParameters.ContainsKey('Model') $PSBoundParameters.ContainsKey('Effort') $null
        Write-Output $workerRun.Line
        if ($workerRun.ReportFresh) { Write-ReportDigest $workerRun.Report $false }
        if ($Review -and $workerRun.Status -eq 'done') {
            $reviewTask = "$Task-review"
            $template = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'templates') 'review.md'
            $reviewBrief = Join-Path (Join-Path $state 'tasks') "$reviewTask.md"
            Write-Utf8 $reviewBrief ([IO.File]::ReadAllText($template, $utf8).Replace('{{TASK}}', $Task))
            $TimeoutMin = $ReviewTimeoutMin
            $reviewRun = Invoke-WorkerRun $reviewTask (Normalize-Model $ReviewModel) $ReviewEffort $null `
                $false $true $true 'rev'
            $verdict = 'UNKNOWN'
            if ($reviewRun.ReportFresh) {
                $reviewText = [IO.File]::ReadAllText($reviewRun.Report, $utf8)
                if ($reviewText -match '(?m)^Verdict:\s*(PASS|NEEDS-WORK|FAIL)\s*$') { $verdict = $Matches[1] }
            }
            $reviewLine = $reviewRun.Line
            $fallbackSuffix = ''
            if ($reviewLine -match ' model-fallback=\S+$') {
                $fallbackSuffix = $Matches[0]
                $reviewLine = $reviewLine.Substring(0, $reviewLine.Length - $fallbackSuffix.Length)
            }
            if ($reviewLine.EndsWith(' HANDOFF-RECOMMENDED')) {
                $reviewLine = $reviewLine.Substring(0, $reviewLine.Length - ' HANDOFF-RECOMMENDED'.Length) +
                    " verdict=$verdict HANDOFF-RECOMMENDED"
            } else { $reviewLine += " verdict=$verdict" }
            $reviewLine += $fallbackSuffix
            Write-Output $reviewLine
            if ($reviewRun.ReportFresh) { Write-ReportDigest $reviewRun.Report $true }
        }
        } finally { Update-Board }
        break
    }
}
