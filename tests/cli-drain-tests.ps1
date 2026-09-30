param([string]$Launcher = (Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'))
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:ORCHESTRA_TEST_ROOT ('drain-unit-' + [guid]::NewGuid().ToString('N'))
$null = . $Launcher init -Project $fixture
$script:checks = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw "FAIL: $Message" }; $script:checks++ }
$mock = @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Diagnostics;
public class MockDrain {
    public static int Main(string[] args) {
        var utf8 = new UTF8Encoding(false);
        Console.InputEncoding = utf8; Console.OutputEncoding = utf8;
        if (args[0] == "child") {
            File.WriteAllText(args[1], Process.GetCurrentProcess().Id.ToString(), utf8);
            Console.WriteLine("child-ready"); Console.Error.WriteLine("child-holds-stderr");
            System.Threading.Thread.Sleep(70000); return 0;
        }
        var prompt = Console.In.ReadToEnd();
        if (args[0] == "quick") {
            File.WriteAllLines(Path.Combine(Directory.GetCurrentDirectory(), "received.txt"), args, utf8);
            Console.Write(prompt); Console.Error.WriteLine("stderr-ok"); return 0;
        }
        var id = Regex.Match(prompt, @"\.orchestra/tasks/([^\s]+)\.md").Groups[1].Value;
        var root = Directory.GetCurrentDirectory();
        File.WriteAllText(Path.Combine(root, ".orchestra/reports/" + id + ".md"), "Status: DONE\n", utf8);
        var child = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,
            "child \"" + Path.Combine(root, id + ".child.pid") + "\"");
        child.UseShellExecute = false; child.CreateNoWindow = true;
        Process.Start(child);
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"mock-drain\"}");
        return 0;
    }
}
'@
$mockPath = Join-Path $fixture 'pipe-mock.exe'
Add-Type -TypeDefinition $mock -OutputAssembly $mockPath -OutputType ConsoleApplication
$realInvoke = (Get-Command Invoke-Codex).ScriptBlock
$script:workerTimedOut = $false
$argsToPass = @('quick', 'two words', 'a"b', '\directory space\')
$unicode = 'cafe Unicode: caf' + [char]0xe9
$code = & $realInvoke $mockPath $argsToPass $unicode "$fixture/quick.stdout" "$fixture/quick.stderr" 1
$received = [IO.File]::ReadAllLines("$fixture/received.txt", $utf8)
Assert ($code -eq 0 -and -not $script:workerTimedOut) 'Normal child exit and completed drainage'
Assert ($received[1] -eq 'two words' -and $received[2] -eq 'a"b' -and $received[3] -eq '\directory space\') 'CreateProcess quoting preserved'
Assert ([IO.File]::ReadAllText("$fixture/quick.stdout", $utf8).TrimEnd("`r", "`n") -eq $unicode) 'UTF8 prompt delivered'
Assert ([IO.File]::ReadAllText("$fixture/quick.stderr", $utf8).Trim() -eq 'stderr-ok') 'Both streams captured'
$script:nextExe = $mockPath
function Resolve-Codex($RequestedModel, $NeedsComputer, $Previous) {
    return [pscustomobject]@{ Info = [pscustomobject]@{ Path = $script:nextExe; VersionText = 'fixture'; Family = 'path' }; Model = $RequestedModel; Fallback = $null; Rule = 'auto' }
}
function Get-Context($Events, $SessionId) { return @{ tokens = 0; window = 0; source = 'fixture' } }
function Invoke-Codex($Exe, $Arguments, $Prompt, $Stdout, $Stderr) {
    $probeArgs = @('parent')
    if ($Exe -ne $mockPath) { $probeArgs = @() }
    return & $realInvoke $Exe $probeArgs $Prompt $Stdout $Stderr $TimeoutMin
}
foreach ($case in @(@('drain-limit', 1, 55, 68, 'timeout', 124, $true), @('drain-cap', 0, 29, 40, 'done', 0, $false))) {
    $id = $case[0]; $TimeoutMin = $case[1]
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-WorkerRun $id 'gpt-6-luna' 'low' $id $false $true $true $null
    $seconds = $watch.Elapsed.TotalSeconds
    Assert ($seconds -ge $case[2] -and $seconds -lt $case[3]) "$id duration $seconds"
    Assert ($result.Status -eq $case[4] -and $result.Line -match " exit=$($case[5]) ") "$id status/exit"
    Assert ($script:workerTimedOut -eq $case[6]) "$id timeout flag"
    $childPid = [int][IO.File]::ReadAllText("$fixture/$id.child.pid")
    $until = [DateTime]::UtcNow.AddSeconds(5)
    while ((Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
    Assert (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) "$id child gone after parent exit"
}
$crash = @'
using System;
public class MockCrash {
    public static int Main(string[] args) {
        Console.Error.WriteLine("memory allocation of 1 bytes failed");
        return -1073740791;
    }
}
'@
$script:nextExe = "$fixture/crash.exe"
Add-Type -TypeDefinition $crash -OutputAssembly $script:nextExe -OutputType ConsoleApplication
$TimeoutMin = 1
$result = Invoke-WorkerRun 'native-crash' 'gpt-6-luna' 'low' 'native-crash' $false $true $true $null
Assert ($result.Status -eq 'failed' -and $result.Line -match ' exit=-1073740791 ') 'Real negative native crash code retained'
Assert ($result.Line.EndsWith(' crash=alloc-failure')) 'Allocation crash suffix appended'
$err = "$fixture/reason.log"
Write-Utf8 $err 'thread main panicked at worker.rs:1'
Assert ((Get-CrashReason -1073740791 $err) -eq 'panic') 'Panic classification'
Assert ((Get-CrashReason 3221226505 $err) -eq 'panic') 'Unsigned native crash classification'
Assert (-not (Get-CrashReason 1 $err)) 'Ordinary CLI failure gets no crash suffix'
Write-Utf8 $err ("memory allocation of 1 bytes failed`n" + (('ordinary line' + "`n") * 25))
Assert (-not (Get-CrashReason -1073740791 $err)) 'Only stderr tail classifies crash'
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0 -and $PSVersionTable.PSVersion.Major -eq 5) 'Actual PS5.1 parser clean'
"PASS: $script:checks checks; fixture=$fixture"
