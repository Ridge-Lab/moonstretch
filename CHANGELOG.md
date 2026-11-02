# Changelog

## 0.1.0

- Original pure MoonBit WSOLA with joint multichannel alignment, bounded PCM history and deterministic chunking.
- Blackman-windowed sinc rate conversion with a fractional phase table and anti-alias filtering.
- Independent tempo, semitone pitch and playback-rate controls; exact final frame accounting and reset/finish lifecycle.
- WAV integration through MoonWavKit, including RIFF padding compatibility fixes, empty recordings and clear malformed-input diagnostics.
- Offline browser A/B demo, WAV CLI, reproducible signal measurements, numerical benchmark and SoundTouch process comparison.
- Four-backend Linux and two-backend Windows CI on MoonBit 0.10.16.
