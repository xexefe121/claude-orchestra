param([string]$Launcher = (Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/codex-run.ps1'))
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-run-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$savedCodex = $env:ORCHESTRA_CODEX; $savedMode = $env:CODEX_RUN_TEST_MODE
$script:checks = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw "FAIL: $Message" }; $script:checks++ }
$mock = @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Threading;
public class MockCodexRun {
    public static int Main(string[] args) {
        var utf8 = new UTF8Encoding(false); Console.InputEncoding = utf8; Console.OutputEncoding = utf8;
        var cwd = Directory.GetCurrentDirectory();
        if (args.Length > 0 && args[0] == "child") {
            File.WriteAllText(Path.Combine(cwd, "child.pid"), Process.GetCurrentProcess().Id.ToString());
            Console.WriteLine("child-ready"); Console.Error.WriteLine("child-holds-stderr"); Thread.Sleep(60000); return 0;
        }
        File.WriteAllLines(Path.Combine(cwd, "args.txt"), args, utf8);
        File.WriteAllText(Path.Combine(cwd, "prompt.txt"), Console.In.ReadToEnd(), utf8);
        File.WriteAllText(Path.Combine(cwd, "entered.txt"), DateTime.UtcNow.Ticks.ToString());
        var mode = Environment.GetEnvironmentVariable("CODEX_RUN_TEST_MODE");
        var last = args[Array.IndexOf(args, "-o") + 1];
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fake-thread\"}");
        if (mode == "linger" || mode == "hang") {
            var child = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "child");
            child.UseShellExecute = false; child.CreateNoWindow = true; Process.Start(child);
            if (mode == "hang") Thread.Sleep(60000);
            return 0;
        }
        if (mode == "fail") {
            Console.Error.WriteLine("first\nsecond\nthird\nfourth"); File.WriteAllText(last, "Do not display failed final."); return 7;
        }
        if (mode == "serial") Thread.Sleep(1200);
        if (mode != "empty") {
            string message = "Files changed: hello.txt\nChecks: fake CLI passed.\nRisks: none.\n";
            if (mode == "long") { message = new string('x', 250) + "\n"; for (int i = 0; i < 20; i++) message += "line " + i + "\n"; }
            if (mode == "wide") message = new string('x', 250);
            File.WriteAllText(last, message, utf8);
        }
        Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10000,\"cached_input_tokens\":6000,\"output_tokens\":2000}}");
        File.WriteAllText(Path.Combine(cwd, "left.txt"), DateTime.UtcNow.Ticks.ToString()); return 0;
    }
}
'@
function Run-Case([string]$Name, [string]$Mode = 'fresh', [string[]]$Extra = @(), [string]$Script = $Launcher) {
    $project = Join-Path $root ($Name + ' project'); [void][IO.Directory]::CreateDirectory($project)
    $env:CODEX_RUN_TEST_MODE = $Mode
    # A PowerShell wrapper preserves quotes that PS5.1's native argument marshalling removes.
    $parameters = @{ Project = $project }
    for ($i = 0; $i -lt $Extra.Count; $i++) {
        $key = $Extra[$i].TrimStart('-')
        if ($key -eq 'ComputerUse') { $parameters[$key] = $true } else { $i++; $parameters[$key] = $Extra[$i] }
    }
    $argumentFile = Join-Path $root ($Name + '.clixml'); $parameters | Export-Clixml -LiteralPath $argumentFile -Encoding UTF8
    $wrapper = Join-Path $root ($Name + '-invoke.ps1')
    $code = '$parameters = Import-Clixml -LiteralPath ''' + $argumentFile.Replace("'", "''") + "'`n& '" + $Script.Replace("'", "''") + "' @parameters`nexit " + '$LASTEXITCODE'
    [IO.File]::WriteAllText($wrapper, $code, (New-Object Text.UTF8Encoding($true)))
    $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper)
    $exitCode = $LASTEXITCODE
    $meta = Get-ChildItem -LiteralPath (Join-Path $project '.orchestra/runs') -Filter '*.json' | Select-Object -First 1
    return [pscustomobject]@{ Project = $project; Lines = $lines; ExitCode = $exitCode; Record = ([IO.File]::ReadAllText($meta.FullName, $utf8) | ConvertFrom-Json) }
}
function Start-Serial([string]$Name, [string]$Script) {
    $project = Join-Path $root $Name; [void][IO.Directory]::CreateDirectory($project)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command powershell.exe).Source; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" -Project "' + $project + '" -Prompt test -ComputerUse'
    $process = [Diagnostics.Process]::Start($info)
    return [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync(); Project = $project }
}
try {
    $env:ORCHESTRA_CODEX = Join-Path $root 'fake codex.exe'
    Add-Type -TypeDefinition $mock -OutputAssembly $env:ORCHESTRA_CODEX -OutputType ConsoleApplication
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0 -and $PSVersionTable.PSVersion.Major -eq 5) 'PS5.1 parser clean'
    Assert (([IO.File]::ReadAllLines($Launcher)).Length -le 220) 'Runner within 220 lines'
    $fresh = Run-Case 'fresh' 'fresh' @('-Prompt', 'two words')
    Assert ($fresh.ExitCode -eq 0 -and $fresh.Record.status -eq 'done') 'Fresh run succeeds'
    Assert ($fresh.Lines[0] -match '^\[codex-run\] \d{8}-\d{6}-[a-f0-9]{4} done thread=fake-thread \d+\.\d+s in=10.0k cached=60% out=2.0k$') 'Compact result format'
    $fields = @('id', 'status', 'thread_id', 'model', 'effort', 'seconds', 'input_tokens', 'cached_input_tokens', 'output_tokens', 'exit_code', 'started', 'finished')
    foreach ($field in $fields) { Assert ($fresh.Record.PSObject.Properties.Name -contains $field) "JSON field $field" }
    Assert ($fresh.Record.model -eq 'gpt-6.1-sol' -and $fresh.Record.effort -eq 'medium') 'Defaults'
    Assert ([DateTime]::Parse($fresh.Record.finished) -ge [DateTime]::Parse($fresh.Record.started)) 'Valid timestamps'
    Assert ([IO.File]::ReadAllText((Join-Path $fresh.Project '.orchestra/.gitignore'), $utf8) -eq "*`n") 'Ignore created'
    Assert (@(Get-ChildItem (Join-Path $fresh.Project '.orchestra/runs')).Count -eq 4) 'Exactly four run files'
    $actual = [IO.File]::ReadAllLines((Join-Path $fresh.Project 'args.txt'), $utf8)
    $expected = @('exec', '--json', '-m', 'gpt-6.1-sol', '-c', 'model_reasoning_effort="medium"', '-c', 'service_tier="default"', '-c', 'tool_output_token_limit=8000', '-c', 'model_auto_compact_token_limit=200000', '-s', 'danger-full-access', '-C', $fresh.Project, '--skip-git-repo-check', '-o', (Join-Path $fresh.Project ('.orchestra/runs/' + $fresh.Record.id + '.last.md')), '-')
    Assert (($actual -join "`n") -eq ($expected -join "`n")) 'Exact fresh arguments and quoted project'
    $resume = Run-Case 'resume' 'fresh' @('-Prompt', 'continue', '-Resume', 'original-thread', '-Model', 'custom slug', '-Effort', 'high', '-TimeoutMin', '120')
    $argsRead = [IO.File]::ReadAllLines((Join-Path $resume.Project 'args.txt'), $utf8)
    Assert ($resume.ExitCode -eq 0 -and ($argsRead[0..2] -join ' ') -eq 'exec resume original-thread') 'Resume thread passed'
    Assert ($argsRead -contains '--dangerously-bypass-approvals-and-sandbox' -and $argsRead -cnotcontains '-C' -and $argsRead -notcontains '-s') 'Resume sandbox and working directory'
    Assert ($argsRead -contains 'custom slug' -and $argsRead -contains 'model_reasoning_effort="high"') 'Model unchanged and high effort'
    $source = [IO.File]::ReadAllText($Launcher, $utf8)
    Assert ($resume.ExitCode -eq 0) 'Timeout above 90 accepted'
    $unicode = 'two spaces  caf' + [char]0xe9 + ' ' + [char]0x4e2d + ' "quoted" C:\directory space\'
    $promptFile = Join-Path $root 'unicode prompt.txt'; [IO.File]::WriteAllText($promptFile, $unicode, $utf8)
    $fileCase = Run-Case 'promptfile' 'fresh' @('-PromptFile', $promptFile)
    Assert ([IO.File]::ReadAllText((Join-Path $fileCase.Project 'prompt.txt'), $utf8).StartsWith($unicode + "`n")) 'Unicode prompt file intact'
    $direct = Run-Case 'prompt' 'fresh' @('-Prompt', $unicode)
    Assert ([IO.File]::ReadAllText((Join-Path $direct.Project 'prompt.txt'), $utf8).StartsWith($unicode + "`n")) 'Unicode prompt argument intact'
    $received = [IO.File]::ReadAllText((Join-Path $direct.Project 'prompt.txt'), $utf8)
    Assert ($received.Contains('Never add AI attribution anywhere.') -and $received.Contains('Final message under 300 words:') -and $received.Contains('no `&&` or `||`')) 'Fixed guidance appended'
    $stdinProject = Join-Path $root 'stdin project'; [void][IO.Directory]::CreateDirectory($stdinProject)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command powershell.exe).Source; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Launcher + '" -Project "' + $stdinProject + '"'
    $proc = [Diagnostics.Process]::Start($info); $stdout = $proc.StandardOutput.ReadToEndAsync(); $stderr = $proc.StandardError.ReadToEndAsync()
    $stdinBytes = $utf8.GetBytes($unicode); $proc.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length); $proc.StandardInput.Close()
    Assert ($proc.WaitForExit(15000) -and $proc.ExitCode -eq 0) 'Stdin run succeeds'
    Assert ([IO.File]::ReadAllText((Join-Path $stdinProject 'prompt.txt'), $utf8).StartsWith($unicode + "`n")) 'UTF8 stdin intact'
    $proc.Dispose()
    $empty = Run-Case 'empty' 'empty' @('-Prompt', 'test')
    Assert ($empty.ExitCode -eq 1 -and $empty.Record.status -eq 'failed' -and $empty.Record.exit_code -eq 0) 'Empty final fails despite exit 0'
    $fail = Run-Case 'fail' 'fail' @('-Prompt', 'test')
    Assert ($fail.ExitCode -eq 1 -and $fail.Record.exit_code -eq 7 -and ($fail.Lines[1..3] -join '|') -eq 'second|third|fourth') 'Failure displays only last three stderr lines'
    foreach ($mode in @('long', 'wide')) {
        $long = Run-Case $mode $mode @('-Prompt', 'test')
        Assert ($long.ExitCode -eq 0 -and $long.Lines.Count -le 15 -and $long.Lines[-1].StartsWith('... (full: ')) "$mode truncation and line limit"
        Assert (@($long.Lines[1..($long.Lines.Count - 2)] | Where-Object { $_.Length -gt 200 }).Count -eq 0) "$mode message lines at most 200 chars"
    }
    foreach ($mode in @('linger', 'hang')) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $timeout = Run-Case $mode $mode @('-Prompt', 'test', '-TimeoutMin', '0.05')
        Assert ($timeout.ExitCode -eq 1 -and $timeout.Record.status -eq 'timeout' -and $timeout.Record.exit_code -eq 124 -and $watch.Elapsed.TotalSeconds -lt 15) "$mode deadline enforced"
        $childPid = [int][IO.File]::ReadAllText((Join-Path $timeout.Project 'child.pid'))
        $until = [DateTime]::UtcNow.AddSeconds(3)
        while ((Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
        Assert (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) "$mode no surviving child"
    }
    $desktopFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-CodexDesktopRunning' }, $true).Extent.Text
    $falseScript = Join-Path $root 'desktop-false.ps1'; $trueScript = Join-Path $root 'desktop-true.ps1'
    [IO.File]::WriteAllText($falseScript, $source.Replace($desktopFunction, 'function Test-CodexDesktopRunning { return $false }'), $utf8)
    [IO.File]::WriteAllText($trueScript, $source.Replace($desktopFunction, 'function Test-CodexDesktopRunning { return $true }'), $utf8)
    $notReady = Run-Case 'desktop-false' 'fresh' @('-Prompt', 'test', '-ComputerUse') $falseScript
    Assert ($notReady.ExitCode -eq 1 -and ($notReady.Lines -join ' ').Contains('Codex desktop app is not running.') -and -not (Test-Path (Join-Path $notReady.Project 'args.txt'))) 'Desktop false fails before CLI launch'
    $env:CODEX_RUN_TEST_MODE = 'serial'
    $first = Start-Serial 'desktop-one' $trueScript; $second = Start-Serial 'desktop-two' $trueScript
    Assert ($first.Process.WaitForExit(20000) -and $second.Process.WaitForExit(20000) -and $first.Process.ExitCode -eq 0 -and $second.Process.ExitCode -eq 0) 'Two desktop runs complete'
    $aStart = [long][IO.File]::ReadAllText((Join-Path $first.Project 'entered.txt')); $aEnd = [long][IO.File]::ReadAllText((Join-Path $first.Project 'left.txt'))
    $bStart = [long][IO.File]::ReadAllText((Join-Path $second.Project 'entered.txt')); $bEnd = [long][IO.File]::ReadAllText((Join-Path $second.Project 'left.txt'))
    Assert ($aEnd -le $bStart -or $bEnd -le $aStart) 'Machine-wide mutex serializes actual CLI intervals'
    $desktopPrompt = [IO.File]::ReadAllText((Join-Path $first.Project 'prompt.txt'), $utf8)
    Assert ($desktopPrompt.Contains('mcp__node_repl__js') -and $desktopPrompt.Contains("@oai/sky") -and $desktopPrompt.Contains('sky.list_windows() first') -and $desktopPrompt.Contains('Never use browser-only cua_repl') -and $desktopPrompt.Contains('end-state screenshot path')) 'Native control guidance'
    Assert ((@($first.Out.Result -split "\r?\n" | Where-Object { $_ }).Count -le 15) -and (@($second.Out.Result -split "\r?\n" | Where-Object { $_ }).Count -le 15)) 'Desktop output line cap'
    $first.Process.Dispose(); $second.Process.Dispose()
    $shimFolder = Join-Path $root 'npm shim'; $package = Join-Path $shimFolder 'node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex'
    [void][IO.Directory]::CreateDirectory($package); Copy-Item -LiteralPath $env:ORCHESTRA_CODEX -Destination (Join-Path $package 'codex.exe')
    $shim = Join-Path $shimFolder 'codex.ps1'; [IO.File]::WriteAllText($shim, 'throw "The shim must not execute."', $utf8)
    $env:ORCHESTRA_CODEX = $shim
    $shimRun = Run-Case 'shim' 'fresh' @('-Prompt', 'test')
    Assert ($shimRun.ExitCode -eq 0) 'npm shim resolves to real executable'
    'PASS: ' + $script:checks + ' checks; fresh/resume/UTF8/stdin/timeout/desktop/output/metadata/shim; fixture=' + $root
} finally {
    $env:ORCHESTRA_CODEX = $savedCodex; $env:CODEX_RUN_TEST_MODE = $savedMode
}
