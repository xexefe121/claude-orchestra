param([string]$Launcher = (Join-Path (Split-Path $PSScriptRoot -Parent) 'skills/orchestra/scripts/orchestra.ps1'))
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:ORCHESTRA_TEST_ROOT ('batch-unit-'+[guid]::NewGuid().ToString('N'))
$null=. $Launcher init -Project $fixture
$script:checks=0
function Assert($Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
$mock=@'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
public class EfficiencyMockCodex {
    public static int Main(string[] args) {
        var utf8 = new UTF8Encoding(false);
        Console.InputEncoding = utf8; Console.OutputEncoding = utf8;
        if (args[0] == "--version") { Console.WriteLine("codex-cli 0.159.2"); return 0; }
        if (args[0] == "debug") { Console.WriteLine("{\"models\":[{\"slug\":\"gpt-6-luna\"}]}"); return 0; }
        var prompt = Console.In.ReadToEnd();
        var id = Regex.Match(prompt, @"\.orchestra/tasks/([^\s]+)\.md").Groups[1].Value;
        var project = Directory.GetCurrentDirectory();
        File.WriteAllText(Path.Combine(project, id + ".invoked"), prompt, utf8);
        if (id == "timeout" || id == "reviewed-review") { System.Threading.Thread.Sleep(600000); return 0; }
        if (id == "exit124") { return 124; }
        File.WriteAllText(Path.Combine(project, ".orchestra/reports/" + id + ".md"), "Status: DONE\n## Summary\nCompleted.\n## Open issues and risks\n- None.", utf8);
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"mock-eff-batch\"}");
        Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1000,\"model_context_window\":200000}}");
        return 0;
    }
}
'@
$mockPath=Join-Path $fixture 'codex.exe'
Add-Type -TypeDefinition $mock -OutputAssembly $mockPath -OutputType ConsoleApplication
# Warm the normal version/model cache outside jobs; synthetic .NET console startup
# can stall version probes under PS5.1 background-job console inheritance.
$info=Get-CodexInfo $mockPath
$null=Get-CodexModels $info
foreach($id in @('ok','timeout','skip','reviewed','reviewskip','forced','under','blocked','exit124')){Write-Utf8 "$state/tasks/$id.md" "# $id"}
$records=@()
foreach($name in @('forced-worker','under-worker','blocked-worker')) {
    $pct=70;if($name -eq 'under-worker'){$pct=69}
    $records += [pscustomobject]@{
        name=$name;model='gpt-6-luna';effort='low';session_id='mock-eff-batch';status='done';current_task="seed-$name";tasks=@("seed-$name")
        context_tokens=($pct*2000);context_window=200000;context_pct=$pct;context_source='mock';exit_code=0
        started=[DateTime]::UtcNow.AddMinutes(-2).ToString('o');finished=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');report=$null
        engine='codex';cli_path=$mockPath;cli_family='path';cli_rule='auto';computer_use=$false
    }
}
Save-Workers $records
$entries=@(
    @{task='ok';model='luna';effort='low';timeoutMin=0},
    @{task='timeout';model='luna';effort='low';timeoutMin=1},
    @{task='skip';model='luna';effort='low';dependsOn=@('timeout')},
    @{task='reviewed';model='luna';effort='low';review=$true;reviewModel='luna';reviewEffort='low';reviewTimeoutMin=1},
    @{task='reviewskip';model='luna';effort='low';dependsOn=@('reviewed')},
    @{task='forced';model='luna';effort='low';name='forced-worker';resume=$true;force=$true},
    @{task='under';model='luna';effort='low';name='under-worker';resume=$true},
    @{task='blocked';model='luna';effort='low';name='blocked-worker';resume=$true},
    @{task='exit124';model='luna';effort='low'}
)
Write-Utf8 "$fixture/plan.json" (ConvertTo-Json -InputObject $entries -Depth 6)
$saved=$env:ORCHESTRA_CODEX
try {
    $env:ORCHESTRA_CODEX=$mockPath
    $lines=@(& $Launcher batch -Project $fixture -Plan plan.json)
    Write-Utf8 "$fixture/output.txt" ($lines -join "`n")
    Assert ($lines[-1] -eq '[orchestra] batch done=3 failed=4 skipped=2') 'Worker and reviewer timeout count as failed; guard/CLI failures count as failed'
    Assert (@($lines|Where-Object{$_ -match '^\[orchestra\].* timeout exit=124 '}).Count -eq 2) 'Both timeout result lines preserved'
    Assert (@($lines|Where-Object{$_ -match ' exit124 failed exit=124 '}).Count -eq 1) 'CLI exit 124 without expiry remains failed'
    Assert (@($lines|Where-Object{$_ -eq '  | Status: DONE'}).Count -eq 4) 'Batch retains digests'
    Assert ($lines -contains '[orchestra] - skip skipped dep=timeout') 'Timeout skips dependent'
    Assert ($lines -contains '[orchestra] - reviewskip skipped dep=reviewed') 'Reviewer timeout skips dependent'
    Assert ([IO.File]::Exists("$fixture/forced.invoked") -and [IO.File]::Exists("$fixture/under.invoked")) 'Batch force/under threshold pass'
    Assert (-not [IO.File]::Exists("$fixture/blocked.invoked")) 'Batch full worker fails without force'
    $board=[IO.File]::ReadAllText("$state/board.md",$utf8)
    Assert ($board -match '\| skip \| - \| gpt-6-luna low \| skipped \|') 'Skipped task persisted on board'
    Assert ($board -match '\| reviewed-review \|.*\| timeout \|') 'Reviewer timeout on board'
    Assert ($board -match '\| blocked \| - \|.*\| failed \|') 'Prelaunch failure on board'
    $current=@(Read-Workers|Where-Object{$_.name -eq 'forced-worker'})[0]
    Assert ($current.current_task -eq 'forced' -and $current.status -eq 'done') 'Forced worker state updated'
    $quiet=@(& $Launcher run -Project $fixture -Task ok -Model luna -Effort low -NoDigest -TimeoutMin 0)
    Assert ($quiet.Count -eq 1 -and $quiet[0] -match ' done exit=0 ') 'NoDigest integrated and zero timeout accepts successful run'
} finally {$env:ORCHESTRA_CODEX=$saved}
"PASS: $script:checks checks; fixture=$fixture"
