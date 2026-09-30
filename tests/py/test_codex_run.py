"""Offline contract checks with an executable fixture confined to temp directories."""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import time
import unittest
from unittest import mock

RUNNER = Path(__file__).resolve().parents[2] / "skills/orchestra/scripts/codex-run.py"
spec = importlib.util.spec_from_file_location("codex_run", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

FAKE = r'''import json, os, signal, subprocess, sys, time
from pathlib import Path
if len(sys.argv) > 1 and sys.argv[1] == 'child':
    if os.name != 'nt': signal.signal(signal.SIGTERM, signal.SIG_IGN)
    Path('child.pid').write_text(str(os.getpid()))
    print('child-ready', flush=True)
    print('child-holds-stderr', file=sys.stderr, flush=True)
    time.sleep(60)
    sys.exit()
args = Path('args.txt').read_text(encoding='utf-8-sig').splitlines() if os.name == 'nt' else sys.argv[1:]
Path('args.txt').write_text('\n'.join(args), encoding='utf-8')
Path('prompt.txt').write_bytes(sys.stdin.buffer.read())
mode = os.environ.get('FAKE_MODE', 'fresh')
last = Path(args[args.index('-o') + 1])
print(json.dumps({'type': 'thread.started', 'thread_id': 'fake-thread'}), flush=True)
if mode in ('hang', 'linger'):
    subprocess.Popen([sys.executable, __file__, 'child'])
    if mode == 'hang': time.sleep(60)
    sys.exit()
if mode == 'silent-child':
    subprocess.Popen([sys.executable, __file__, 'child'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if Path('child.pid').exists(): break
        time.sleep(0.01)
if mode == 'fail':
    print('first\nsecond\nthird\nfourth', file=sys.stderr)
    last.write_text('Do not display failed final.', encoding='utf-8')
    sys.exit(7)
if mode == 'flood':
    sys.stdout.write('x' * 200000 + '\n'); sys.stdout.flush()
    sys.stderr.write('y' * 200000 + '\n'); sys.stderr.flush()
if mode != 'empty':
    last.write_text(('x' * 250 + '\n' + '\n'.join('line ' + str(i) for i in range(20))) if mode == 'long'
                    else 'Files changed: hello.txt\nChecks: fake CLI passed.\nRisks: none.\n', encoding='utf-8')
print('invalid json')
for _ in range(2):
    print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 5000, 'cached_input_tokens': 3000, 'output_tokens': 1000}}))
'''


class CodexRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="codex-run-tests-")
        root = Path(cls.fixture.name)
        cls.script = root / "fake codex.py"
        cls.script.write_text("#!/usr/bin/env python3\n" + FAKE, encoding="utf-8")
        cls.exe = cls.script
        if os.name == "nt":
            cls.exe = root / "fake codex.exe"
            # Native fixture avoids depending on installed script associations on Windows.
            source = r'''
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Threading;
public class FakeCodex {
    public static int Main(string[] args) {
        var utf8 = new UTF8Encoding(false); Console.InputEncoding = utf8; Console.OutputEncoding = utf8;
        if (args.Length > 0 && args[0] == "child") {
            File.WriteAllText("child.pid", Process.GetCurrentProcess().Id.ToString());
            Console.WriteLine("child-ready"); Console.Error.WriteLine("child-holds-stderr");
            Thread.Sleep(60000); return 0;
        }
        File.WriteAllLines("args.txt", args, utf8);
        File.WriteAllText("prompt.txt", Console.In.ReadToEnd(), utf8);
        var mode = Environment.GetEnvironmentVariable("FAKE_MODE");
        var last = args[Array.IndexOf(args, "-o") + 1];
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fake-thread\"}");
        if (mode == "hang" || mode == "linger") {
            var info = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "child");
            info.UseShellExecute = false; info.CreateNoWindow = true; Process.Start(info);
            if (mode == "hang") Thread.Sleep(60000);
            return 0;
        }
        if (mode == "fail") {
            Console.Error.WriteLine("first\nsecond\nthird\nfourth");
            File.WriteAllText(last, "Do not display failed final."); return 7;
        }
        if (mode == "flood") {
            Console.WriteLine(new string('x', 200000)); Console.Error.WriteLine(new string('y', 200000));
        }
        if (mode != "empty") {
            var message = "Files changed: hello.txt\nChecks: fake CLI passed.\nRisks: none.\n";
            if (mode == "long") {
                message = new string('x', 250) + "\n";
                for (int i = 0; i < 20; i++) message += "line " + i + "\n";
            }
            File.WriteAllText(last, message, utf8);
        }
        Console.WriteLine("invalid json");
        for (int i = 0; i < 2; i++)
            Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":5000,\"cached_input_tokens\":3000,\"output_tokens\":1000}}");
        return 0;
    }
}
'''
            cs = root / "fake.cs"
            cs.write_text(source, encoding="utf-8")
            build = root / "build.ps1"
            build.write_text("$ErrorActionPreference = 'Stop'\nAdd-Type -TypeDefinition ([IO.File]::ReadAllText($env:FAKE_CS)) -OutputAssembly $env:FAKE_EXE -OutputType ConsoleApplication\n", encoding="utf-8")
            env = dict(os.environ, FAKE_CS=str(cs), FAKE_EXE=str(cls.exe))
            subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(build)],
                           env=env, check=True, capture_output=True, timeout=30)
        else:
            cls.script.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex project ")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()

    def run_case(self, mode="fresh", extra=(), stdin=None, cwd=None):
        env = dict(os.environ, ORCHESTRA_CODEX=str(self.exe), FAKE_MODE=mode,
                   FAKE_PYTHON=sys.executable, FAKE_SCRIPT=str(self.script))
        command = [sys.executable, str(RUNNER), "--project", str(self.project)]
        if stdin is None and "--prompt-file" not in extra and "--prompt" not in extra:
            command += ["--prompt", "two words"]
        result = subprocess.run(command + list(extra), input=stdin, env=env, cwd=cwd, capture_output=True, timeout=20)
        self.assertEqual(result.stderr, b"")
        lines = result.stdout.decode("utf-8").splitlines()
        self.assertLessEqual(len(lines), 15)
        records = list((self.project / ".orchestra/runs").glob("*.json"))
        self.assertEqual(len(records), 1)
        return result, lines, json.loads(records[0].read_text(encoding="utf-8"))

    def arguments(self):
        return (self.project / "args.txt").read_text(encoding="utf-8").splitlines()

    def test_fresh_and_run_fields(self):
        result, lines, record = self.run_case()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(record["status"], "done")
        self.assertEqual(set(record), {"id", "status", "thread_id", "model", "effort", "seconds", "input_tokens",
                                      "cached_input_tokens", "output_tokens", "exit_code", "started", "finished"})
        self.assertEqual((record["thread_id"], record["input_tokens"], record["cached_input_tokens"], record["output_tokens"]),
                         ("fake-thread", 10000, 6000, 2000))
        self.assertGreaterEqual(datetime.datetime.fromisoformat(record["finished"]), datetime.datetime.fromisoformat(record["started"]))
        self.assertRegex(lines[0], r"^\[codex-run\] \d{8}-\d{6}-[a-f0-9]{4} done thread=fake-thread \d+\.\d+s in=10.0k cached=60% out=2.0k$")
        self.assertEqual((self.project / ".orchestra/.gitignore").read_bytes(), b"*\n")
        base = self.project / ".orchestra/runs" / record["id"]
        self.assertEqual(self.arguments(), ["exec", "--json", "-m", "gpt-6.1-sol", "-c", 'model_reasoning_effort="medium"',
                         "-c", 'service_tier="default"', "-c", "tool_output_token_limit=8000", "-c", "model_auto_compact_token_limit=200000",
                         "-s", "danger-full-access", "-C", str(self.project), "--skip-git-repo-check", "-o", str(base) + ".last.md", "-"])
        self.assertEqual({p.name for p in base.parent.iterdir()}, {record["id"] + suffix for suffix in (".json", ".jsonl", ".err.log", ".last.md")})

    def test_resume_passes_thread(self):
        result, _, record = self.run_case(extra=("--resume", "original-thread", "--model", "custom slug", "--effort", "high", "--timeout-min", "120"))
        self.assertEqual(result.returncode, 0)
        args = self.arguments()
        self.assertEqual(args[:3], ["exec", "resume", "original-thread"])
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", args)
        self.assertNotIn("-C", args); self.assertNotIn("-s", args)
        self.assertEqual((record["model"], record["effort"]), ("custom slug", "high"))
        self.assertIn('model_reasoning_effort="high"', args)

    def test_relative_executable_override(self):
        self.exe = "./" + self.exe.name
        result, _, record = self.run_case(cwd=self.fixture.name)
        self.assertEqual((result.returncode, record["status"]), (0, "done"))

    def test_unicode_prompt(self):
        prompt = 'two spaces  café 中文 🐍 "quoted" C:\\directory space\\'
        self.run_case(extra=("--prompt", prompt))
        received = (self.project / "prompt.txt").read_text(encoding="utf-8")
        self.assertTrue(received.startswith(prompt + "\n"))
        self.assertIn(runner.GUIDANCE, received)
        self.assertEqual("Shell is Windows PowerShell 5.1:" in received, os.name == "nt")
        self.assertEqual("Shell is bash/zsh:" in received, os.name != "nt")

    def test_unicode_prompt_file(self):
        path = self.project / "unicode prompt.txt"
        prompt = "café 中文 🐍"
        path.write_text(prompt, encoding="utf-8")
        self.run_case(extra=("--prompt-file", str(path)))
        self.assertTrue((self.project / "prompt.txt").read_text(encoding="utf-8").startswith(prompt + "\n"))

    def test_unicode_stdin(self):
        prompt = "café 中文 🐍"
        self.run_case(stdin=prompt.encode("utf-8"))
        self.assertTrue((self.project / "prompt.txt").read_bytes().startswith((prompt + "\n").encode("utf-8")))

    def test_empty_final_fails(self):
        result, _, record = self.run_case("empty")
        self.assertEqual((result.returncode, record["status"], record["exit_code"]), (1, "failed", 0))

    def test_failure_tail(self):
        result, lines, record = self.run_case("fail")
        self.assertEqual((result.returncode, record["exit_code"]), (1, 7))
        self.assertEqual(lines[1:], ["second", "third", "fourth"])

    def test_output_cap(self):
        result, lines, _ = self.run_case("long")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(lines), 15)
        self.assertTrue(lines[-1].startswith("... (full: "))
        self.assertTrue(all(len(line) <= 200 for line in lines[1:-1]))

    def test_streams_drained(self):
        result, _, record = self.run_case("flood")
        self.assertEqual((result.returncode, record["status"]), (0, "done"))

    def child_alive(self, pid):
        if os.name == "nt":
            import ctypes
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.restype = ctypes.c_void_p
            handle = kernel.OpenProcess(0x1000, False, pid)
            if not handle:
                return False
            code = ctypes.c_ulong()
            kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))
            kernel.CloseHandle(ctypes.c_void_p(handle))
            return code.value == 259
        # A terminated child may briefly remain a zombie until init reaps it.
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True).stdout.decode().strip()
        return bool(state) and not state.startswith("Z")

    def timeout_case(self, mode):
        started = time.monotonic()
        result, _, record = self.run_case(mode, extra=("--timeout-min", "0.05"))
        self.assertEqual((result.returncode, record["status"], record["exit_code"]), (1, "timeout", 124))
        self.assertLess(time.monotonic() - started, 15)
        pid = int((self.project / "child.pid").read_text())
        deadline = time.monotonic() + 3
        while self.child_alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        alive = self.child_alive(pid)
        if alive:  # Test failure still cleans up its fixture child.
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
            else:
                os.kill(pid, 9)
        self.assertFalse(alive, "Timeout left a living child")

    def test_timeout_kills_child(self):
        self.timeout_case("hang")

    def test_timeout_kills_child_after_parent_exit(self):
        self.timeout_case("linger")

    def test_computer_use_preflight_failure(self):
        env = dict(os.environ, ORCHESTRA_CODEX=str(self.exe))
        with mock.patch.object(sys, "argv", [str(RUNNER), "--project", str(self.project), "--prompt", "test", "--computer-use"]), \
                mock.patch.dict(os.environ, env), mock.patch.object(runner, "desktop_running", return_value=False), \
                mock.patch("builtins.print") as output:
            self.assertEqual(runner.main(), 1)
        lines = [str(call.args[0]) for call in output.call_args_list]
        self.assertIn("BLOCKED: native CUA unavailable; Codex desktop app is not running.", lines)
        self.assertFalse((self.project / "args.txt").exists())
        record = json.loads(next((self.project / ".orchestra/runs").glob("*.json")).read_text(encoding="utf-8"))
        self.assertEqual(record["status"], "failed")

    def test_desktop_probe_missing_command(self):
        with mock.patch.object(runner.subprocess, "run", side_effect=FileNotFoundError):
            self.assertFalse(runner.desktop_running())

    def test_computer_use_guidance_and_lock(self):
        env = dict(os.environ, ORCHESTRA_CODEX=str(self.exe), FAKE_MODE="fresh")
        argv = [str(RUNNER), "--project", str(self.project), "--prompt", "test", "--computer-use"]
        with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, env), \
                mock.patch.object(runner, "desktop_running", return_value=True), \
                mock.patch.object(runner.tempfile, "gettempdir", return_value=str(self.project)), mock.patch("builtins.print"):
            self.assertEqual(runner.main(), 0)
        self.assertIn(runner.NATIVE, (self.project / "prompt.txt").read_text(encoding="utf-8"))
        self.assertTrue((self.project / "orchestra-desktop.lock").exists())

    def test_desktop_lock_contention_and_release(self):
        with mock.patch.object(runner.tempfile, "gettempdir", return_value=str(self.project)):
            first = runner.desktop_lock(1)
            try:
                with self.assertRaisesRegex(RuntimeError, "Timed out waiting"):
                    runner.desktop_lock(0.05)
            finally:
                first.close()
            runner.desktop_lock(1).close()
        self.assertEqual((self.project / "orchestra-desktop.lock").stat().st_size, 1)

    @unittest.skipIf(os.name == "nt", "POSIX cleanup when descendants close inherited pipes")
    def test_success_cleans_child_with_closed_pipes(self):
        result, _, record = self.run_case("silent-child")
        self.assertEqual((result.returncode, record["status"]), (0, "done"))
        pid = int((self.project / "child.pid").read_text())
        alive = self.child_alive(pid)
        if alive:
            os.kill(pid, 9)
        self.assertFalse(alive, "Successful parent left a living child")


class ShellInstallerTests(unittest.TestCase):
    def setUp(self):
        self.bash = shutil.which("bash")
        if os.name == "nt":
            git = shutil.which("git")
            candidate = Path(git).parent.parent / "bin/bash.exe" if git else Path("missing")
            self.bash = str(candidate) if candidate.is_file() else None
        if not self.bash:
            self.skipTest("Git Bash / bash unavailable")
        self.temp = tempfile.TemporaryDirectory(prefix="orchestra install ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        source = RUNNER.parents[3]
        self.repo = self.root / "clone"
        shutil.copytree(source / "skills/orchestra", self.repo / "skills/orchestra")
        (self.repo / "docs").mkdir()
        shutil.copyfile(source / "docs/AGENTS-snippet.md", self.repo / "docs/AGENTS-snippet.md")
        for name in ("install.sh", "uninstall.sh"):
            # Windows checkouts may translate shell files to CRLF; fixtures use POSIX newlines.
            (self.repo / name).write_bytes((source / name).read_text(encoding="utf-8").encode("utf-8"))
        self.env = dict(os.environ, HOME=self.home.as_posix())

    def shell(self, script, *args, stdin=None):
        result = subprocess.run([self.bash, str(script).replace("\\", "/"), *args], input=stdin,
                                env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout.decode(errors="replace")

    def test_install_repeat_backup_and_uninstall(self):
        self.shell(self.repo / "install.sh", "--add-agents-rule")
        skill = self.home / ".claude/skills/orchestra"
        self.assertEqual((skill / "scripts/codex-run.py").read_bytes(), RUNNER.read_bytes())
        agents = self.home / ".claude/AGENTS.md"
        self.assertEqual(agents.read_text(encoding="utf-8").count("<!-- orchestra:start -->"), 1)
        self.assertNotIn("orchestra:git:start", agents.read_text(encoding="utf-8"))
        with agents.open("a", encoding="utf-8") as handle:
            handle.write("Keep user rule.\n")
        self.shell(self.repo / "install.sh", "--add-agents-rule")
        self.assertEqual(agents.read_text(encoding="utf-8").count("<!-- orchestra:start -->"), 1)
        self.assertEqual(len(list(skill.parent.glob("orchestra.bak-*"))), 1)
        self.shell(self.repo / "uninstall.sh")
        self.assertFalse(skill.exists())
        self.assertEqual(agents.read_text(encoding="utf-8").strip(), "Keep user rule.")
        self.assertEqual(len(list(skill.parent.glob("orchestra.bak-*"))), 2)
        self.assertEqual(len(list(agents.parent.glob("AGENTS.md.bak-*"))), 1)
        self.shell(self.repo / "uninstall.sh")

    def test_claude_rule_fallback(self):
        claude = self.home / ".claude/CLAUDE.md"
        claude.parent.mkdir()
        claude.write_text("Existing rule.\n", encoding="utf-8")
        self.shell(self.repo / "install.sh", "--add-agents-rule")
        self.assertFalse((claude.parent / "AGENTS.md").exists())
        self.assertTrue(claude.read_text(encoding="utf-8").startswith("Existing rule.\n"))
        self.shell(self.repo / "uninstall.sh")
        self.assertEqual(claude.read_text(encoding="utf-8").strip(), "Existing rule.")

    def test_piped_install_downloads_main_tarball_offline(self):
        archive = self.root / "main.tar.gz"
        with tarfile.open(archive, "w:gz") as package:
            for relative in ("skills/orchestra", "docs/AGENTS-snippet.md"):
                package.add(self.repo / relative, arcname="claude-orchestra-main/" + relative)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text('#!/usr/bin/env bash\nset -euo pipefail\n[ "$1" = -fsSL ]\n[ "$2" = https://github.com/xexefe121/claude-orchestra/archive/refs/heads/main.tar.gz ]\n[ "$3" = -o ]\ncp "$FAKE_ARCHIVE" "$4"\n', encoding="utf-8")
        curl.chmod(0o755)
        self.env["FAKE_ARCHIVE"] = archive.as_posix()
        self.env["FAKE_CURL"] = curl.as_posix()
        # Override by function so Windows PATH conversion can never fall back to network curl.
        script = b'curl() { "$BASH" "$FAKE_CURL" "$@"; }\n' + (self.repo / "install.sh").read_bytes()
        self.shell("-s", "--", "--add-agents-rule", stdin=script)
        self.assertTrue((self.home / ".claude/skills/orchestra/scripts/codex-run.py").is_file())


if __name__ == "__main__":
    unittest.main()
