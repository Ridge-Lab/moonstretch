#!/usr/bin/env python3
"""Check whether the independent PCM checks reject known host/stream faults.

Requires a current JS release build. Uses the real JSON driver, followed by an
explicit request/output fault; does NOT mutate production source or measure
source-code mutation coverage. All accepted baselines must pass unchanged.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import pathlib
import platform
import random
import subprocess
import sys
import tempfile

import audio_quality as quality

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAULTS = {
    "ignored_tempo": ("request.tempo", "duration"),
    "ignored_pitch": ("request.pitch_semitones", "frequency"),
    "swapped_channels": ("reply.samples: interleaved left/right", "frequency"),
    "lost_tail_frame": ("reply.samples: final complete frame removed", "duration"),
    "duplicated_tail_frame": ("reply.samples: final complete frame duplicated", "duration"),
    "partial_frame": ("reply.samples: final interleaved scalar removed", "partial output frame"),
    "nonfinite_json_value": ("reply.samples: one value replaced by null, as JSON.stringify(NaN)", "nonfinite PCM"),
    "wrong_sample_rate": ("reply.sample_rate", "sample-rate metadata changed"),
    "muted_output": ("reply.samples: all values zero", "too few periodic cycles"),
    "excessive_gain": ("reply.samples: gain multiplied by ten", "tone level"),
    "accepted_roundoff": ("reply.samples: one value changed by 1e-12", None),
}


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def inject(mode: str, command: list[str], seed: int, trace_path: pathlib.Path) -> int:
    request = json.load(sys.stdin)
    before_request = digest(request)
    field, _ = FAULTS[mode]
    if mode == "ignored_tempo":
        request["tempo"] = 1.0
    elif mode == "ignored_pitch":
        request["pitch_semitones"] = 0.0
    completed = subprocess.run(command, input=json.dumps(request), text=True,
                               encoding="utf-8", capture_output=True, timeout=120, cwd=ROOT)
    if completed.returncode:
        sys.stderr.write(completed.stderr)
        return completed.returncode
    reply = json.loads(completed.stdout)
    if "error" in reply:
        raise RuntimeError(f"engine failed before injection: {reply['error']}")
    samples, channels = reply["samples"], reply["channels"]
    before_reply, before_length = digest(reply), len(samples)
    sample_index = random.Random(seed).randrange(len(samples))
    if mode == "swapped_channels":
        if channels != 2:
            raise ValueError("channel-swap probe requires stereo")
        for i in range(0, len(samples), 2):
            samples[i], samples[i + 1] = samples[i + 1], samples[i]
    elif mode == "lost_tail_frame":
        del samples[-channels:]
    elif mode == "duplicated_tail_frame":
        samples.extend(samples[-channels:])
    elif mode == "partial_frame":
        del samples[-1]
    elif mode == "nonfinite_json_value":
        samples[sample_index] = None
    elif mode == "wrong_sample_rate":
        reply["sample_rate"] += 1
    elif mode == "muted_output":
        samples[:] = [0.0] * len(samples)
    elif mode == "excessive_gain":
        samples[:] = [10.0 * value for value in samples]
    elif mode == "accepted_roundoff":
        samples[sample_index] += 1e-12
    trace = {"mode": mode, "location": field, "seed": seed,
             "request_before_sha256": before_request, "request_after_sha256": digest(request),
             "reply_before_sha256": before_reply, "reply_after_sha256": digest(reply),
             "samples_before": before_length, "samples_after": len(samples)}
    if mode in ("nonfinite_json_value", "accepted_roundoff"):
        trace["sample_index"] = sample_index
    if before_request == trace["request_after_sha256"] and before_reply == trace["reply_after_sha256"]:
        raise RuntimeError("requested injection changed neither request nor response")
    trace_path.write_text(json.dumps(trace), encoding="utf-8")
    sys.stdout.write(json.dumps(reply, allow_nan=False))
    return 0


def evaluate(command: list[str], mode: str) -> dict:
    """Reuse the same duration/finite/framing/frequency oracles as audio_quality."""
    if mode in ("swapped_channels", "partial_frame"):
        stereo = [x for pair in zip(quality.tone(330), quality.tone(660)) for x in pair]
        output = quality.invoke(command, stereo, channels=2, tempo=1.5)
        return {"left": quality.verify_frequency(output[::2], 330),
                "right": quality.verify_frequency(output[1::2], 660)}
    tempo = 0.75 if mode == "ignored_tempo" else 1.0
    pitch = 7.0 if mode == "ignored_pitch" else 0.0
    output = quality.invoke(command, quality.tone(440), tempo=tempo, pitch=pitch)
    return quality.verify_frequency(output, 440 * 2 ** (pitch / 12))


def git_value(*arguments: str) -> str | None:
    try:
        completed = subprocess.run(["git", f"--git-dir={ROOT / '.git'}", f"--work-tree={ROOT}",
                                    *arguments], text=True, capture_output=True)
    except OSError:
        return None
    return completed.stdout.strip() if completed.returncode == 0 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "work/fault-sensitivity.json")
    parser.add_argument("--seed", type=int, default=20261110)
    parser.add_argument("--inject", choices=FAULTS, help=argparse.SUPPRESS)
    parser.add_argument("--trace", type=pathlib.Path, help=argparse.SUPPRESS)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    command = command or ["node", str(ROOT / "scripts/quality_driver.mjs")]
    if args.inject:
        if args.trace is None:
            parser.error("internal injection requires --trace")
        return inject(args.inject, command, args.seed, args.trace)
    if not __debug__:
        parser.error("run without Python -O: the shared numerical suite uses assertions")
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc).isoformat()
    rows = []
    # Temporary files stay next to the explicitly selected report, not OS Temp.
    with tempfile.TemporaryDirectory(prefix="fault-probes-", dir=args.output.parent) as temporary:
        for index, (mode, (location, expected)) in enumerate(FAULTS.items()):
            row = {"case": mode, "location": location, "expected_rejection": expected,
                   "baseline_passed": False, "passed": False}
            trace_path = pathlib.Path(temporary) / f"{mode}.json"
            try:
                row["baseline_measurements"] = evaluate(command, mode)
                row["baseline_passed"] = True
                wrapped = [sys.executable, str(pathlib.Path(__file__).resolve()), "--inject", mode,
                           "--seed", str(args.seed + index), "--trace", str(trace_path), "--", *command]
                observed = None
                try:
                    row["modified_measurements"] = evaluate(wrapped, mode)
                except AssertionError as error:
                    observed = str(error)
                row["observed_rejection"] = observed
                if not trace_path.exists():
                    raise RuntimeError("driver did not record an actual injection")
                row["injection"] = json.loads(trace_path.read_text(encoding="utf-8"))
                if expected is None:
                    row["passed"] = observed is None
                    row["outcome"] = "accepted within declared tolerance" if row["passed"] else "false alarm"
                else:
                    row["passed"] = observed is not None and expected in observed
                    row["outcome"] = ("rejected by intended check" if row["passed"] else
                                      "escaped check" if observed is None else "rejected for unexpected reason")
            except Exception as error:
                row["error"] = f"{type(error).__name__}: {error}"
            rows.append(row)
    status = git_value("status", "--porcelain")
    built = ROOT / "_build/js/release/build/bridge/bridge.js"
    report = {"schema_version": 1, "passed": all(row["passed"] for row in rows),
              "started_at": started, "finished_at": datetime.now(timezone.utc).isoformat(),
              "seed": args.seed, "source_commit": git_value("rev-parse", "HEAD"),
              "source_dirty": bool(status) if status is not None else None,
              "python": sys.version.split()[0], "platform": platform.platform(),
              "driver_command": command,
              "engine_sha256": hashlib.sha256(built.read_bytes()).hexdigest() if built.exists() else None,
              "verifier_sha256": hashlib.sha256(pathlib.Path(quality.__file__).read_bytes()).hexdigest(),
              "fault_count": sum(expected is not None for _, expected in FAULTS.values()),
              "negative_control_count": sum(expected is None for _, expected in FAULTS.values()),
              "cases": rows,
              "scope": "Sensitivity of existing PCM oracles to explicit request/output faults. "
                       "Not production-source mutation coverage, proof of all bug detection, "
                       "listening quality or SoundTouch superiority."}
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"{'Passed' if report['passed'] else 'FAILED'} {sum(row['passed'] for row in rows)}/{len(rows)} "
          f"fault/negative-control probes; report: {args.output}")
    for row in rows:
        if not row["passed"]:
            print(f"  {row['case']}: {row.get('error', row.get('outcome'))}", file=sys.stderr)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
