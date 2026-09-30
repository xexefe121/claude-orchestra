#!/usr/bin/env python3
"""Cross-platform orchestra launcher (Python 3.9+, standard library only).

The PowerShell launcher defines the state and output interfaces. Engine-specific
resolution, invocation, and event parsing live in separate methods so additional
engines and command handlers can reuse the worker lifecycle.
"""

import argparse
from contextlib import contextmanager
import datetime as dt
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Dict, Iterator, List, Optional, Tuple, Union
import uuid


MODELS = {
    "sol": "gpt-6.1-sol", "sol6": "gpt-6-sol", "astra": "gpt-6-astra",
    "luna": "gpt-6-luna", "luna56": "gpt-5.6-luna",
}
EFFORTS = ("low", "medium", "high", "xhigh", "max", "ultra")
WINDOWS_RULES = (
    "Shell is Windows PowerShell 5.1: no && or ||. Write scripts longer than 3 lines "
    "to a .py/.ps1 file and run the file; no inline here-strings. rg/findstr exit 1 "
    "means no match, not an error. Do not use wsl."
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_utf8(path: Path, value: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(value)


def read_utf8(path: Path) -> str:
    # Accept Windows-prepared briefs and old PowerShell JSON files with a BOM.
    return path.read_text(encoding="utf-8-sig")


def read_array(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    text = read_utf8(path)
    if not text.strip():
        return []
    parsed = json.loads(text)
    # Older PowerShell serializers may unwrap a singleton array.
    return parsed if isinstance(parsed, list) else [parsed]


def write_json(path: Path, value: Any) -> None:
    write_utf8(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def ensure_utf8_bom(path: Path) -> None:
    if not path.is_file():
        return
    data = path.read_bytes()
    if data.startswith((b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff", b"\x00\x00\xfe\xff")):
        return
    if any(byte > 127 for byte in data):
        path.write_bytes(b"\xef\xbb\xbf" + data)


def normalize_model(value: str) -> str:
    return MODELS.get(value.lower(), value)


def model_prefix(value: str) -> str:
    for prefix, model in MODELS.items():
        if value.lower() == model:
            return prefix
    return re.sub(r"[^A-Za-z0-9_-]", "-", value).strip("-_") or "worker"


def get_engine(value: str) -> str:
    if value.lower() in ("sonnet", "opus", "fable", "haiku") or value.lower().startswith("claude-"):
        return "claude"
    return "codex"


def test_handoff(engine: str, tokens: int, window: int, percent: int) -> bool:
    if engine == "claude":
        return tokens >= 200000 or (window > 0 and tokens >= 0.7 * window)
    return percent >= 70


def pid_alive(pid: Any) -> bool:
    if not pid:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenProcess(0x1000, False, int(pid))
        if not handle:
            return ctypes.get_last_error() == 5  # Access denied still proves existence.
        try:
            code = wintypes.DWORD()
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (ProcessLookupError, ValueError, OverflowError):
        return False


@contextmanager
def state_lock(state: Path, timeout: float = 30.0) -> Iterator[None]:
    """Lock state files, also sharing the legacy launcher's mutex on Windows."""
    deadline = time.monotonic() + timeout
    mutex = None
    kernel = None
    held = False
    stream = None
    file_held = False
    try:
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            import msvcrt
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.CreateMutexW.argtypes = (ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR)
            kernel.CreateMutexW.restype = wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
            kernel.WaitForSingleObject.restype = wintypes.DWORD
            kernel.ReleaseMutex.argtypes = (wintypes.HANDLE,)
            kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
            key = hashlib.sha1(str(state).lower().encode("utf-8")).hexdigest()
            mutex = kernel.CreateMutexW(None, False, "Global\\orchestra-" + key)
            if not mutex:
                raise ctypes.WinError(ctypes.get_last_error())
            held = kernel.WaitForSingleObject(mutex, int(timeout * 1000)) in (0, 0x80)
            if not held:
                raise RuntimeError("Timed out waiting for workers.json lock.")
        else:
            import fcntl
        stream = (state / ".state.lock").open("a+b")
        if os.name == "nt":
            stream.seek(0, os.SEEK_END)
            if stream.tell() == 0:
                stream.write(b"\0")
                stream.flush()
        while True:
            try:
                if os.name == "nt":
                    stream.seek(0)
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                file_held = True
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Timed out waiting for workers.json lock.")
                time.sleep(0.05)
        yield
    finally:
        try:
            if stream is not None:
                try:
                    if file_held:
                        if os.name == "nt":
                            stream.seek(0)
                            msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
                        else:
                            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
                finally:
                    stream.close()
        finally:
            if mutex:
                if held:
                    kernel.ReleaseMutex(mutex)
                kernel.CloseHandle(mutex)


def executable_command(path: str, arguments: List[str]) -> Union[List[str], str]:
    suffix = Path(path).suffix.lower()
    if suffix == ".py":
        return [sys.executable, path] + arguments
    if os.name == "nt" and suffix == ".ps1":
        return [shutil.which("powershell.exe") or "powershell.exe", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-File", path] + arguments
    if os.name == "nt" and suffix in (".cmd", ".bat"):
        # cmd needs an extra outer pair of quotes for executable paths with spaces.
        command = subprocess.list2cmdline([path] + arguments)
        # Pass a raw command line: Popen's list quoting would escape the inner
        # quotes for the C runtime, whereas cmd.exe uses its own quote parser.
        shell = subprocess.list2cmdline([os.environ.get("COMSPEC", "cmd.exe")])
        return shell + ' /d /s /c "' + command + '"'
    return [path] + arguments


@dataclass
class CliInfo:
    path: str
    version: Tuple[int, int, int]
    version_text: str
    release: bool
    native: bool
    family: str
    cache: Path
    stamp: int
    models: Optional[List[str]] = None
    model_error: Optional[str] = None


@dataclass
class Selection:
    info: CliInfo
    model: str
    rule: str
    fallback: Optional[str] = None


def desktop_candidates() -> List[Path]:
    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA")
        return list((Path(local) / "OpenAI/Codex/bin").glob("*/codex.exe")) if local else []
    if sys.platform == "darwin":
        candidates = []
        for app in (Path("/Applications/Codex.app"), Path.home() / "Applications/Codex.app"):
            for relative in ("Contents/MacOS/codex", "Contents/Resources/codex",
                             "Contents/Resources/bin/codex", "Contents/Resources/app/bin/codex"):
                candidate = app / relative
                if candidate.is_file():
                    candidates.append(candidate)
        return candidates
    return []


def cli_family(path: Path) -> str:
    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA")
        if local:
            root = str((Path(local) / "OpenAI/Codex/bin").absolute()).lower() + os.sep
            if str(path.absolute()).lower().startswith(root):
                return "desktop"
    elif sys.platform == "darwin":
        for app in (Path("/Applications/Codex.app"), Path.home() / "Applications/Codex.app"):
            if app in path.absolute().parents:
                return "desktop"
    return "path"


class CodexResolver:
    def __init__(self) -> None:
        self.infos: Dict[str, CliInfo] = {}

    def get_info(self, path: str) -> CliInfo:
        path = str(Path(path).absolute())
        if path in self.infos:
            return self.infos[path]
        # .NET UTC ticks keep cache keys compatible with the PowerShell launcher.
        stamp = Path(path).stat().st_mtime_ns // 100 + 621355968000000000
        key = hashlib.sha1((path + "|" + str(stamp)).encode("utf-8")).hexdigest()
        cache = Path(tempfile.gettempdir()) / ("orchestra-models-" + key + ".json")
        saved = None
        try:
            if time.time() - cache.stat().st_mtime < 24 * 3600:
                candidate = json.loads(read_utf8(cache))
                if (candidate.get("path") == path and candidate.get("stamp") == stamp
                        and candidate.get("version") and candidate.get("models") is not None):
                    saved = candidate
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        raw = ""
        if saved:
            raw = "codex-cli " + saved["version"]
        else:
            try:
                probe = subprocess.run(executable_command(path, ["--version"]),
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       timeout=30, encoding="utf-8", errors="replace")
                raw = probe.stdout.splitlines()[0] if probe.stdout else ""
            except (OSError, subprocess.SubprocessError):
                pass
        match = re.match(r"^codex-cli\s+(\d+)\.(\d+)\.(\d+)(-\S+)?", raw)
        version = tuple(int(match[i]) for i in (1, 2, 3)) if match else (0, 0, 0)
        text = ".".join(str(n) for n in version) + (match[4] or "") if match else "unknown"
        info = CliInfo(path, version, text, bool(match and not match[4]),
                       Path(path).suffix.lower() == ".exe", cli_family(Path(path)), cache, stamp,
                       list(saved["models"]) if saved else None)
        self.infos[path] = info
        return info

    def get_models(self, info: CliInfo) -> List[str]:
        if info.models is not None:
            return info.models
        if info.model_error:
            return []
        try:
            probe = subprocess.run(executable_command(info.path, ["debug", "models"]),
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   timeout=30, encoding="utf-8", errors="replace")
            if probe.returncode:
                raise RuntimeError("debug models exited " + str(probe.returncode))
            data = json.loads(probe.stdout)
            if data.get("models") is None:
                raise RuntimeError("debug models returned no models array")
            info.models = [entry["slug"] for entry in data["models"] if entry.get("slug")]
            temporary = info.cache.with_name(info.cache.name + "." + uuid.uuid4().hex + ".tmp")
            try:
                write_json(temporary, {"path": info.path, "stamp": info.stamp,
                                       "version": info.version_text, "models": info.models})
                os.replace(str(temporary), str(info.cache))
            except OSError:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass
            return info.models
        except (OSError, ValueError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
            info.model_error = str(error)
            return []

    def candidates(self, include_path: bool) -> List[CliInfo]:
        paths = desktop_candidates()
        on_path = shutil.which("codex") if include_path or not paths else None
        if on_path:
            shim = Path(on_path)
            real = shim.parent / "codex.exe"
            if os.name == "nt" and not real.is_file():
                package = shim.parent / "node_modules/@openai/codex"
                real = next(package.rglob("codex.exe"), shim)
            paths.append(real if os.name == "nt" and real.is_file() else shim)
        infos = [self.get_info(str(path)) for path in dict.fromkeys(paths)]
        infos = [info for info in infos if info.version_text != "unknown"]
        if not infos:
            raise RuntimeError("Codex CLI not found. Set ORCHESTRA_CODEX or install codex.")
        return sorted(infos, key=lambda info: (info.version, info.release, info.native), reverse=True)

    def resolve(self, model: str, rule: str = "auto", needs_computer: bool = False,
                previous: Optional[Dict[str, Any]] = None) -> Selection:
        previous = previous or {}
        rule = previous.get("cli_rule") or rule
        override = os.environ.get("ORCHESTRA_CODEX")
        selected = None
        candidates = []
        if override:
            if not Path(override).is_file():
                raise RuntimeError("ORCHESTRA_CODEX not found: " + override)
            selected = self.get_info(override)
        elif previous.get("cli_path") and Path(previous["cli_path"]).is_file():
            selected = self.get_info(previous["cli_path"])
        else:
            candidates = self.candidates(rule != "desktop" or previous.get("cli_family") == "path")
            if previous.get("cli_family"):
                candidates = [info for info in candidates if info.family == previous["cli_family"]]
            if not candidates:
                raise RuntimeError("No Codex CLI found in the required session family.")
            if rule != "auto":
                selected = candidates[0]
            else:
                preferred = "desktop" if needs_computer else "path"
                ordered = [i for i in candidates if i.family == preferred] + [i for i in candidates if i.family != preferred]
                selected = next((info for info in ordered if model in self.get_models(info)), None)
        if selected is None:
            checked = ", ".join("{} ({}{})".format(i.path, i.version_text,
                                "; " + i.model_error if i.model_error else "") for i in candidates)
            raise RuntimeError("No Codex CLI lists model '{}'. CLIs checked: {}".format(model, checked))
        if previous and not override and rule == "auto" and model not in self.get_models(selected):
            raise RuntimeError("Saved session CLI {} ({}) does not list model '{}'. Resume must reuse its CLI family.".format(
                selected.path, selected.version_text, model))
        return Selection(selected, model, rule)


class WindowsJob:
    """Own descendants even after their parent exits, including detached children."""
    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes
        self.ctypes = ctypes
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)

        class BasicLimit(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                        ("flags", wintypes.DWORD), ("min_working_set", ctypes.c_size_t),
                        ("max_working_set", ctypes.c_size_t), ("active_processes", wintypes.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
                        ("scheduling", wintypes.DWORD)]

        class IoCounters(ctypes.Structure):
            _fields_ = [(field, ctypes.c_ulonglong) for field in (
                "read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

        class ExtendedLimit(ctypes.Structure):
            _fields_ = [("basic", BasicLimit), ("io", IoCounters),
                        ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                        ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t)]

        self.kernel.CreateJobObjectW.argtypes = (ctypes.c_void_p, wintypes.LPCWSTR)
        self.kernel.CreateJobObjectW.restype = wintypes.HANDLE
        self.kernel.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD)
        self.kernel.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        self.kernel.TerminateJobObject.argtypes = (wintypes.HANDLE, wintypes.UINT)
        self.kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimit()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def attach_and_resume(self, process: subprocess.Popen) -> None:
        if not self.kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise self.ctypes.WinError(self.ctypes.get_last_error())
        # Popen closes the primary thread handle. Resume through the process
        # handle only after job assignment, before any child can escape ownership.
        ntdll = self.ctypes.WinDLL("ntdll")
        ntdll.NtResumeProcess.argtypes = (self.ctypes.c_void_p,)
        ntdll.NtResumeProcess.restype = self.ctypes.c_long
        status = ntdll.NtResumeProcess(int(process._handle))
        if status < 0:
            raise OSError("NtResumeProcess failed: {}".format(status))

    def kill(self) -> None:
        if not self.kernel.TerminateJobObject(self.handle, 124):
            raise self.ctypes.WinError(self.ctypes.get_last_error())

    def close(self) -> None:
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def kill_posix_group(process: subprocess.Popen, grace: float = 1.0) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    # The parent may already be gone. Waiting for it is insufficient for its group.
    until = time.monotonic() + grace
    while time.monotonic() < until:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


@dataclass
class ProcessResult:
    exit_code: int
    timed_out: bool = False


def invoke_process(exe: str, arguments: List[str], prompt: str, project: Path,
                   stdout: Path, stderr: Path, timeout_min: float = 90,
                   drain_seconds: float = 30) -> ProcessResult:
    """Pump all three pipes concurrently; bound inherited-pipe drainage."""
    process = None
    job = None
    threads: List[threading.Thread] = []
    errors: List[BaseException] = []
    started = time.monotonic()
    parent_exited = None
    expired = False
    try:
        kwargs: Dict[str, Any] = {"cwd": str(project), "stdin": subprocess.PIPE,
                                  "stdout": subprocess.PIPE, "stderr": subprocess.PIPE}
        if os.name == "nt":
            job = WindowsJob()
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW | 0x4
        else:
            kwargs["start_new_session"] = True
        process = subprocess.Popen(executable_command(exe, arguments), **kwargs)
        if job:
            job.attach_and_resume(process)

        def pump(source: Any, target: Path) -> None:
            try:
                with target.open("wb") as output:
                    while True:
                        chunk = source.read1(65536) if hasattr(source, "read1") else source.read(65536)
                        if not chunk:
                            break
                        output.write(chunk)
                        output.flush()
            except (OSError, ValueError) as error:
                errors.append(error)
            finally:
                source.close()

        def send_prompt() -> None:
            try:
                process.stdin.write((prompt + "\n").encode("utf-8"))
                process.stdin.flush()
            except (OSError, ValueError):
                pass  # A crashing CLI can close stdin before delivery.
            finally:
                process.stdin.close()

        for action, args in ((pump, (process.stdout, stdout)), (pump, (process.stderr, stderr)), (send_prompt, ())):
            thread = threading.Thread(target=action, args=args, daemon=True)
            thread.start()
            threads.append(thread)
        while True:
            now = time.monotonic()
            if process.poll() is not None and parent_exited is None:
                parent_exited = now
            if parent_exited is not None and not any(t.is_alive() for t in threads):
                break
            expired = timeout_min > 0 and now - started >= timeout_min * 60
            drain_capped = parent_exited is not None and now - parent_exited >= drain_seconds
            if expired or drain_capped:
                if job:
                    job.kill()
                else:
                    kill_posix_group(process)
                process.wait(timeout=5)
                for thread in threads:
                    thread.join(timeout=5)
                if any(t.is_alive() for t in threads):
                    raise RuntimeError("Worker streams did not close after process termination.")
                break
            time.sleep(0.05)
        if errors:
            raise errors[0]
        code = process.wait()
        # PowerShell exposes native Windows crash codes as signed Int32 values.
        if os.name == "nt" and code > 2147483647:
            code -= 4294967296
        return ProcessResult(124 if expired else code, expired)
    finally:
        if process is not None:
            if job:
                job.close()
            else:
                kill_posix_group(process)
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for thread in threads:
                thread.join(timeout=5)
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe and not pipe.closed:
                    pipe.close()
        elif job:
            job.close()


def run_events(path: Path) -> Iterator[Dict[str, Any]]:
    if not path.is_file():
        return
    with path.open(encoding="utf-8-sig", errors="replace") as stream:
        for line in stream:
            try:
                value = json.loads(line)
                if isinstance(value, dict):
                    yield value
            except ValueError:
                pass


def get_context(events: List[Dict[str, Any]], session_id: Optional[str],
                sessions: Optional[Path] = None) -> Dict[str, Any]:
    result = {"tokens": 0, "window": 0, "source": "approx"}
    if session_id:
        sessions = sessions if sessions is not None else Path.home() / ".codex/sessions"
        # Session IDs are untrusted telemetry; do not interpret glob metacharacters.
        files = [p for p in sessions.rglob("rollout-*.jsonl") if p.name.endswith("-" + session_id + ".jsonl")]
        if files:
            latest = max(files, key=lambda path: path.stat().st_mtime_ns)
            with latest.open(encoding="utf-8-sig", errors="replace") as stream:
                for line in stream:
                    if '"token_count"' not in line:
                        continue
                    try:
                        event = json.loads(line)
                        payload = event.get("payload", {})
                        info = payload.get("info") or {}
                        usage = info.get("last_token_usage") or {}
                        if (event.get("type") == "event_msg" and payload.get("type") == "token_count"
                                and usage.get("input_tokens") is not None):
                            result = {"tokens": int(usage["input_tokens"]),
                                      "window": int(info.get("model_context_window") or 0), "source": "rollout"}
                    except (ValueError, TypeError, AttributeError):
                        pass
    if result["source"] == "approx":
        for event in events:
            if event.get("type") == "turn.completed" and event.get("usage"):
                usage = event["usage"]
                result["tokens"] = int(usage.get("input_tokens") or 0)
                if usage.get("model_context_window"):
                    result["window"] = int(usage["model_context_window"])
    return result


def crash_reason(exit_code: int, error_log: Path) -> Optional[str]:
    if 0 <= exit_code <= 2147483648 or not error_log.is_file():
        return None
    from collections import deque
    with error_log.open(encoding="utf-8-sig", errors="replace") as stream:
        tail = "".join(deque(stream, maxlen=20))
    if re.search(r"memory allocation.*failed|failed to allocate|allocation.*fail|out of memory", tail, re.I):
        return "alloc-failure"
    if re.search(r"panic|panicked", tail, re.I):
        return "panic"
    return None


def report_text(path: Path) -> str:
    try:
        return read_utf8(path)
    except OSError:
        return ""


def report_field(text: str, field: str) -> str:
    match = re.search(r"^" + re.escape(field) + r":[ \t]*([^\r\n]+)", text, re.M | re.I)
    return match[1].strip() if match else ""


def report_section(text: str, section: str) -> List[str]:
    match = re.search(r"^#{1,6}\s+" + re.escape(section) + r"\s*\r?$", text, re.M | re.I)
    if not match:
        return []
    lines = []
    for line in text[match.end():].splitlines():
        if re.match(r"^#{1,6}\s+", line):
            break
        if line.strip():
            lines.append(line.strip())
    return lines


def report_digest(path: Path, reviewer: bool = False) -> List[str]:
    text = report_text(path)
    lines = []
    if reviewer:
        fields = [field + ": " + report_field(text, field) for field in ("Verdict", "Blocking") if report_field(text, field)]
        if fields:
            lines.append(" ".join(fields))
        lines.extend([line for line in report_section(text, "Issues") if re.match(r"^[-*+]\s+", line)][:5])
    else:
        status = report_field(text, "Status")
        if status:
            lines.append("Status: " + status)
        lines.extend(report_section(text, "Summary")[:3])
        lines.extend([line for line in report_section(text, "Open issues and risks") if re.match(r"^[-*+]\s+", line)][:5])
    values = ["  | " + line for line in lines[:10]]
    return [value[:197] + "..." if len(value) > 200 else value for value in values]


def board_date(value: Any) -> Optional[dt.datetime]:
    if not value:
        return None
    try:
        date = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return date.astimezone(dt.timezone.utc)
    except (ValueError, TypeError):
        return None


def file_date(path: Path, creation: bool = False) -> dt.datetime:
    stat = path.stat()
    timestamp = stat.st_mtime
    if creation:
        # POSIX ctime describes metadata changes, not creation. macOS has birthtime.
        timestamp = stat.st_ctime if os.name == "nt" else getattr(stat, "st_birthtime", stat.st_mtime)
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc)


@dataclass
class WorkerRun:
    line: str
    status: str
    report: Path
    report_fresh: bool


class Orchestra:
    def __init__(self, project: Path, cli: str = "auto", timeout_min: float = 90,
                 force: bool = False, no_digest: bool = False) -> None:
        self.project = project.absolute()
        self.state = self.project / ".orchestra"
        self.workers_file = self.state / "workers.json"
        self.runs_file = self.state / "runs.json"
        self.cli = cli
        self.timeout_min = timeout_min
        self.force = force
        self.no_digest = no_digest
        self.resolver = CodexResolver()

    def lock(self) -> Any:
        return state_lock(self.state)

    def read_workers(self) -> List[Dict[str, Any]]:
        return read_array(self.workers_file)

    def save_workers(self, workers: List[Dict[str, Any]]) -> None:
        write_json(self.workers_file, workers)

    def read_task_runs(self) -> List[Dict[str, Any]]:
        return read_array(self.runs_file)

    def save_task_run(self, run: Dict[str, Any]) -> None:
        # Callers hold the state lock: latest record for each task survives resumes.
        records = [record for record in self.read_task_runs() if record["task"] != run["task"]]
        write_json(self.runs_file, records + [run])

    def ensure_state(self, notes: bool = False) -> None:
        for path in (self.state, self.state / "tasks", self.state / "reports", self.state / "runs"):
            path.mkdir(parents=True, exist_ok=True)
        templates = Path(__file__).absolute().parent.parent / "templates"
        with self.lock():
            for name in ("context.md", "progress.md", "WORKER.md"):
                target = self.state / name
                source = templates / name
                if not target.is_file():
                    if source.is_file():
                        write_utf8(target, read_utf8(source))
                    elif notes:
                        print("Template missing; skipped " + name)
            if not self.workers_file.is_file():
                write_utf8(self.workers_file, "[]\n")
            write_utf8(self.state / ".gitignore", "runs/\n")

    def status(self) -> None:
        if not self.workers_file.is_file():
            return
        with self.lock():
            workers = self.read_workers()
        for worker in workers:
            print("{} {} {} {} {}% {}".format(*(worker.get(key) if worker.get(key) is not None else "" for key in (
                "name", "model", "effort", "status", "context_pct", "current_task"))))

    def update_board(self) -> None:
        with self.lock():
            workers = self.read_workers()
            records = {record["task"]: record for record in self.read_task_runs()}
            for worker in workers:
                ids = list(worker.get("tasks") or []) + [worker.get("current_task")]
                for task in dict.fromkeys(ids):
                    if not task or task in records:
                        continue
                    current = task == worker.get("current_task")
                    records[task] = {"task": task, "worker": worker.get("name"), "model": worker.get("model"),
                                     "effort": worker.get("effort"), "status": worker.get("status") if current else "unknown",
                                     "started": worker.get("started") if current else None,
                                     "finished": worker.get("finished") if current else None,
                                     "context_pct": worker.get("context_pct") if current else None}
            for report in (self.state / "reports").glob("*.md"):
                records.setdefault(report.stem, {"task": report.stem, "worker": "-", "model": "-", "effort": "-",
                                                  "status": "unknown", "started": None, "finished": None, "context_pct": None})
            for log in (self.state / "runs").glob("*.jsonl"):
                match = re.match(r"^(.*)\.([^.]+)$", log.stem)
                if not match:
                    continue
                task, name = match.groups()
                if task not in records:
                    records[task] = {"task": task, "worker": name, "model": "-", "effort": "-", "status": "unknown",
                                     "started": file_date(log, True).isoformat(), "finished": file_date(log).isoformat(), "context_pct": None}
                elif records[task].get("worker") == "-":
                    records[task]["worker"] = name
            rows = []
            totals: Dict[str, int] = {}
            now = dt.datetime.now(dt.timezone.utc)
            for task, record in records.items():
                status = record.get("status") or ""
                started = board_date(record.get("started"))
                finished = board_date(record.get("finished"))
                verdict = ""
                report = self.state / "reports" / (task + ".md")
                if report.is_file():
                    text = report_text(report)
                    status = report_field(text, "Status") or status
                    verdict = report_field(text, "Verdict")
                    if not finished and record.get("status") != "running":
                        finished = file_date(report)
                review = self.state / "reports" / (task + "-review.md")
                if review.is_file():
                    verdict = report_field(report_text(review), "Verdict")
                log = self.state / "runs" / (task + "." + str(record.get("worker")) + ".jsonl")
                if log.is_file():
                    started = started or file_date(log, True)
                    if not finished and record.get("status") != "running":
                        finished = file_date(log)
                minutes = "-"
                sort = dt.datetime.min.replace(tzinfo=dt.timezone.utc)
                if started:
                    minutes = "{:.1f}".format(round(max(0, ((finished or now) - started).total_seconds() / 60), 1))
                    sort = started
                if finished:
                    sort = finished
                pct = str(record["context_pct"]) if record.get("context_pct") is not None else "-"
                cells = [task, record.get("worker") or "", "{} {}".format(record.get("model") or "", record.get("effort") or ""),
                         status, verdict, pct, minutes, finished.astimezone().strftime("%Y-%m-%d %H:%M:%S") if finished else "-"]
                rows.append((sort, task, cells))
                totals[status] = totals.get(status, 0) + 1
            lines = ["# Task board", "", "| task | worker | model+effort | status | review verdict | ctx % | minutes | finished (local time) |",
                     "| --- | --- | --- | --- | --- | --- | --- | --- |"]
            # Stable sorting preserves task ascending for equal timestamps.
            rows.sort(key=lambda row: row[1].lower())
            rows.sort(key=lambda row: row[0], reverse=True)
            for _, _, cells in rows:
                lines.append("| " + " | ".join(str(cell).replace("|", "\\|").replace("\r", " ").replace("\n", " ") for cell in cells) + " |")
            running = []
            for worker in workers:
                if worker.get("status") != "running":
                    continue
                if worker.get("launcher_pid") and not pid_alive(worker["launcher_pid"]):
                    continue
                start = board_date(worker.get("started"))
                elapsed = "{:.1f}".format(round((now - start).total_seconds() / 60, 1)) if start else "?"
                running.append("{} ({}m)".format(worker["name"], elapsed))
            lines.extend(["", "Totals: " + ", ".join("{}={}".format(key, totals[key]) for key in sorted(totals, key=str.lower))
                          + "; running workers: " + (", ".join(running) if running else "none")])
            write_utf8(self.state / "board.md", "\n".join(lines) + "\n")

    def resolve_engine(self, model: str, previous: Optional[Dict[str, Any]]) -> Selection:
        """Extension point for Claude resolution and native computer-use preflight."""
        if get_engine(model) != "codex":
            raise RuntimeError("Claude engine is not implemented in this launcher yet.")
        if previous and previous.get("computer_use"):
            raise RuntimeError("Native computer use is not implemented in this launcher yet.")
        return self.resolver.resolve(model, self.cli, False, previous)

    def worker_prompt(self, task: str, name: str, model: str, effort: str, resume: bool) -> str:
        if resume:
            prompt = "You are still GPT worker {}. New brief: .orchestra/tasks/{}.md. Re-read .orchestra/context.md if it changed. Same rules. Report to .orchestra/reports/{}.md.".format(name, task, task)
        else:
            prompt = "You are GPT worker {} (model {}, effort {}). Before anything else read .orchestra/WORKER.md (your rules), .orchestra/context.md (project context), then your brief .orchestra/tasks/{}.md. Do the task. When finished, write your report to .orchestra/reports/{}.md in the format WORKER.md specifies. Your final message: one line status, then the report path.".format(name, model, effort, task, task)
        if os.name == "nt":
            prompt += "\n" + WINDOWS_RULES
        return prompt

    def engine_arguments(self, model: str, effort: str, session_id: Optional[str],
                         resume: bool, last: Path) -> List[str]:
        setting = 'model_reasoning_effort="' + effort + '"'
        if resume:
            return ["exec", "resume", session_id, "--json", "-m", model, "-c", setting,
                    "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "-o", str(last), "-"]
        return ["exec", "--json", "-m", model, "-c", setting, "-s", "danger-full-access",
                "--skip-git-repo-check", "-C", str(self.project), "-o", str(last), "-"]

    def parse_engine_result(self, events: List[Dict[str, Any]], session_id: Optional[str],
                            model: str, last: Path, exit_code: int) -> Tuple[Optional[str], str, Dict[str, Any], int]:
        for event in events:
            if event.get("type") == "thread.started" and event.get("thread_id"):
                session_id = str(event["thread_id"])
                break
        try:
            context = get_context(events, session_id)
        except (OSError, ValueError, TypeError, AttributeError):
            context = {"tokens": 0, "window": 0, "source": "approx"}
        return session_id, model, context, exit_code

    def run_worker(self, task: str, model: str = "sol", effort: str = "high", name: Optional[str] = None,
                   resume: bool = False, model_specified: bool = False, effort_specified: bool = False,
                   name_prefix: Optional[str] = None) -> WorkerRun:
        if not task:
            raise RuntimeError("run requires --task <id>.")
        if task in (".", "..") or "/" in task or "\\" in task or (os.name == "nt" and ":" in task):
            raise RuntimeError("Task must be a file name without a path.")
        if name and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name):
            raise RuntimeError("Name may contain only letters, digits, underscores, and hyphens.")
        brief = self.state / "tasks" / (task + ".md")
        if not brief.is_file():
            raise RuntimeError("Task brief missing: " + str(brief))
        if resume and not name:
            raise RuntimeError("--resume requires --name of an existing worker.")
        self.ensure_state()
        model = normalize_model(model)
        started = utc_now()
        session_id = None
        with self.lock():
            if os.name == "nt":
                for path in (brief, self.state / "context.md", self.state / "WORKER.md"):
                    ensure_utf8_bom(path)
            workers = self.read_workers()
            if not name:
                prefix = name_prefix or model_prefix(model)
                number = 1
                names = {worker["name"].lower() for worker in workers}
                while "{}-{:02d}".format(prefix, number).lower() in names:
                    number += 1
                name = "{}-{:02d}".format(prefix, number)
            existing = next((worker for worker in workers if worker["name"].lower() == name.lower()), None)
            if resume and (not existing or not existing.get("session_id")):
                raise RuntimeError("No saved session for worker " + name + ".")
            if existing and existing.get("status") == "running":
                if pid_alive(existing.get("launcher_pid")):
                    raise RuntimeError("Worker " + name + " is already running.")
                existing["status"] = "failed"
            if existing and not resume:
                raise RuntimeError("Worker " + name + " already exists; use --resume.")
            previous = existing if resume else None
            if previous:
                if not model_specified:
                    model = previous.get("requested_model") if previous.get("model_fallback") and previous.get("requested_model") else previous["model"]
                if not effort_specified:
                    effort = previous["effort"]
                if (previous.get("engine") or "codex") != get_engine(model):
                    raise RuntimeError("Resume cannot change worker engine.")
                engine = previous.get("engine") or get_engine(previous["model"])
                if not self.force and test_handoff(engine, previous.get("context_tokens") or 0,
                                                  previous.get("context_window") or 0, previous.get("context_pct") or 0):
                    raise RuntimeError("Worker {} is at its handoff threshold ({}%, {} tokens). Start a fresh worker, or use --force with --resume.".format(
                        name, previous.get("context_pct"), previous.get("context_tokens")))
            requested_model = model
            selection = self.resolve_engine(model, previous)
            model = selection.model
            engine = get_engine(model)
            if previous:
                worker = previous
                old_task = worker.get("current_task")
                if old_task and old_task != task and not any(r["task"] == old_task for r in self.read_task_runs()):
                    self.save_task_run({"task": old_task, "worker": worker["name"], "model": worker["model"], "effort": worker["effort"],
                                        "status": worker["status"], "started": worker.get("started"), "finished": worker.get("finished"),
                                        "context_pct": worker.get("context_pct")})
                session_id = worker["session_id"]
                worker.update(model=model, effort=effort, status="running", current_task=task,
                              tasks=list(worker.get("tasks") or []) + [task], started=started,
                              finished=None, exit_code=None, launcher_pid=os.getpid())
            else:
                worker = {"name": name, "model": model, "effort": effort, "session_id": None, "status": "running",
                          "current_task": task, "tasks": [task], "context_tokens": 0, "context_window": 0,
                          "context_pct": 0, "context_source": "approx", "exit_code": None, "started": started,
                          "finished": None, "report": None, "launcher_pid": os.getpid()}
                workers.append(worker)
            worker.update(cli_path=selection.info.path, cli_version=selection.info.version_text,
                          cli_family=selection.info.family, cli_rule=selection.rule, engine=engine,
                          profile=None, resolved_effort=effort, resolved_model=model, computer_use=False,
                          requested_model=requested_model, model_fallback=selection.fallback)
            self.save_workers(workers)
            self.save_task_run({"task": task, "worker": name, "model": model, "effort": effort, "status": "running",
                                "started": started, "finished": None, "context_pct": 0})
        base = task + "." + name
        jsonl = self.state / "runs" / (base + ".jsonl")
        stderr = self.state / "runs" / (base + ".err.log")
        last = self.state / "runs" / (base + ".last.md")
        relative = ".orchestra/reports/" + task + ".md"
        report = self.state / "reports" / (task + ".md")
        before = report.stat().st_mtime_ns if report.is_file() else None
        prompt = self.worker_prompt(task, name, model, effort, resume)
        arguments = self.engine_arguments(model, effort, session_id, resume, last)
        result = ProcessResult(-1)
        try:
            result = invoke_process(selection.info.path, arguments, prompt, self.project, jsonl, stderr, self.timeout_min)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            write_utf8(stderr, str(error) + "\n")
        events = list(run_events(jsonl))
        session_id, resolved_model, context, exit_code = self.parse_engine_result(events, session_id, model, last, result.exit_code)
        pct = int(round(100.0 * context["tokens"] / context["window"])) if context["window"] > 0 else 0
        fresh = report.is_file() and (before is None or report.stat().st_mtime_ns > before)
        status = "done" if exit_code == 0 and fresh else "failed"
        if result.timed_out:
            status = "timeout"
        finished = utc_now()
        with self.lock():
            workers = self.read_workers()
            worker = next(worker for worker in workers if worker["name"].lower() == name.lower())
            worker.update(session_id=session_id, resolved_model=resolved_model, status=status, context_tokens=context["tokens"],
                          context_window=context["window"], context_pct=pct, context_source=context["source"],
                          exit_code=exit_code, finished=finished, report=relative if report.is_file() else None)
            self.save_workers(workers)
            self.save_task_run({"task": task, "worker": name, "model": model, "effort": effort, "status": status,
                                "started": started, "finished": finished, "context_pct": pct})
        line = "[orchestra] {} {} {} exit={} ctx={}k/{}k ({}%) report={}".format(
            name, task, status, exit_code, round(context["tokens"] / 1000.0), round(context["window"] / 1000.0),
            pct, relative if report.is_file() else "MISSING")
        if test_handoff(engine, context["tokens"], context["window"], pct):
            line += " HANDOFF-RECOMMENDED"
        if selection.fallback:
            line += " model-fallback=" + selection.fallback
        if engine == "codex" and not result.timed_out:
            reason = crash_reason(exit_code, stderr)
            if reason:
                line += " crash=" + reason
        return WorkerRun(line, status, report, fresh)

    def emit_run(self, run: WorkerRun, reviewer: bool = False) -> None:
        print(run.line)
        if run.report_fresh and not self.no_digest:
            for line in report_digest(run.report, reviewer):
                print(line)


def nonnegative_int(value: str) -> int:
    number = int(value)
    if number < 0 or number > 2147483647:
        raise argparse.ArgumentTypeError("must be an integer between 0 and 2147483647")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    # Additional command handlers (such as batch) can reuse these shared options.
    for command in ("init", "run", "status", "board"):
        child = commands.add_parser(command)
        child.add_argument("--project", default=os.getcwd())
        child.add_argument("--task")
        child.add_argument("--model", default=None)
        child.add_argument("--effort", choices=EFFORTS, default=None)
        child.add_argument("--name")
        child.add_argument("--resume", action="store_true")
        child.add_argument("--force", action="store_true")
        child.add_argument("--timeout-min", type=nonnegative_int, default=90)
        child.add_argument("--no-digest", action="store_true")
        child.add_argument("--cli", choices=("auto", "desktop", "newest"), default="auto")
    return parser


def dispatch(args: argparse.Namespace) -> None:
    launcher = Orchestra(Path(args.project), args.cli, args.timeout_min, args.force, args.no_digest)
    if args.command == "init":
        launcher.ensure_state(True)
    elif args.command == "status":
        launcher.status()
    elif args.command == "board":
        launcher.ensure_state()
        launcher.update_board()
    elif args.command == "run":
        try:
            run = launcher.run_worker(args.task, args.model or "sol", args.effort or "high", args.name,
                                      args.resume, args.model is not None, args.effort is not None)
            launcher.emit_run(run)
        finally:
            if launcher.state.is_dir():
                launcher.update_board()


def main(argv: Optional[List[str]] = None) -> int:
    # Terminal pipes on Windows otherwise inherit the local ANSI code page.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    args = build_parser().parse_args(argv)
    try:
        dispatch(args)
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
