# Ecosystem scope and provenance

MoonStretch accepts decoded PCM and independently changes its duration, musical
pitch, and playback rate. Its core contribution is a streaming time-domain audio
transform with linked channel alignment and band-limited resampling. File parsing,
audio devices, music notation, and waveform reports are separate concerns.

## Existing MoonBit projects checked

The selection audit on 2026-11-02 examined the Mooncakes Git registry snapshot
`249f01069eb48811a7e6a2669ea441287d7257c3` from
[`https://mooncakes.io/git/index`](https://mooncakes.io/git/index), containing
3,541 package index files. Package names and descriptions were searched for
`audio`, `dsp`, `stretch`, `tempo`, `pitch`, `wsola`, `soundtouch`, `rubberband`,
`resample`, and related terms; the closest projects were then checked at their
documented API/source level. This is a dated scope comparison, not a permanent
claim that no other implementation can exist.

| Existing work | Documented role | MoonStretch's separate contribution |
| --- | --- | --- |
| [dowdiness/moondsp](https://mooncakes.io/docs/dowdiness/moondsp) | Synthesis oscillators, filters, DSP graphs, voice scheduling and browser AudioWorklet integration | Transform an existing recording's speed without transposing it, or transpose it without changing its duration |
| [Sakuraqwq1/moonaudio](https://github.com/Sakuraqwq1/moonaudio) | Audio-container decoding/encoding, PCM, filters, FFT/spectrograms and sample-rate conversion | Independent tempo and pitch control, with stream input, incremental output and a defined flush lifecycle |
| [Milky2018/moon_rodio](https://github.com/moonbit-community/moon_rodio) | Native playback, sources, effects and a `Speed` source adapter | Generate new PCM at the original sample rate while controlling tempo and pitch separately; no audio device is required |
| [HK-SHAO/atools](https://github.com/HK-SHAO/atools/blob/main/docs/algorithms.md) | Audio-to-image encoding and phase reconstruction, including STFT and resampling | Preserve decoded audio as audio and expose continuous time/pitch transformation, rather than image encoding/reconstruction |
| [Ridge-Lab/moonwavkit](https://github.com/Ridge-Lab/MoonWavKit) | RIFF/WAVE parsing, PCM conversion, metadata, waveform/statistical analysis and basic PCM operations | New time-stretch and pitch-shift DSP; the existing WAV library is an explicitly declared adapter dependency |

Changing a recording's declared sample rate changes its duration and pitch
together. Ordinary sample-rate conversion changes sample representation while
keeping both physical duration and pitch. Neither operation by itself provides
the independent controls above. MoonStretch does not claim that filtering,
resampling, or audio handling was previously absent from MoonBit.

## Concrete uses

1. A language-learning or transcription tool decodes a speech recording, applies
   `tempo = 0.75`, and plays/writes the returned PCM. The recording lasts longer
   without the speaker being transposed down in pitch.
2. A music-practice tool decodes an accompaniment and applies a semitone offset.
   The singer or instrumentalist changes key while the backing track retains its
   duration and beat positions. Extreme transformations can produce artifacts;
   this is not a promise of studio-mastering quality.
3. A video editor or game asset pipeline transforms PCM to match a required
   scene length, checks the returned frame count, and hands it to an existing
   encoder/player. The core has no dependency on a browser or audio device.

## Relationship to mature solutions

[SoundTouch](https://www.surina.net/soundtouch/) demonstrates that separate tempo,
pitch and playback-rate control is an established application requirement, with
an existing command-line tool and integrations in other ecosystems. MoonStretch
is an original MoonBit implementation of the same class of signal-processing
operation, not a source translation, binding, or API-compatible SoundTouch port.

SoundTouch is LGPL-2.1; MoonStretch's independently written source is MIT.
SoundTouch source is not included or linked into the library. CI can install the
separate `soundstretch` executable to check independently measured duration and
frequency. Different algorithms are not required to emit identical samples, and
passing numerical checks is not evidence that one sounds better than the other.

The older MoonWavKit work is reused as a published dependency for WAV input/output;
it is not relabeled as new development. MoonIce and Capnp-MBT are not source bases
for the DSP implementation. The independent Python signal generator creates test
PCM mathematically and requires no copied recording or third-party dataset.

## Verification boundary

`scripts/audio_quality.py` measures analytical tone frequency, exact output frame
count, unchanged identity samples, anti-phase stereo alignment, distinct channel
content, partition-independent streaming, first output before flush, bounded
retained PCM across different recording lengths, transformed event timing, and
suppression of a tone above the resampling passband. Measurements and thresholds
are saved as JSON by CI. These
checks establish objective behavior; listening with speech and music remains
necessary when selecting parameters for a particular application.
