# Changelog

## 0.2.0

- Correct the ecosystem comparison: MoonMel already supplies offline time stretching, pitch shifting and tempo analysis. Document the concrete streaming increment and a SoundTouch feature matrix.
- Add continuous tempo/pitch/rate updates with preserved WSOLA analysis clock, resampler phase and filter history. Keep the fixed-stream exact-duration API.
- Add player-facing FIFO input/output, reusable destination reads, explicit queued-frame counts and clear/finish lifecycle.
- Add Speech/Balanced/Music processing profiles with documented latency and search tradeoffs.
- Add bounded streaming BPM analysis, periodicity estimates, silence/nonperiodic rejection and target-BPM CLI workflows, including known source tempo and binary stdin/stdout.
- Add real incremental browser playback, live control updates and BPM-assisted practice, alongside the existing offline export path.
- Add runnable player and practice examples, independent control-transition and beat-event measurements, and block-level performance reports.

## 0.1.1

- Fix the fresh-consumer verification script to use the non-deprecated UInt32 conversion on MoonBit 0.10.16. The audio API and algorithms are unchanged.

## 0.1.0

- Original pure MoonBit WSOLA with joint multichannel alignment, bounded PCM history and deterministic chunking.
- Blackman-windowed sinc rate conversion with a fractional phase table and anti-alias filtering.
- Independent tempo, semitone pitch and playback-rate controls; exact final frame accounting and reset/finish lifecycle.
- WAV integration through MoonWavKit, including RIFF padding compatibility fixes, empty recordings and clear malformed-input diagnostics.
- Offline browser A/B demo, WAV CLI, reproducible signal measurements, numerical benchmark and SoundTouch process comparison.
- Four-backend Linux and two-backend Windows CI on MoonBit 0.10.16.
