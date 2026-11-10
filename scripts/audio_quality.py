#!/usr/bin/env python3
"""Independent analytical PCM checks; Python standard library only.

Usage: python scripts/audio_quality.py --output work/quality.json -- node .../quality.js
Optional --soundstretch invokes the independent SoundTouch CLI, comparing physical
properties rather than samples. This is a regression suite, not a listening test.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import random
import shutil
import struct
import subprocess
import tempfile
import wave

SAMPLE_RATE = 16000
FRAME_COUNT = 16000


def tone(frequency: float, frames: int = FRAME_COUNT) -> list[float]:
    return [0.5 * math.sin(2 * math.pi * frequency * i / SAMPLE_RATE) for i in range(frames)]


def rms(samples: list[float]) -> float:
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0.0


def interior(samples: list[float]) -> list[float]:
    return samples[len(samples) // 4 : len(samples) * 3 // 4]


def measured_frequency(samples: list[float]) -> float:
    """Interpolated positive zero crossings, independent of FFT/WSOLA code."""
    crossings = []
    for i in range(1, len(samples)):
        left, right = samples[i - 1], samples[i]
        if left <= 0 < right:
            crossings.append(i - 1 - left / (right - left))
    assert len(crossings) >= 10, "too few periodic cycles to measure frequency"
    return (len(crossings) - 1) * SAMPLE_RATE / (crossings[-1] - crossings[0])


def invoke(command: list[str], samples: list[float], channels: int = 1,
           tempo: float = 1.0, pitch: float = 0.0, rate: float = 1.0,
           chunk_frames: int | None = None, metadata: dict | None = None) -> list[float]:
    request = {"sample_rate": SAMPLE_RATE, "channels": channels, "tempo": tempo,
               "pitch_semitones": pitch, "rate": rate, "samples": samples}
    if chunk_frames is not None:
        request["chunk_frames"] = chunk_frames
    completed = subprocess.run(command, input=json.dumps(request), capture_output=True,
                               text=True, encoding="utf-8", timeout=120)
    assert completed.returncode == 0, f"driver exited {completed.returncode}: {completed.stderr[-2000:]}"
    try:
        reply = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"driver stdout is not JSON: {completed.stdout[:300]!r}") from error
    assert reply["channels"] == channels, "channel count changed"
    assert reply["sample_rate"] == SAMPLE_RATE, "sample-rate metadata changed"
    output = reply["samples"]
    assert isinstance(output, list) and len(output) % channels == 0, "partial output frame"
    assert all(isinstance(x, (int, float)) and math.isfinite(x) for x in output), "nonfinite PCM"
    expected = math.floor((len(samples) // channels) / (tempo * rate) + 0.5)
    assert len(output) // channels == expected, ("duration", len(output) // channels, expected)
    if metadata is not None:
        for field in ["peak_buffered_frames", "first_output_at_input_frame", "latency_frames"]:
            metadata[field] = reply[field]
    return output


def verify_frequency(output: list[float], expected: float) -> dict:
    body = interior(output)
    actual, level = measured_frequency(body), rms(body)
    relative_error = abs(actual - expected) / expected
    assert relative_error <= 0.015, ("frequency", actual, expected, relative_error)
    assert 0.05 <= level <= 1.0, ("tone level", level)
    return {"expected_hz": expected, "measured_hz": actual,
            "relative_error": relative_error, "rms": level}


def pcm16_source(samples: list[float]) -> list[float]:
    """One common representable input for the float API and PCM16 reference CLI."""
    return [round(max(-1, min(1, x)) * 32767) / 32768 for x in samples]


def reference(executable: str, directory: pathlib.Path, source: list[float],
              tempo: float, pitch: float, rate: float, channels: int = 1,
              metadata: dict | None = None) -> list[float]:
    input_path, output_path = directory / "input.wav", directory / "output.wav"
    with wave.open(str(input_path), "wb") as writer:
        writer.setparams((channels, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
        writer.writeframes(struct.pack("<" + "h" * len(source),
                                       *(max(-32768, min(32767, round(x * 32768))) for x in source)))
    completed = subprocess.run([executable, str(input_path), str(output_path),
                                f"-tempo={(tempo - 1) * 100:.8f}", f"-pitch={pitch:.8f}",
                                f"-rate={(rate - 1) * 100:.8f}"],
                               capture_output=True, text=True, timeout=120)
    assert completed.returncode == 0, f"SoundTouch reference failed: {completed.stderr[-2000:]}"
    if metadata is not None and "reported_banner" not in metadata:
        # Keep the actual binary's output, rather than assuming the apt package
        # version. CI separately records dpkg-query for package provenance.
        metadata["reported_banner"] = "\n".join(
            line.strip() for line in (completed.stderr + "\n" + completed.stdout).splitlines()
            if "SoundStretch" in line or "SoundTouch" in line)[:1000]
    with wave.open(str(output_path), "rb") as reader:
        assert reader.getnchannels() == channels and reader.getsampwidth() == 2
        assert reader.getframerate() == SAMPLE_RATE
        raw = reader.readframes(reader.getnframes())
    return [x / 32768 for x in struct.unpack("<" + "h" * (len(raw) // 2), raw)]


def paired_reference(command: list[str], executable: str, directory: pathlib.Path,
                     metadata: dict) -> list[dict]:
    """Same input/parameters, independent physical checks, no sample equality."""
    rows = []
    configurations = [
        ("tempo", [440], 0.75, 0.0, 1.0),
        ("pitch", [440], 1.0, 7.0, 1.0),
        ("rate", [440], 1.0, 0.0, 1.5),
        ("distinct_stereo", [330, 660], 1.5, 0.0, 1.0),
    ]
    for label, frequencies, tempo, pitch, rate in configurations:
        channels = len(frequencies)
        source = pcm16_source([value for frame in zip(*(tone(f) for f in frequencies)) for value in frame])
        ours = invoke(command, source, channels=channels, tempo=tempo, pitch=pitch, rate=rate)
        other = reference(executable, directory, source, tempo, pitch, rate, channels, metadata)
        expected_frames = FRAME_COUNT / (tempo * rate)
        assert abs(len(other) / channels - expected_frames) <= 2, (
            "reference duration", len(other) / channels, expected_frames)
        expected_hz = [f * 2 ** (pitch / 12) * rate for f in frequencies]
        ours_metrics = [verify_frequency(ours[ch::channels], expected_hz[ch]) for ch in range(channels)]
        other_metrics = [verify_frequency(other[ch::channels], expected_hz[ch]) for ch in range(channels)]
        rows.append({"case": "soundtouch_paired_tones", "scenario": label, "channels": channels,
                     "tempo": tempo, "pitch_semitones": pitch, "rate": rate,
                     "common_input": "identical PCM16-representable samples", "input_frames": FRAME_COUNT,
                     "expected_duration_frames": expected_frames, "sample_equality_required": False,
                     "moonstretch": {"output_frames": len(ours) // channels, "channels": ours_metrics},
                     "soundtouch": {"output_frames": len(other) // channels, "channels": other_metrics},
                     "difference_moonstretch_minus_soundtouch": {
                         "output_frames": (len(ours) - len(other)) // channels,
                         "frequency_hz": [a["measured_hz"] - b["measured_hz"] for a, b in zip(ours_metrics, other_metrics)],
                         "rms": [a["rms"] - b["rms"] for a, b in zip(ours_metrics, other_metrics)]}})
    source = pcm16_source(timed_bursts())
    tempo, pitch, rate = 0.75, 0.0, 1.0
    ours = invoke(command, source, tempo=tempo, pitch=pitch, rate=rate)
    other = reference(executable, directory, source, tempo, pitch, rate, metadata=metadata)
    expected_frames = len(source) / (tempo * rate)
    assert abs(len(other) - expected_frames) <= 2, ("reference duration", len(other), expected_frames)
    expected_seconds = [second / tempo for second in [1, 2, 3]]
    measured = {}
    for name, output in [("moonstretch", ours), ("soundtouch", other)]:
        centers = burst_centers(output)
        assert len(centers) == 3, ("lost or duplicated audio burst", name, centers)
        error = max(abs(actual - expected) for actual, expected in zip(centers, expected_seconds))
        assert error <= 0.08, ("burst timing error seconds", name, error, centers, expected_seconds)
        measured[name] = {"output_frames": len(output), "burst_centers_seconds": centers,
                          "maximum_timing_error_seconds": error, "rms": rms(output)}
    rows.append({"case": "soundtouch_paired_bursts", "channels": 1,
                 "tempo": tempo, "pitch_semitones": pitch, "rate": rate,
                 "common_input": "identical PCM16-representable samples", "input_frames": len(source),
                 "expected_duration_frames": expected_frames, "expected_burst_centers_seconds": expected_seconds,
                 "burst_timing_limit_seconds": 0.08, "sample_equality_required": False, **measured,
                 "difference_moonstretch_minus_soundtouch": {
                     "output_frames": len(ours) - len(other),
                     "burst_centers_seconds": [a - b for a, b in zip(
                         measured["moonstretch"]["burst_centers_seconds"], measured["soundtouch"]["burst_centers_seconds"])],
                     "rms": measured["moonstretch"]["rms"] - measured["soundtouch"]["rms"]}})
    return rows


def timed_bursts() -> list[float]:
    """Three 100 ms Hann-shaped bursts at independently known source times."""
    samples = [0.0] * (4 * SAMPLE_RATE)
    half_width = SAMPLE_RATE // 20
    for second in [1, 2, 3]:
        center = second * SAMPLE_RATE
        for offset in range(-half_width, half_width + 1):
            envelope = 0.5 + 0.5 * math.cos(math.pi * offset / half_width)
            samples[center + offset] = 0.5 * envelope * math.sin(2 * math.pi * 660 * offset / SAMPLE_RATE)
    return samples


def burst_centers(samples: list[float]) -> list[float]:
    """Energy centroids of connected 10 ms active bins, without DSP internals."""
    width = SAMPLE_RATE // 100
    energies = [sum(x * x for x in samples[i:i + width])
                for i in range(0, len(samples), width)]
    threshold = max(energies, default=0) * 0.02
    groups, active = [], []
    for index, energy in enumerate(energies):
        if energy > threshold:
            active.append((index, energy))
        elif active:
            groups.append(active)
            active = []
    if active:
        groups.append(active)
    return [sum((index + 0.5) * width * energy for index, energy in group) /
            sum(energy for _, energy in group) / SAMPLE_RATE for group in groups]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--soundstretch", help="optional independent SoundTouch executable")
    parser.add_argument("--require-soundtouch", action="store_true",
                        help="require paired reference checks; default executable: soundstretch")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("supply the JSON quality driver command after --")
    reference_status = {"status": "skipped", "reason": "SoundTouch comparison not requested"}
    if args.require_soundtouch:
        args.soundstretch = args.soundstretch or "soundstretch"
    if args.soundstretch:
        resolved_reference = shutil.which(args.soundstretch)
        if resolved_reference is None:
            parser.error(f"requested SoundTouch executable not found: {args.soundstretch}")
        args.soundstretch = resolved_reference
        reference_status = {"status": "pending", "executable": resolved_reference,
                            "executable_sha256": hashlib.sha256(pathlib.Path(resolved_reference).read_bytes()).hexdigest(),
                            "frequency_relative_tolerance": 0.015,
                            "soundtouch_duration_tolerance_frames": 2,
                            "moonstretch_duration_tolerance_frames": 0,
                            "duration_rounding": "MoonStretch uses floor(expected_frames + 0.5)",
                            "interpretation": "Paired physical measurements; neither listening quality nor speed ranking."}
    results, source = [], tone(440)
    random_source = random.Random(20261102)
    noise = [random_source.uniform(-0.7, 0.7) for _ in range(4096)]
    same = invoke(command, noise)
    error = max(abs(a - b) for a, b in zip(same, noise))
    assert error <= 1e-12, ("identity", error)
    results.append({"case": "identity_seeded_noise", "max_absolute_error": error})
    for count in [0, 1, 17, 137]:
        for speed in [0.5, 1.0, 2.0]:
            short = invoke(command, tone(440, count), tempo=speed)
            results.append({"case": "short_clip", "input_frames": count,
                            "tempo": speed, "output_frames": len(short)})
    cases = [(0.5, 0.0, 1.0), (0.75, 0.0, 1.0), (1.5, 0.0, 1.0),
             (2.0, 0.0, 1.0), (1.0, -12.0, 1.0), (1.0, 7.0, 1.0),
             (1.0, 12.0, 1.0), (1.0, 0.0, 0.5), (1.0, 0.0, 2.0),
             (0.75, 7.0, 1.25), (1.5, -5.0, 0.75)]
    for tempo, pitch, rate in cases:
        output = invoke(command, source, tempo=tempo, pitch=pitch, rate=rate)
        row = {"case": "analytical_tone", "tempo": tempo, "pitch_semitones": pitch,
               "rate": rate, "output_frames": len(output)}
        row.update(verify_frequency(output, 440 * 2 ** (pitch / 12) * rate))
        results.append(row)
    stereo = [sample for x in source for sample in (x, -x)]
    output = invoke(command, stereo, channels=2, tempo=0.75, pitch=7)
    cancellation = max(abs(output[i] + output[i + 1]) for i in range(0, len(output), 2))
    assert cancellation < 1e-10, ("anti-phase channel alignment", cancellation)
    row = {"case": "stereo_anti_phase", "maximum_cancellation_error": cancellation}
    row.update(verify_frequency(output[::2], 440 * 2 ** (7 / 12)))
    results.append(row)
    stereo = [sample for pair in zip(tone(330), tone(660)) for sample in pair]
    output = invoke(command, stereo, channels=2, tempo=1.5)
    results.append({"case": "stereo_distinct_tones", "left": verify_frequency(output[::2], 330),
                    "right": verify_frequency(output[1::2], 660)})
    batch = invoke(command, stereo, channels=2, tempo=0.75, pitch=-5)
    for chunk in [1, 137, 1024, 2048]:
        streamed = invoke(command, stereo, channels=2, tempo=0.75, pitch=-5, chunk_frames=chunk)
        error = max((abs(a - b) for a, b in zip(batch, streamed)), default=0.0)
        assert len(batch) == len(streamed) and error <= 1e-10, ("stream partition", chunk, error)
        results.append({"case": "stream_partition", "chunk_frames": chunk, "max_absolute_error": error})
    # A full-clip buffering implementation would pass the sample checks above.
    # Require observable output before finish and a constant retained-PCM bound
    # across clips with a fourfold duration difference and extreme controls.
    for frames in [2 * SAMPLE_RATE, 8 * SAMPLE_RATE]:
        for tempo, pitch, rate in [(0.5, 12.0, 2.0), (2.0, -12.0, 0.5)]:
            metrics = {}
            invoke(command, tone(440, frames), tempo=tempo, pitch=pitch, rate=rate,
                   chunk_frames=137, metadata=metrics)
            assert 0 < metrics["first_output_at_input_frame"] <= metrics["latency_frames"] + 137, metrics
            assert 0 <= metrics["peak_buffered_frames"] <= SAMPLE_RATE // 2, metrics
            results.append({"case": "bounded_stream", "input_frames": frames,
                            "tempo": tempo, "pitch_semitones": pitch, "rate": rate,
                            "maximum_retained_frames": SAMPLE_RATE // 2, **metrics})
    # Detect actual relocated events, not merely the final output array length.
    for tempo, pitch in [(0.75, 0.0), (1.5, 0.0), (1.0, 7.0)]:
        events = burst_centers(invoke(command, timed_bursts(), tempo=tempo, pitch=pitch))
        expected = [second / tempo for second in [1, 2, 3]]
        assert len(events) == len(expected), ("lost or duplicated audio burst", events, expected)
        maximum_error = max(abs(actual - target) for actual, target in zip(events, expected))
        assert maximum_error <= 0.08, ("burst timing error seconds", maximum_error, events, expected)
        results.append({"case": "timed_bursts", "tempo": tempo, "pitch_semitones": pitch,
                        "expected_seconds": expected, "measured_seconds": events,
                        "maximum_error_seconds": maximum_error, "limit_seconds": 0.08})
    # At rate 2 the source Nyquist limit is 4 kHz; 6 kHz must not alias to 4 kHz.
    low = invoke(command, source, rate=2)
    high = invoke(command, tone(6000), rate=2)
    low_rms, high_rms = rms(interior(low)), rms(interior(high))
    rejection = 20 * math.log10(max(high_rms, 1e-15) / low_rms)
    assert rejection <= -25, ("anti-alias stopband relative dB", rejection)
    results.append({"case": "resampling_stopband", "low_rms": low_rms,
                    "high_rms": high_rms, "relative_db": rejection, "limit_db": -25})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.soundstretch:
        # All temporary audio goes beside the explicit report path, not system Temp.
        with tempfile.TemporaryDirectory(prefix="soundtouch-", dir=args.output.parent) as temporary:
            results.extend(paired_reference(command, args.soundstretch, pathlib.Path(temporary), reference_status))
        reference_status["status"] = "passed"
        reference_status["paired_cases"] = 5
    report = {"schema_version": 2, "sample_rate": SAMPLE_RATE, "tone_frames": FRAME_COUNT,
              "frequency_relative_tolerance": 0.015, "soundtouch": reference_status, "cases": results,
              "interpretation": "Numerical regression checks, not a perceptual-quality benchmark."}
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Passed {len(results)} independent PCM checks; report: {args.output}")


if __name__ == "__main__":
    main()
