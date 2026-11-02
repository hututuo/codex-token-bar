"""Owned synthetic fixture roots and durable, non-following failure evidence.

The launchers create every root themselves. This module never accepts an
existing application directory as a fixture, never follows archive symlinks or
Windows reparse points, and keeps each attempt separate from previous results.
"""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import uuid
import zipfile

OVERRIDES = ("CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR", "CODEX_TOKEN_BAR_TAURI_CACHE_DIR",
    "CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", "CODEX_TOKEN_BAR_CACHE_BASE_DIR", "CODEX_TOKEN_BAR_TAURI_USAGE_CACHE_DIR")


def fixture_temporary_base() -> Path:
    """Choose a writable external temp directory without trusting runner layout.

    Linux and macOS Actions runners may put RUNNER_TEMP inside their home.
    Resolve candidates before checking; an explicit unsafe override is an error,
    while the normal search can fall back to the system temporary directory.
    The root creator still independently checks ownership and home isolation.
    """
    explicit = os.environ.get("TOKENBAR_FIXTURE_TEMP_BASE")
    system_temp = Path(os.environ.get("SystemRoot", "C:/Windows")) / "Temp" if os.name == "nt" else Path("/tmp")
    candidates = [Path(explicit)] if explicit else [
        Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())),
        Path(tempfile.gettempdir()), system_temp,
    ]
    home = Path.home().resolve()
    for candidate in candidates:
        try:
            base = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if (base.is_dir() and not base.is_relative_to(home)
                and not home.is_relative_to(base) and os.access(base, os.W_OK | os.X_OK)):
            return base
    raise ValueError("No writable external temporary directory; refusing user home")


def native_path(path: Path | str, *, windows: bool | None = None) -> str:
    text = str(path)
    if not (os.name == "nt" if windows is None else windows) or text.startswith("\\\\?\\"):
        return text
    return "\\\\?\\UNC\\" + text[2:] if text.startswith("\\\\") else "\\\\?\\" + text


def _link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def _identity(info: os.stat_result) -> tuple:
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def _cross_api_identity(info: os.stat_result, *, windows: bool | None = None) -> tuple:
    # Windows stat/lstat may expose birth time as ctime while fstat exposes
    # change time (https://github.com/python/cpython/issues/157671). Compare
    # birth time across APIs, but retain full ctime in both same-API before/
    # after checks below. Never discard inode, device, size, mtime or nlink.
    stamp = (getattr(info, "st_birthtime_ns", info.st_ctime_ns)
        if (os.name == "nt" if windows is None else windows) else info.st_ctime_ns)
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, stamp, info.st_nlink)


def atomic_text(path: Path, text: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix="fixture-report-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text); stream.flush(); os.fsync(stream.fileno())
        # Replace the directory entry; do not follow an existing report symlink.
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def execute_native(command: list[str], *, cwd: Path, env: dict[str, str], timeout: float,
                   log_directory: Path) -> subprocess.CompletedProcess:
    """Keep stdout/stderr on disk while running and stop only this child's tree."""
    stdout = log_directory / "stdout.log"
    stderr = log_directory / "stderr.log"
    timed_out = False
    termination_error = None
    options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    with stdout.open("xb") as out, stderr.open("xb") as err:
        child = subprocess.Popen(command, cwd=cwd, env=env, stdout=out, stderr=err, **options)
        try:
            child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                if os.name == "nt":
                    killed = subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                        capture_output=True, timeout=20, check=False)
                    if killed.returncode != 0 and child.poll() is None:
                        raise RuntimeError("Owned fixture process tree did not terminate")
                else:
                    try: os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                child.wait(timeout=10)
            except Exception as error:
                termination_error = str(error)
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)
        finally:
            out.flush(); err.flush()
    out_text = stdout.read_text(encoding="utf-8", errors="replace")
    err_text = stderr.read_text(encoding="utf-8", errors="replace")
    if timed_out:
        error = subprocess.TimeoutExpired(command, timeout, output=out_text, stderr=err_text)
        error.termination_error = termination_error
        raise error
    return subprocess.CompletedProcess(command, child.returncode, out_text, err_text)


class FixtureAttempt:
    def __init__(self, report_path: Path, *, label: str, log_path: Path | None = None):
        report_path.parent.mkdir(parents=True, exist_ok=True)
        parent = report_path.parent.resolve(strict=True)
        self.report_path = parent / report_path.name
        self.log_path = parent / (log_path.name if log_path else report_path.with_suffix(".log").name)
        artifacts = parent / "business-fixture-evidence"
        artifacts.mkdir(exist_ok=True)
        info = artifacts.lstat()
        if _link(info) or not stat.S_ISDIR(info.st_mode):
            raise ValueError("Fixture evidence directory must be a real directory")
        self.id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-") + uuid.uuid4().hex
        self.directory = artifacts / (label + "-" + self.id)
        self.directory.mkdir(mode=0o700)
        self.root: Path | None = None
        self.root_identity: tuple | None = None
        self.report = {"status": "FAIL", "attemptID": self.id, "cfg_test": False,
            "phase": "preparing", "error": "This invocation has not produced a completed, validated native proof.",
            "artifactDirectory": str(self.directory), "fixtureRootRetained": False}
        for path, destination in [(self.report_path, "previous-report.json"), (self.log_path, "previous-native.log")]:
            if path.exists() or path.is_symlink():
                info = path.lstat()
                if stat.S_ISREG(info.st_mode) and not _link(info) and info.st_nlink == 1:
                    path.rename(self.directory / destination)
                elif stat.S_ISDIR(info.st_mode) and not _link(info):
                    raise ValueError("A fixture result path is occupied by a directory")
                else:
                    self.report.setdefault("previousResultSkipped", []).append({"path": str(path), "reason": "linked result"})
        self.logs("", "")
        self.save()

    def save(self) -> None:
        text = json.dumps(self.report, ensure_ascii=False, indent=2) + "\n"
        atomic_text(self.directory / "report.json", text)
        atomic_text(self.report_path, text)

    def update(self, **values) -> None:
        self.report.update(values); self.save()

    def logs(self, stdout: str | bytes | None, stderr: str | bytes | None) -> None:
        def decoded(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
        text = decoded(stderr) + "\nSTDOUT:\n" + decoded(stdout)
        atomic_text(self.directory / "native.log", text)
        atomic_text(self.log_path, text)

    def create_root(self, base: Path, *, prefix: str, slugs: tuple[str, ...]) -> dict[str, str]:
        base = base.resolve(strict=True)
        home = Path.home().resolve()
        if not base.is_dir() or base.is_relative_to(home) or home.is_relative_to(base):
            raise ValueError("Fixture temporary directory overlaps the user home or is not a directory")
        self.root = Path(tempfile.mkdtemp(prefix=prefix, dir=base)).resolve(strict=True)
        info = self.root.lstat()
        self.root_identity = (info.st_dev, info.st_ino)
        (self.root / "synthetic-fixture-owner.json").write_text(
            json.dumps({"scope": "isolated-synthetic-native-fixture", "attemptID": self.id}) + "\n", encoding="utf-8")
        self.update(fixtureRoot=native_path(self.root), fixtureRootRetained=True)
        env = os.environ.copy()
        if len(slugs) != len(OVERRIDES) or len(set(slugs)) != len(slugs):
            raise ValueError("Every native override needs its own owned directory")
        for key, slug in zip(OVERRIDES, slugs, strict=True):
            if Path(slug).name != slug or slug in (".", "..") or "\\" in slug or ":" in slug:
                raise ValueError("Invalid fixture directory name")
            path = self.root / slug
            path.mkdir()
            resolved = path.resolve(strict=True)
            if _link(path.lstat()) or not resolved.is_dir() or resolved.parent != self.root:
                raise ValueError("Native path override escaped its owned fixture root")
            env[key] = native_path(resolved)
        return env

    def _owned_root(self) -> Path:
        if self.root is None:
            raise ValueError("No owned fixture root was created")
        info = self.root.lstat()
        if _link(info) or not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != self.root_identity:
            raise ValueError("Fixture root ownership changed")
        marker = self.root / "synthetic-fixture-owner.json"
        info = marker.lstat()
        if _link(info) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Fixture ownership marker is not a private regular file")
        value = json.loads(marker.read_text(encoding="utf-8"))
        if value != {"scope": "isolated-synthetic-native-fixture", "attemptID": self.id}:
            raise ValueError("Fixture ownership marker changed")
        return self.root

    def archive(self) -> dict:
        root = self._owned_root()
        files = []
        directories = []
        skipped = []
        def scan(directory: Path) -> None:
            for path in sorted(directory.iterdir()):
                relative = path.relative_to(root).as_posix()
                info = path.lstat()
                if _link(info):
                    skipped.append({"path": relative, "reason": "symlink-or-reparse-point"})
                elif "\\" in relative or any(":" in part for part in path.relative_to(root).parts):
                    skipped.append({"path": relative, "reason": "nonportable-archive-path"})
                elif stat.S_ISDIR(info.st_mode):
                    directories.append(relative)
                    scan(path)
                elif stat.S_ISREG(info.st_mode):
                    files.append((path, relative, info))
                else:
                    skipped.append({"path": relative, "reason": "not-a-regular-file"})
        scan(root)
        # A hard link is readable only when every link is inside this inventory.
        # An outside hard link must not bring unrelated bytes into diagnostics.
        links = Counter((info.st_dev, info.st_ino) for _, _, info in files)
        manifest = {"attemptID": self.id, "scope": "isolated-synthetic-native-fixture",
            "files": [], "directories": directories, "skipped": skipped}
        target = self.directory / "synthetic-state.zip"
        with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            for relative in directories:
                archive.writestr("state/" + relative + "/", "")
            for path, relative, expected in files:
                try:
                    self._owned_root()
                    if expected.st_nlink > 1 and (expected.st_ino == 0 or links[(expected.st_dev, expected.st_ino)] != expected.st_nlink):
                        raise ValueError("hard-link-outside-owned-inventory")
                    if not path.resolve(strict=True).is_relative_to(root):
                        raise ValueError("resolved-path-outside-owned-root")
                    for parent in path.relative_to(root).parents:
                        if _link((root / parent).lstat()):
                            raise ValueError("linked-parent")
                    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
                    with os.fdopen(descriptor, "rb") as source, tempfile.TemporaryFile(dir=self.directory) as copy:
                        before = os.fstat(source.fileno())
                        current = path.lstat()
                        if not stat.S_ISREG(before.st_mode) or _cross_api_identity(before) != _cross_api_identity(expected) \
                                or _identity(current) != _identity(expected) \
                                or not path.resolve(strict=True).is_relative_to(root):
                            raise ValueError("file-identity-changed-before-read: " + json.dumps({
                                "expected": _identity(expected), "opened": _identity(before),
                                "current": _identity(current)}))
                        digest = hashlib.sha256()
                        for chunk in iter(lambda: source.read(1024 * 1024), b""):
                            copy.write(chunk); digest.update(chunk)
                        if _identity(os.fstat(source.fileno())) != _identity(before) or _identity(path.lstat()) != _identity(expected):
                            raise ValueError("file-changed-during-read")
                        copy.seek(0)
                        with archive.open("state/" + relative, "w") as entry:
                            shutil.copyfileobj(copy, entry)
                        manifest["files"].append({"path": relative, "bytes": before.st_size, "sha256": digest.hexdigest()})
                except (OSError, ValueError) as error:
                    skipped.append({"path": relative, "reason": str(error)})
            archive.writestr("archive-manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        return {"failureArchive": str(target), "archiveComplete": not skipped,
            "archivedFiles": len(manifest["files"]), "archiveSkipped": skipped}

    def fail(self, error: BaseException, *, phase: str) -> None:
        self.report.update(status="FAIL", phase=phase, error=str(error), errorType=type(error).__name__,
            timedOut=isinstance(error, subprocess.TimeoutExpired), fixtureRootRetained=self.root is not None)
        if isinstance(error, subprocess.TimeoutExpired):
            self.logs(error.stdout, error.stderr)
            self.report["timeoutSeconds"] = error.timeout
            if getattr(error, "termination_error", None):
                self.report["terminationError"] = error.termination_error
        if isinstance(error, subprocess.CalledProcessError):
            self.report["nativeExitCode"] = error.returncode
        if self.root is not None:
            try: self.report.update(self.archive())
            except Exception as archive_error: self.report.update(archiveComplete=False, archiveError=str(archive_error))
        self.save()

    def succeed(self, native: dict) -> dict:
        root = self._owned_root()
        metadata = {key: self.report[key] for key in ("attemptID", "source_sha", "working_tree_dirty", "artifactDirectory", "fixtureRoot") if key in self.report}
        self.report = {**native, **metadata, "status": "PASS", "cfg_test": False,
            "phase": "completed", "fixtureRootRetained": True}
        self.save()
        try:
            shutil.rmtree(root)
            self.report["fixtureRootRetained"] = False
        except OSError as error:
            self.report["cleanupError"] = str(error)
        self.save()
        return self.report
