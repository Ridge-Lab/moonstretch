# Ecosystem scope and SoundTouch comparison

MoonStretch processes decoded PCM for independently controlled tempo, musical pitch,
and playback rate. Its intended reusable boundary is the audio transform between an
existing decoder and an existing player or encoder.

**Revision on 2026-11-09:** the earlier comparison omitted MoonMel's offline
`time_stretch` and `pitch_shift` APIs. Independent time/pitch transformation and
tempo estimation already exist in the MoonBit ecosystem. They are not claimed as
an empty niche. The meaningful increment must be demonstrated by the streaming
processing lifecycle, continuous control, multichannel behavior, and complete
application workflows described below.

## Existing implementations and the actual overlap

The original registry scan on 2026-11-02 used snapshot
`249f01069eb48811a7e6a2669ea441287d7257c3` of the
[Mooncakes index](https://mooncakes.io/git/index). Names and descriptions alone did
not reveal every public API. This revision checks the closest implementations'
generated interfaces and source, not just package descriptions. It is a dated
comparison, not a claim that other private, unpublished, or future work cannot exist.

| Existing work | Verified capability | Relationship to MoonStretch |
| --- | --- | --- |
| [1zhouhaoran1/moonmel 0.1.6](https://mooncakes.io/docs/1zhouhaoran1/moonmel) | Offline phase-vocoder time stretching, semitone pitch shifting, resampling, tempo estimation, and incremental Mel/Log-Mel/MFCC extraction | **Direct overlap for offline time/pitch effects.** MoonStretch needs to earn its separate value through a controllable PCM processing stream, linked channels, output queues and application integration. |
| [Sakuraqwq1/moonaudio 0.3.2](https://github.com/Sakuraqwq1/moonaudio) | WAV/AIFF/AU/FLAC decoding, several encoders, PCM operations, linear/cubic/sinc resampling, FFT and spectrograms | Complementary decoding and analysis; ordinary sample-rate conversion alone is not independent time/pitch control. |
| [dowdiness/moondsp 0.6.0](https://github.com/dowdiness/moondsp) | Oscillators, filters, delays, graph and voice control, browser audio integration | A reusable synthesis/processing graph can consume transformed PCM. Its graph-control work must not be described as absent from the ecosystem. |
| [hwlxmm/dsp 0.1.0](https://github.com/hwlxmm/moonbit-dsp) | Filters, FFT, YIN pitch estimation, MFCC, spectral subtraction, compressor and equalizer | Analysis and effects are established capabilities. Estimating pitch is different from changing the pitch of a recording. |
| [HK-SHAO/dsp / atools](https://github.com/HK-SHAO/atools/blob/main/moon/README.md) | FFT, STFT codec, PGHI and RTISI-LA phase reconstruction for audio/image conversion | Existing spectral DSP and phase reconstruction; not a source of newly claimed FFT/STFT work in MoonStretch. |
| [Milky2018/moon_rodio](https://github.com/moonbit-community/moon_rodio) | Native playback and a `Speed` adapter that changes the reported playback sample rate | A possible downstream player. That adapter couples speed and pitch; it does not establish absence of independent effects in other packages. |
| [Ridge-Lab/moonwavkit 0.1.3](https://github.com/Ridge-Lab/MoonWavKit) | RIFF/WAVE parsing, PCM conversion, analysis and basic PCM operations | Explicitly reused for WAV input/output. Its historical work is not counted as a new MoonStretch contribution. |

Relevant interfaces:
[moonaudio DSP](https://github.com/Sakuraqwq1/moonaudio/tree/main/src/dsp),
[moondsp public interface](https://github.com/dowdiness/moondsp/blob/main/pkg.generated.mbti),
[hwlxmm signal](https://github.com/hwlxmm/moonbit-dsp/blob/44fb1ac88917b0c13e209b9566679565a1ed80c4/src/signal/pkg.generated.mbti),
[hwlxmm audio DSP](https://github.com/hwlxmm/moonbit-dsp/blob/44fb1ac88917b0c13e209b9566679565a1ed80c4/src/audio_dsp/pkg.generated.mbti).

## MoonMel comparison at a fixed version

The checked [MoonMel v0.1.6 tag](https://github.com/1zhouhaoran1/MoonMel/tree/v0.1.6)
points to `b49eb6d239ae148a9782f4495332090bc1ee727c`, committed on 2026-10-30.
Its module declares version 0.1.6 and MIT licensing. This predates the original
MoonStretch audit; it is a correction to that audit, not a newly appearing competitor.

The [public interface](https://github.com/1zhouhaoran1/MoonMel/blob/v0.1.6/pkg.generated.mbti)
and [effects implementation](https://github.com/1zhouhaoran1/MoonMel/blob/v0.1.6/src/features/effects/effects.mbt)
show:

- `time_stretch(samples, rate, config?)` takes a full mono sample array, computes
  complex STFT frames, applies a phase vocoder, and reconstructs the requested
  output length with ISTFT.
- `pitch_shift(samples, sample_rate?, n_steps?, config?)` stretches the recording
  and resamples it back to the original length.
- `phase_vocoder` is public and works on a complete array of complex frames.
- [Tempo analysis](https://github.com/1zhouhaoran1/MoonMel/blob/v0.1.6/src/features/tempo/tempo.mbt)
  includes an autocorrelation tempogram and a prior-weighted BPM estimate.
- [Its streaming extractor](https://github.com/1zhouhaoran1/MoonMel/blob/v0.1.6/docs/en/API_SPECIFICATION.md#streaming)
  incrementally produces Mel/Log-Mel/MFCC features. That is a useful existing
  streaming API, but it is not an incremental time-stretched PCM output stream.

These source-level differences describe API scope, not a claim that MoonStretch
sounds better, executes faster, or is more reliable. Such conclusions require
matched measurements on representative signals.

## SoundTouch as a functional reference

[SoundTouch](https://www.surina.net/soundtouch/) is the mature reference for the
processing workflow. The [official README](https://www.surina.net/soundtouch/README.html)
and [public header](https://codeberg.org/soundtouch/soundtouch/src/branch/master/include/SoundTouch.h)
describe independent controls, FIFO processing, algorithm settings and
BPM-assisted WAV processing. The README heading says 2.4.0 but its changelog also
contains 2.4.1. Therefore this document does not call the website heading the
latest release or use it as proof of a particular installed reference binary.

| User-facing capability | SoundTouch / SoundStretch | MoonStretch 0.1.1 baseline | MoonStretch 0.2.0 increment |
| --- | --- | --- | --- |
| Independent tempo, pitch and rate | Combined controls | Fixed controls per stream, with batch convenience API | Preserve existing semantics and regression coverage. |
| Incremental input and consumer-controlled output | `putSamples`, `receiveSamples`, flush and clear | `push` returns newly available PCM; `finish` and `reset` | A FIFO processor with `put_samples`, `receive_samples`, `read_into`, `finish` and `clear`. |
| Change controls during processing | Runtime control setters | Requires a new fixed-configuration stream | `Stream::new_live` and `set_controls`; preserve processing history and define when changes take effect. |
| Processing tradeoffs | Sequence/seek/overlap settings and quick-seek option | A fixed algorithm configuration | Speech/Balanced/Music presets, documented settings, latency and throughput measurements. Preset names are not a guarantee of listening quality. |
| Tempo estimation and tempo matching | BPM detection and target-BPM CLI workflow | Not provided | Incremental BPM analysis and an estimate-to-target-tempo workflow, including ambiguity and low-confidence handling. |
| File and application integration | WAV command-line tool and library integrations | WAV CLI and offline browser preview | A real stream consumer demo plus reproducible control-change and tempo-matching examples. |
| Quality and correctness evidence | Established implementation; behavior depends on configuration | Analytical signal checks and independent SoundTouch process comparisons | Extend tests to control transitions, FIFO backpressure/lifecycle, presets, long-running streams and BPM ambiguity. |

The last column is implemented in the 0.2.0 source. Reproducible evidence includes
`scripts/verify_streaming.mjs` (changing controls and partition-independent output),
`scripts/verify_bpm.mjs` (independently measured beat-event intervals),
`web/stream-engine.test.mjs` (incremental consumption through the real compiled
MoonBit processor), and the runnable `examples/player` and `examples/practice`.
Published versions and CI results are linked from the README; source capabilities
should not be inferred to exist in an older installed package.

The SoundTouch CLI accepts a broader parameter range than MoonStretch 0.2.0.
MoonStretch must publish its own supported ranges instead of claiming all
SoundTouch settings or sample formats are compatible. Its API is MoonBit-native;
it does not promise SoundTouch binary/API compatibility, identical output samples,
SIMD/OpenMP support, or complete replacement of the upstream software.

## Why the increment is useful

1. **Interactive language learning:** decode a recording in blocks, adjust the
   practice tempo during consumption, and read the output in a player's requested
   block sizes. The application needs a processing state and timing contract,
   beyond calling an offline effect on the complete recording.
2. **Accompaniment practice:** estimate a stable beat rate, show uncertainty to the
   user, choose a target practice tempo and transpose the accompaniment. Export
   the result and demonstrate that pitch and duration follow the chosen controls.
   BPM detection alone is not claimed as a new ecosystem capability.
3. **Long recordings and multichannel asset processing:** keep decoder, transform
   and encoder connected through blocks, consume output promptly, and retain
   shared channel alignment. Measure retained algorithm history separately from
   unconsumed output, rather than claiming bounded memory for a caller that never
   drains its queue.

These are integration scenarios, not claims that a third-party product has already
adopted the library. A browser demo that first transforms the entire recording
does not by itself prove incremental playback or live parameter changes.

## Provenance and verification boundary

MoonStretch's time-domain implementation is independently written MoonBit WSOLA
plus band-limited sinc resampling. MoonMel uses a spectral phase-vocoder path;
its source is compared for scope, not copied into MoonStretch.

SoundTouch is LGPL-2.1; MoonStretch is MIT. The reference executable runs as a
separate development/test process and is not linked into the library. The actual
installed SoundTouch version must be recorded by each comparison run. The earlier
CI reference was the Ubuntu `soundstretch 2.3.2+ds1` package, not an asserted 2.4.x
runtime.

The numerical checks establish properties such as duration, target tone
frequency, channel relationships, anti-alias suppression and lifecycle behavior.
They do not establish lossless transformation, formant preservation, studio
mastering quality, universally correct BPM, or hard real-time operation.
Representative speech, music and transient listening cases and measured runtime
budgets are necessary for those application decisions.
