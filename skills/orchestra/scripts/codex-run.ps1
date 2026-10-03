param(
    [string]$Project = (Get-Location).Path, [string]$Prompt, [string]$PromptFile,
    [ValidateSet('medium', 'high')][string]$Effort = 'medium', [string]$Model = 'gpt-6.1-sol',
    [ValidateRange(0, [double]::MaxValue)][double]$TimeoutMin = 0,
    [string]$Resume, [switch]$ComputerUse
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
function Quote-Argument([string]$Value) {
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $result = '"'; $slashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') { $slashes++; continue }
        if ($char -eq '"') { $result += ('\' * ($slashes * 2 + 1)) + '"' }
        else { $result += ('\' * $slashes) + $char }
        $slashes = 0
    }
    return $result + ('\' * ($slashes * 2)) + '"'
}
function Test-CodexDesktopRunning {
    foreach ($process in @(Get-Process -Name ChatGPT, Codex -ErrorAction SilentlyContinue)) {
        try { $path = $process.Path } catch { continue }
        if ($path -match '(?i)[\\/]WindowsApps[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/](ChatGPT|Codex)\.exe$' -or
            $path -match '(?i)[\\/]OpenAI[\\/]Codex[\\/](?:app[\\/])?(ChatGPT|Codex)\.exe$') { return $true }
    }
    return $false
}
function Initialize-WorkerJob {
    if ('CodexRunJob' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
public sealed class CodexRunJob : IDisposable {
    public Process Process;
    public AnonymousPipeServerStream Input, Output, Error;
    private IntPtr job;
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct Startup {
        public int cb; public string reserved, desktop, title;
        public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
        public ushort show, reservedSize; public IntPtr reservedData, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimit {
        public long processTime, jobTime; public uint flags;
        public UIntPtr minWorkingSet, maxWorkingSet; public uint activeProcesses;
        public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit {
        public BasicLimit basic; public IoCounters io; public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool CreateProcess(string app,
        StringBuilder command, IntPtr processAttrs, IntPtr threadAttrs, bool inherit, uint flags, IntPtr environment,
        string cwd, ref Startup startup, out ProcessInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimit limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    private static void Check(bool okay) { if (!okay) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static CodexRunJob Start(string exe, string commandLine, string cwd) {
        var child = new CodexRunJob(); var info = new ProcessInfo();
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
            // Assign while suspended so even immediate descendants inherit the job.
            Check(CreateProcess(exe, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true,
                0x08000004, IntPtr.Zero, cwd, ref startup, out info));
            Check(AssignProcessToJobObject(child.job, info.process));
            child.Process = Process.GetProcessById((int)info.pid); child.Process.Handle.ToInt64();
            child.Input.DisposeLocalCopyOfClientHandle(); child.Output.DisposeLocalCopyOfClientHandle(); child.Error.DisposeLocalCopyOfClientHandle();
            if (ResumeThread(info.thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            return child;
        } catch { if (info.process != IntPtr.Zero) TerminateProcess(info.process, 1); child.Dispose(); throw; }
        finally { if (info.thread != IntPtr.Zero) CloseHandle(info.thread); if (info.process != IntPtr.Zero) CloseHandle(info.process); }
    }
    public void Kill() { Check(TerminateJobObject(job, 124)); }
    public void Dispose() {
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        if (Input != null) Input.Dispose(); if (Output != null) Output.Dispose(); if (Error != null) Error.Dispose();
        if (Process != null) Process.Dispose();
    }
}
'@
}
$id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
$record = [ordered]@{ id = $id; status = 'failed'; thread_id = $Resume; model = $Model; effort = $Effort;
    seconds = 0; input_tokens = 0L; cached_input_tokens = 0L; output_tokens = 0L; exit_code = 1;
    started = [DateTime]::UtcNow.ToString('o'); finished = $null }
$child = $null; $outFile = $null; $errFile = $null; $mutex = $null; $held = $false; $timer = $null; $base = $null
try {
    $Project = (Resolve-Path -LiteralPath $Project).ProviderPath
    $folder = Join-Path $Project '.orchestra'; [void][IO.Directory]::CreateDirectory((Join-Path $folder 'runs'))
    $ignore = Join-Path $folder '.gitignore'; if (-not [IO.File]::Exists($ignore)) { [IO.File]::WriteAllText($ignore, "*`n", $utf8) }
    $base = Join-Path $folder "runs\$id"
    [IO.File]::WriteAllText("$base.last.md", '', $utf8)
    [IO.File]::WriteAllText("$base.jsonl", '', $utf8); [IO.File]::WriteAllText("$base.err.log", '', $utf8)
    if ($PSBoundParameters.ContainsKey('Prompt') -and $PSBoundParameters.ContainsKey('PromptFile')) { throw 'Use only one of -Prompt and -PromptFile.' }
    if ($PromptFile) { $Prompt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).ProviderPath, $utf8) }
    elseif (-not $PSBoundParameters.ContainsKey('Prompt')) { [Console]::InputEncoding = $utf8; $Prompt = [Console]::In.ReadToEnd() }
    $Prompt += "`nShell is Windows PowerShell 5.1: no ``&&`` or ``||``. Put scripts longer than 3 lines in a file and run the file. ``rg``/``findstr`` exit 1 means no match.`nKeep tool output small: read line ranges or filter; never print whole large files or logs.`nTouch only what the task needs. Do not run git commands that change history (commit, push, reset, rebase, checkout, stash, clean).`nNever add AI attribution anywhere.`nIf blocked, stop and say exactly what is missing.`nFinal message under 300 words: files changed, commands run with results, open risks."
    # TimeoutMin 0 (the default) means no timeout; a positive value is an opt-in deadline.
    if ($ComputerUse) {
        if (-not (Test-CodexDesktopRunning)) { throw 'BLOCKED: native CUA unavailable; Codex desktop app is not running.' }
        $mutex = New-Object Threading.Mutex($false, 'Global\orchestra-desktop')
        $waitMs = -1; if ($TimeoutMin -gt 0) { $waitMs = [int][Math]::Min(2147483647.0, $TimeoutMin * 60000) }
        try { $held = $mutex.WaitOne($waitMs) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out waiting for native CUA desktop lock (another ComputerUse worker is running).' }
        $Prompt += "`nNative desktop control: use mcp__node_repl__js through functions.exec as tools.mcp__node_repl__js (discover that exact name in ALL_TOOLS if deferred). Import with const {sky} = await import('@oai/sky'); call sky.list_windows() first as native preflight. Never use browser-only cua_repl for desktop apps. If the tool, import, or native preflight fails, stop and write Status: BLOCKED with BLOCKED: native CUA unavailable in the report. Include the end-state screenshot path in the final message."
    }
    $exe = $env:ORCHESTRA_CODEX; if (-not $exe) { $exe = (Get-Command codex -ErrorAction Stop).Source }
    if (-not [IO.Path]::IsPathRooted($exe)) { $exe = (Get-Command $exe -ErrorAction Stop).Source }
    if ([IO.Path]::GetExtension($exe) -ne '.exe') {
        $parent = Split-Path $exe -Parent; $real = Join-Path $parent 'codex.exe'
        if (-not [IO.File]::Exists($real)) {
            $real = Get-ChildItem -LiteralPath (Join-Path $parent 'node_modules\@openai\codex') -Recurse -File -Filter codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $real) { throw 'Cannot resolve the Codex shim to codex.exe in its npm package.' }; $exe = $real
    }
    $arguments = @('exec'); if ($Resume) { $arguments += @('resume', $Resume) }
    $arguments += @('--json', '-m', $Model, '-c', "model_reasoning_effort=`"$Effort`"", '-c', 'service_tier="default"',
        '-c', 'tool_output_token_limit=8000', '-c', 'model_auto_compact_token_limit=200000')
    if ($Resume) { $arguments += '--dangerously-bypass-approvals-and-sandbox' } else { $arguments += @('-s', 'danger-full-access', '-C', $Project) }
    $arguments += @('--skip-git-repo-check', '-o', "$base.last.md", '-')
    Initialize-WorkerJob
    $commandLine = (Quote-Argument $exe) + ' ' + (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $timer = [Diagnostics.Stopwatch]::StartNew(); $child = [CodexRunJob]::Start($exe, $commandLine, $Project)
    $outFile = [IO.File]::Create("$base.jsonl"); $errFile = [IO.File]::Create("$base.err.log")
    $outTask = $child.Output.CopyToAsync($outFile); $errTask = $child.Error.CopyToAsync($errFile)
    $bytes = $utf8.GetBytes($Prompt + "`n"); $inputTask = $child.Input.WriteAsync($bytes, 0, $bytes.Length); $inputClosed = $false
    while ($true) {
        if (-not $inputClosed -and $inputTask.IsCompleted) { $child.Input.Dispose(); $inputClosed = $true }
        $exited = $child.Process.WaitForExit(50)
        if ($exited -and $outTask.IsCompleted -and $errTask.IsCompleted) { break }
        if ($TimeoutMin -gt 0 -and $timer.Elapsed.TotalMinutes -ge $TimeoutMin) {
            $record.status = 'timeout'; $child.Kill()
            if (-not $child.Process.WaitForExit(5000)) { throw 'Worker did not exit after job termination.' }
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 5000)) { throw 'Worker streams did not close after job termination.' }
            break
        }
        if ($exited) { [Threading.Thread]::Sleep(50) }
    }
    [void]$outTask.GetAwaiter().GetResult(); [void]$errTask.GetAwaiter().GetResult()
    $record.exit_code = $child.Process.ExitCode
    if ($record.status -eq 'timeout') { $record.exit_code = 124 }
    elseif ($record.exit_code -eq 0 -and -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText("$base.last.md", $utf8))) { $record.status = 'done' }
} catch {
    $failure = $_.Exception.Message
} finally {
    if ($child) { $child.Dispose() }; if ($outFile) { $outFile.Dispose() }; if ($errFile) { $errFile.Dispose() }
    if ($timer) { $timer.Stop(); $record.seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1) }
    if ($held) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
}
if ($base) {
    if ($failure) { [IO.File]::AppendAllText("$base.err.log", $failure + "`n", $utf8) }
    foreach ($line in [IO.File]::ReadLines("$base.jsonl", $utf8)) {
        try { $event = ConvertFrom-Json $line } catch { continue }
        if ($event.type -eq 'thread.started') { $record.thread_id = $event.thread_id }
        if ($event.type -eq 'turn.completed' -and $event.usage) {
            $record.input_tokens += [long]$event.usage.input_tokens; $record.cached_input_tokens += [long]$event.usage.cached_input_tokens; $record.output_tokens += [long]$event.usage.output_tokens
        }
    }
    $record.finished = [DateTime]::UtcNow.ToString('o'); [IO.File]::WriteAllText("$base.json", ($record | ConvertTo-Json), $utf8)
}
$cached = 0; if ($record.input_tokens -gt 0) { $cached = [Math]::Round(100 * $record.cached_input_tokens / $record.input_tokens) }
Write-Output ('[codex-run] {0} {1} thread={2} {3}s in={4}k cached={5}% out={6}k' -f $id, $record.status, $record.thread_id,
    $record.seconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture), ($record.input_tokens / 1000).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture), $cached, ($record.output_tokens / 1000).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))
if ($record.status -eq 'done') {
    $lines = @([IO.File]::ReadLines("$base.last.md", $utf8) | Select-Object -First 14); $truncated = $lines.Count -gt 13
    foreach ($line in ($lines | Select-Object -First 13)) { if ($line.Length -gt 200) { $truncated = $true }; $line.Substring(0, [Math]::Min(200, $line.Length)) }
    if ($truncated) { Write-Output "... (full: $base.last.md)" }
    exit 0
}
if ($base) { Get-Content -LiteralPath "$base.err.log" -Encoding UTF8 -Tail 3 | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) } }
elseif ($failure) { Write-Output $failure.Substring(0, [Math]::Min(200, $failure.Length)) }
exit 1
