# Rate conversion

This package converts interleaved floating-point PCM without changing the
declared playback sample rate. `rate` is input frames advanced per output
frame: a value of 2 doubles pitch and halves duration. Supported rates are
0.25 through 4, with 1 through 8 channels.

`new(channels, rate)` creates the converter. Feed complete frames to `push`,
consume the returned output, then append the result of `finish`. No host I/O,
native DSP library, or SoundTouch implementation is used. `reset` reuses the
configured filter for an independent stream.

For non-identity rates, the kernel is a normalized Blackman-windowed sinc.
Its normalized cutoff is `0.9 / max(1, rate)` and its input-frame radius is
`ceil(48 * max(1, rate))`. A table of 513 phases is built once; runtime samples
interpolate between adjacent coefficient rows. Downsampling lowers the cutoff
and increases the support rather than aliasing high frequencies through a
fixed interpolation filter. All channels use the same fractional position.

The filter intentionally reserves a transition band below Nyquist; it is not
a brick-wall filter. Lookahead is exposed by `latency_frames`. Output begins
when the first center has its complete future support. `finish` extends the
first and last samples, preserves DC at the edges, and emits exactly
`floor(input_frames / rate + 0.5)` frames. Identity conversion is an immediate,
bit-exact copy, including signed zero. The retained history after a push is
bounded by twice the filter radius plus four frames; input and returned output
arrays remain the caller's responsibility.

The tests measure passband waveform error, at least 60 dB stopband rejection
for specified 1.37x, 2x and 4x downsampling tones, impulse timing, reported
lookahead, endpoint DC, signed-zero identity, invalid-input atomicity, final
duration, per-channel isolation, and exact input-partition invariance. These
are numerical checks of this rate converter, not perceptual quality claims for
the complete time-stretch pipeline.

Algorithm background: Julius O. Smith III,
[Windowed Sinc Interpolation](https://www.dsprelated.com/freebooks/pasp/Windowed_Sinc_Interpolation.html).
The implementation in this repository is original; no source code is copied
from that reference or from SoundTouch.
