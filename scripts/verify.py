#!/usr/bin/env python3
"""One reproducible entry point for existing checks; Python standard library only."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGETS = ("js", "wasm", "wasm-gc", "native")


def utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def source_state() -> dict:
    """Fingerprint the actual checkout, including uncommitted source changes."""
    git = ["git", f"--git-dir={ROOT / '.git'}", f"--work-tree={ROOT}"]
    if not (ROOT / ".git").is_dir():
        git = ["git", "-C", str(ROOT)]
    try:
        def read(*args: str) -> bytes:
            return subprocess.check_output(git + list(args), cwd=ROOT, stderr=subprocess.PIPE)
        commit = read("rev-parse", "HEAD").decode().strip()
        status = read("status", "--porcelain").decode("utf-8", errors="replace")
        names = read("ls-files", "-z", "--cached", "--others", "--exclude-standard")
        digest = hashlib.sha256()
        count = 0
        for name in sorted(set(names.split(b"\0")) - {b""}):
            path = ROOT / os.fsdecode(name)
            digest.update(name + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest() if path.is_file() else b"MISSING")
            count += 1
        return {"commit": commit, "dirty": bool(status), "status": status,
                "source_sha256": digest.hexdigest(), "files": count}
    except (OSError, subprocess.CalledProcessError) as error:
        return {"commit": None, "dirty": None, "error": str(error)}


class Verification:
    def __init__(self, args: argparse.Namespace, directory: pathlib.Path):
        self.args, self.directory = args, directory
        self.tasks: list[dict] = []
        self.environment = os.environ.copy()
        temporary = directory / "tmp"
        temporary.mkdir()
        for key in ("TMP", "TEMP", "TMPDIR"):
            self.environment[key] = str(temporary)
        # Existing scripts invoke these tools by name. Use the same installation
        # as the probes, without altering the user's persistent PATH.
        for tool in (args.node, args.moon):
            executable = shutil.which(tool)
            if executable:
                self.environment["PATH"] = str(pathlib.Path(executable).parent) + os.pathsep + self.environment.get("PATH", "")
        self.report = {
            "schema_version": 1, "run_id": directory.name, "started_at": utc(),
            "profile": args.profile, "targets": args.targets,
            "source": source_state(), "platform": platform.platform(),
            "python": sys.version, "moon_home": self.environment.get("MOON_HOME"),
            "working_directory": str(ROOT), "report_directory": str(directory),
            "toolchain": {}, "tasks": self.tasks, "errors": [],
            "module": dict(re.findall(r'^\s*(name|version)\s*=\s*"([^"]+)"',
                                      (ROOT / "moon.mod").read_text(encoding="utf-8"), re.MULTILINE)),
            "counting": "Counts are executed commands, not individual assertions or unique tests. See each task log and numerical report.",
        }

    def task(self, name: str, command: list[str], *, requires: tuple[str, ...] = (),
             artifacts: tuple[pathlib.Path, ...] = (), optional: bool = False,
             skip: str | None = None) -> None:
        states = {task["name"]: task["status"] for task in self.tasks}
        failed = [dependency for dependency in requires if states.get(dependency) != "passed"]
        record = {"name": name, "command": command, "requires": list(requires),
                  "optional": optional, "status": "skipped", "duration_seconds": 0.0,
                  "exit_code": None, "log": None, "artifacts": []}
        self.tasks.append(record)
        if skip or failed:
            record["reason"] = skip or "Dependency did not pass: " + ", ".join(failed)
            print(f"SKIP {name}: {record['reason']}", flush=True)
            return
        log_path = self.directory / f"{len(self.tasks):02d}-{name}.log"
        record.update(log=str(log_path), started_at=utc())
        start = time.monotonic()
        print(f"RUN  {name}", flush=True)
        try:
            with log_path.open("w", encoding="utf-8") as log:
                log.write(json.dumps({"command": command, "cwd": str(ROOT)}, ensure_ascii=False) + "\n")
                log.flush()
                try:
                    result = subprocess.run(command, cwd=ROOT, env=self.environment,
                                            stdout=log, stderr=subprocess.STDOUT,
                                            timeout=self.args.timeout, check=False)
                    record["exit_code"] = result.returncode
                    record["status"] = "passed" if result.returncode == 0 else "failed"
                except (OSError, subprocess.TimeoutExpired) as error:
                    record.update(status="failed", reason=str(error))
                    log.write("\n" + str(error) + "\n")
            if record["status"] == "passed":
                for artifact in artifacts:
                    # Every artifact lives in this new run directory. A previous
                    # success file cannot make a failed or skipped check pass.
                    if not artifact.is_file():
                        record.update(status="failed", reason=f"Expected artifact missing: {artifact}")
                        break
                    raw = artifact.read_bytes()
                    record["artifacts"].append({"path": str(artifact), "bytes": len(raw),
                                                "sha256": hashlib.sha256(raw).hexdigest()})
        except KeyboardInterrupt:
            record.update(status="failed", reason="Interrupted by operator")
            raise
        finally:
            record["duration_seconds"] = round(time.monotonic() - start, 3)
            record["finished_at"] = utc()
        print(f"{record['status'].upper():4} {name} ({record['duration_seconds']:.2f}s)", flush=True)

    def run(self) -> None:
        args = self.args
        moon, node = args.moon, args.node
        self.task("moon-version", [moon, "version", "--all"])
        self.task("node-version", [node, "--version"])
        for task in self.tasks:
            if task["status"] == "passed":
                self.report["toolchain"][task["name"]] = pathlib.Path(task["log"]).read_text(encoding="utf-8").split("\n", 1)[1].strip()
        if args.profile == "release":
            self.task("public-package", [sys.executable, "scripts/verify_release.py", "--version", args.version,
                      "--targets", *args.targets, "--output", str(self.directory / "consumer")],
                      requires=("moon-version", "node-version"))
            return

        self.task("harness-contracts", [sys.executable, "scripts/verify_harness_test.py"])
        self.task("format", [moon, "fmt", "--check"], requires=("moon-version",))
        for target in args.targets:
            self.task(f"check-{target}", [moon, "check", "--target", target, "--deny-warn"], requires=("moon-version",))
            self.task(f"test-{target}", [moon, "test", "--target", target, "--deny-warn"], requires=(f"check-{target}",))
            self.task(f"build-{target}", [moon, "build", "--target", target, "--release", "--deny-warn"], requires=(f"check-{target}",))
            if args.profile == "full":
                for example in ("basic", "player", "practice"):
                    self.task(f"example-{target}-{example}", [moon, "run", "--target", target, "--release", f"examples/{example}"],
                              requires=(f"build-{target}",))
        if "js" not in args.targets:
            self.task("build-js", [moon, "build", "--target", "js", "--release", "--deny-warn"], requires=("moon-version",))
        host = ("build-js", "node-version")
        streaming = self.directory / "streaming-quality.json"
        self.task("host-boundaries", [node, "scripts/verify_host_boundaries.mjs"], requires=host)
        self.task("streaming", [node, "scripts/verify_streaming.mjs", str(streaming)], requires=host, artifacts=(streaming,))
        self.task("web-build", [node, "scripts/build_web.mjs"], requires=host)
        self.task("browser-protocol", [node, "--test", "web/stream-protocol.test.mjs", "web/stream-engine.test.mjs"], requires=("web-build",))
        stream_cli = self.directory / "stream-cli-quality.json"
        self.task("stream-wav-cli", [node, "scripts/verify_stream_cli.mjs", str(stream_cli)], requires=host, artifacts=(stream_cli,))
        if args.profile == "full":
            quality = self.directory / "pcm-quality.json"
            self.task("pcm-properties", [sys.executable, "scripts/audio_quality.py", "--output", str(quality),
                      "--", node, "scripts/quality_driver.mjs"], requires=host, artifacts=(quality,))
            self.task("wav-cli", [node, "scripts/verify_wav.mjs"], requires=host)
            bpm = self.directory / "bpm-quality.json"
            self.task("bpm-cli", [node, "scripts/verify_bpm.mjs", str(bpm)], requires=host, artifacts=(bpm,))
            faults = self.directory / "fault-sensitivity.json"
            self.task("fault-sensitivity", [sys.executable, "scripts/verify_faults.py", "--output", str(faults),
                      "--", node, "scripts/quality_driver.mjs"], requires=host, artifacts=(faults,))
            benchmark = self.directory / "streaming-benchmark.json"
            self.task("block-benchmark", [node, "scripts/benchmark_streaming.mjs", str(benchmark)], requires=host, artifacts=(benchmark,))
            reference = self.directory / "soundtouch-quality.json"
            self.task("soundtouch-reference", [sys.executable, "scripts/audio_quality.py", "--output", str(reference),
                      "--require-soundtouch", "--soundstretch", args.soundstretch or "soundstretch", "--", node, "scripts/quality_driver.mjs"],
                      requires=host, artifacts=(reference,), optional=not bool(args.soundstretch),
                      skip=None if args.soundstretch else "Not requested; pass --soundstretch with the independent executable")

    def finish(self) -> int:
        self.report["source_after"] = source_state()
        before, after = self.report["source"], self.report["source_after"]
        if before.get("error") or after.get("error"):
            self.report["errors"].append("Could not identify the checked source tree")
        elif before["source_sha256"] != after["source_sha256"] or before["commit"] != after["commit"]:
            self.report["errors"].append("Source changed during verification; rerun on a stable checkout")
        failures = [task for task in self.tasks if task["status"] == "failed" or
                    (task["status"] == "skipped" and not task["optional"])]
        ok = bool(self.tasks) and not failures and not self.report["errors"]
        self.report.update(status="passed" if ok else "failed", finished_at=utc(),
                           counts={status: sum(task["status"] == status for task in self.tasks)
                                   for status in ("passed", "failed", "skipped")})
        summary = self.directory / "summary.json"
        summary.write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"{self.report['status'].upper()}: {summary}", flush=True)
        return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("quick", "full", "release"), default="quick")
    parser.add_argument("--targets", choices=TARGETS, nargs="+", default=["js"], help="Explicit backends; default: js. Host checks also build JS.")
    parser.add_argument("--version", help="Required published package version for the release profile")
    parser.add_argument("--soundstretch", help="Independent SoundTouch executable; required to claim reference checks ran")
    parser.add_argument("--moon", default="moon", help="MoonBit executable; never installed or upgraded by this script")
    parser.add_argument("--node", default="node", help="Node executable")
    parser.add_argument("--timeout", type=int, default=600, help="Maximum seconds per task")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "work" / "verification", help="Parent directory for a new, unique run")
    args = parser.parse_args()
    args.targets = list(dict.fromkeys(args.targets))
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    if args.profile == "release" and not args.version:
        parser.error("release verification requires an explicit --version")
    if args.version and (args.profile != "release" or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", args.version)):
        parser.error("--version is only valid for release and must be a semantic version")
    if args.soundstretch and args.profile != "full":
        parser.error("--soundstretch requires --profile full")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    directory = output / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    directory.mkdir()
    verification = Verification(args, directory)
    lock = ROOT / "work" / "verification.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    acquired = False
    try:
        try:
            with lock.open("x", encoding="utf-8") as handle:
                handle.write(json.dumps({"pid": os.getpid(), "run": str(directory), "started_at": utc()}))
            acquired = True
        except FileExistsError:
            verification.report["errors"].append(f"Another verification owns {lock}; inspect its PID before removing a stale lock")
            return verification.finish()
        verification.run()
    except KeyboardInterrupt:
        verification.report["errors"].append("Interrupted by operator")
    except Exception as error:
        verification.report["errors"].append(f"Harness error: {type(error).__name__}: {error}")
    finally:
        if acquired:
            lock.unlink()
    return verification.finish()


if __name__ == "__main__":
    raise SystemExit(main())
