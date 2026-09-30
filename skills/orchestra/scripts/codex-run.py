#!/usr/bin/env python3
"""Small, UTF-8 Codex runner; Python 3.9+, standard library only."""
import argparse, csv, ctypes
import datetime as dt
import json, math, os, re
from pathlib import Path
import shutil, signal, struct, subprocess, sys, tempfile, threading, time, uuid

WINDOWS = os.name == "nt"
GUIDANCE = """Keep tool output small: read line ranges or filter; never print whole large files or logs.
Touch only what the task needs. Do not run git commands that change history (commit, push, reset, rebase, checkout, stash, clean).
Never add AI attribution anywhere.
If blocked, stop and say exactly what is missing.
Final message under 300 words: files changed, commands run with results, open risks."""
NATIVE = "Native desktop control: use mcp__node_repl__js through functions.exec as tools.mcp__node_repl__js (discover that exact name in ALL_TOOLS if deferred). Import with const {sky} = await import('@oai/sky'); call sky.list_windows() first as native preflight. Never use browser-only cua_repl for desktop apps. If the tool, import, or native preflight fails, stop and write Status: BLOCKED with BLOCKED: native CUA unavailable in the report. Include the end-state screenshot path in the final message."


def desktop_running():
    # Native control on macOS is unverified.
    try:
        if WINDOWS:
            result = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, timeout=10)
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.restype = ctypes.c_void_p
            for row in csv.reader(result.stdout.decode(errors="replace").splitlines()):
                if not row or row[0].lower() not in ("chatgpt.exe", "codex.exe"): continue
                handle = ctypes.c_void_p(kernel.OpenProcess(0x1000, False, int(row[1])))
                if not handle: continue
                try:
                    path, size = ctypes.create_unicode_buffer(32768), ctypes.c_ulong(32768)
                    if kernel.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(size)) and re.search(
                            r"(?i)/(?:WindowsApps/OpenAI\.Codex_[^/]+/app|OpenAI/Codex(?:/app)?)/(ChatGPT|Codex)\.exe$", path.value.replace("\\", "/")):
                        return result.returncode == 0
                finally:
                    kernel.CloseHandle(handle)
            return False
        return subprocess.run(["pgrep", "-f", r"(/Codex\.app/Contents/MacOS/|/(Codex|codex-desktop)( |$))"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def desktop_lock(timeout):
    handle = os.fdopen(os.open(str(Path(tempfile.gettempdir()) / "orchestra-desktop.lock"), os.O_RDWR | os.O_CREAT, 0o666), "r+b")
    if os.fstat(handle.fileno()).st_size == 0:
        handle.write(b"\0"); handle.flush()
    deadline = time.monotonic() + timeout
    while True:
        try:
            handle.seek(0)
            if WINDOWS:
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle  # Close releases the lock; never unlink a shared lock inode.
        except OSError:
            if time.monotonic() >= deadline:
                handle.close()
                raise RuntimeError("Timed out waiting for native CUA desktop lock (another ComputerUse worker is running).")
            time.sleep(0.05)


class Worker:
    def __init__(self, command, project):
        self.job = None
        if WINDOWS:
            self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            self.kernel.CreateJobObjectW.restype = ctypes.c_void_p
            # Wrap pointer-sized handles explicitly; ctypes' default return type is a 32-bit int.
            self.job = ctypes.c_void_p(self.kernel.CreateJobObjectW(None, None))
            # JOBOBJECT_EXTENDED_LIMIT_INFORMATION, flags at byte 16 on both architectures.
            limits = ctypes.create_string_buffer(144 if ctypes.sizeof(ctypes.c_void_p) == 8 else 112)
            struct.pack_into("I", limits, 16, 0x2000)  # KILL_ON_JOB_CLOSE
            if not self.job or not self.kernel.SetInformationJobObject(self.job, 9, limits, len(limits)):
                self.close(); raise ctypes.WinError(ctypes.get_last_error())
        try:
            self.process = subprocess.Popen(command, cwd=project, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, start_new_session=not WINDOWS,
                                            creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP | 4) if WINDOWS else 0)
            if WINDOWS:
                # Start suspended: descendants cannot escape assignment by racing the runner.
                if not self.kernel.AssignProcessToJobObject(self.job, ctypes.c_void_p(int(self.process._handle))): raise ctypes.WinError(ctypes.get_last_error())
                if ctypes.WinDLL("ntdll").NtResumeProcess(ctypes.c_void_p(int(self.process._handle))) != 0:
                    raise RuntimeError("Cannot resume worker process.")
        except BaseException:
            if hasattr(self, "process"): self.process.kill(); self.process.wait()
            self.close()
            raise

    def kill(self):
        if WINDOWS:
            try:
                subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            finally:
                # Parent may already have exited; its lingering descendants remain in the job.
                if not self.kernel.TerminateJobObject(self.job, 124):
                    raise ctypes.WinError(ctypes.get_last_error())
        else:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(self.process.pid, sig)
                except ProcessLookupError:
                    pass
                if sig == signal.SIGTERM:
                    time.sleep(0.2)

    def close(self):
        if self.job:
            self.kernel.CloseHandle(self.job); self.job = None
        elif not WINDOWS and hasattr(self, "process"):
            self.kill()  # Clean up even descendants that closed all inherited pipes.


def transfer(source, target, errors):
    try:
        with source, target: shutil.copyfileobj(source, target)
    except Exception as error:
        errors.append(error)


def feed(pipe, prompt):
    try:
        with pipe: pipe.write(prompt.encode("utf-8")); pipe.flush()
    except (BrokenPipeError, OSError): pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=os.getcwd()); prompts = parser.add_mutually_exclusive_group()
    prompts.add_argument("--prompt"); prompts.add_argument("--prompt-file")
    parser.add_argument("--effort", choices=("medium", "high"), default="medium")
    parser.add_argument("--model", default="gpt-6.1-sol"); parser.add_argument("--timeout-min", type=float, default=20)
    parser.add_argument("--resume", default=""); parser.add_argument("--computer-use", action="store_true")
    args = parser.parse_args()
    if not math.isfinite(args.timeout_min) or args.timeout_min < 0.000001:
        parser.error("--timeout-min must be at least 0.000001")
    timeout = min(90, args.timeout_min) * 60; now = lambda: dt.datetime.now(dt.timezone.utc).isoformat()
    run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:4]
    record = dict(id=run_id, status="failed", thread_id=args.resume, model=args.model, effort=args.effort,
                  seconds=0, input_tokens=0, cached_input_tokens=0, output_tokens=0, exit_code=1,
                  started=now(), finished=None)
    base = worker = lock = started = None; failure, threads, errors = "", [], []
    try:
        project = Path(args.project).resolve(strict=True)
        if not project.is_dir(): raise ValueError("Project must be a directory.")
        folder = project / ".orchestra"
        (folder / "runs").mkdir(parents=True, exist_ok=True)
        if not (folder / ".gitignore").exists(): (folder / ".gitignore").write_bytes(b"*\n")
        base = str(folder / "runs" / run_id)
        for suffix in (".last.md", ".jsonl", ".err.log"): Path(base + suffix).write_bytes(b"")
        prompt = (Path(args.prompt_file).read_bytes().decode("utf-8-sig") if args.prompt_file else
                  args.prompt if args.prompt is not None else sys.stdin.buffer.read().decode("utf-8"))
        shell = ("Shell is Windows PowerShell 5.1: no `&&` or `||`. Put scripts longer than 3 lines in a file and run the file. `rg`/`findstr` exit 1 means no match."
                 if WINDOWS else "Shell is bash/zsh: use POSIX shell syntax; `rg` exit 1 means no match.")
        prompt += "\n" + shell + "\n" + GUIDANCE
        if args.computer_use:
            if not desktop_running():
                raise RuntimeError("BLOCKED: native CUA unavailable; Codex desktop app is not running.")
            lock = desktop_lock(timeout); prompt += "\n" + NATIVE
        exe = os.environ.get("ORCHESTRA_CODEX") or shutil.which("codex")
        if not exe: raise RuntimeError("Codex executable not found; install codex or set ORCHESTRA_CODEX.")
        exe = str(Path(shutil.which(exe) or exe).resolve())
        if WINDOWS and Path(exe).suffix.lower() in (".cmd", ".bat", ".ps1"):
            parent = Path(shutil.which(exe) or exe).resolve().parent
            candidates = [parent / "codex.exe"] + list((parent / "node_modules" / "@openai" / "codex").rglob("codex.exe"))
            exe = next((str(p) for p in candidates if p.is_file()), None)
            if not exe:
                raise RuntimeError("Cannot resolve the Codex shim to codex.exe in its npm package.")
        command = [exe, "exec"] + (["resume", args.resume] if args.resume else [])
        command += ["--json", "-m", args.model, "-c", 'model_reasoning_effort="' + args.effort + '"',
                    "-c", 'service_tier="default"', "-c", "tool_output_token_limit=8000", "-c", "model_auto_compact_token_limit=200000"]
        command += (["--dangerously-bypass-approvals-and-sandbox"] if args.resume else ["-s", "danger-full-access", "-C", str(project)])
        command += ["--skip-git-repo-check", "-o", base + ".last.md", "-"]
        started = time.monotonic(); worker = Worker(command, project); proc = worker.process
        for source, suffix in ((proc.stdout, ".jsonl"), (proc.stderr, ".err.log")):
            threads.append(threading.Thread(target=transfer, args=(source, open(base + suffix, "wb"), errors), daemon=True))
        threads.append(threading.Thread(target=feed, args=(proc.stdin, prompt + "\n"), daemon=True))
        for thread in threads: thread.start()
        while proc.poll() is None or any(t.is_alive() for t in threads):
            if time.monotonic() - started >= timeout:
                record["status"] = "timeout"; worker.kill()
                break
            time.sleep(0.05)
        proc.wait(timeout=5)
        record["exit_code"] = 124 if record["status"] == "timeout" else proc.returncode
        if record["status"] != "timeout" and proc.returncode == 0 and Path(base + ".last.md").read_text(encoding="utf-8").strip():
            record["status"] = "done"
    except (Exception, KeyboardInterrupt) as error:
        failure = str(error) or "Interrupted."
    finally:
        if worker:
            worker.close()
            worker.process.wait(timeout=5)
            for thread in threads: thread.join(timeout=5)
        if lock: lock.close()
        if started is not None: record["seconds"] = round(time.monotonic() - started, 1)
    if errors:
        failure = str(errors[0])
        if record["status"] == "done": record["status"] = "failed"
    if base:
        if failure:
            with open(base + ".err.log", "a", encoding="utf-8") as log: log.write(failure + "\n")
        with open(base + ".jsonl", encoding="utf-8", errors="replace") as log:
            for line in log:
                try:
                    event = json.loads(line)
                    if event.get("type") == "thread.started": record["thread_id"] = event.get("thread_id")
                    if event.get("type") == "turn.completed":
                        for key in ("input_tokens", "cached_input_tokens", "output_tokens"):
                            record[key] += int((event.get("usage") or {}).get(key, 0))
                except (ValueError, TypeError, AttributeError): continue
        record["finished"] = now(); Path(base + ".json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    cached = round(100 * record["cached_input_tokens"] / record["input_tokens"]) if record["input_tokens"] else 0
    thread_id = " ".join(str(record["thread_id"] or "").splitlines())
    print(f'[codex-run] {run_id} {record["status"]} thread={thread_id} {record["seconds"]:.1f}s in={record["input_tokens"] / 1000:.1f}k cached={cached}% out={record["output_tokens"] / 1000:.1f}k')
    if record["status"] == "done":
        with open(base + ".last.md", encoding="utf-8") as message:
            lines = [line.rstrip("\r\n") for _, line in zip(range(14), message)]
        for line in lines[:13]: print(" ".join(line.splitlines())[:200])
        if len(lines) > 13 or any(len(line) > 200 for line in lines[:13]):
            print(f"... (full: {base}.last.md)")
        return 0
    if base:
        from collections import deque
        with open(base + ".err.log", encoding="utf-8", errors="replace") as log:
            for line in deque(log, maxlen=3):
                print(" ".join(line.splitlines())[:200])
    elif failure:
        print(" ".join(failure.splitlines())[:200])
    return 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
