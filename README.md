# MoonStretch

Pure MoonBit PCM time stretching and pitch shifting. Under active development.

MoonStretch changes tempo while preserving pitch, and transposes audio while
preserving duration. It is intended for language-learning players, music practice
tools and audio asset pipelines. Its core accepts decoded interleaved PCM; file
decoding belongs to existing audio libraries.

The implementation is original code based on published WSOLA and bandlimited
interpolation methods. SoundTouch is a behavioral comparison, not vendored code
or a promised drop-in API. License: MIT. Compiler baseline: MoonBit 0.10.16.

Current status and runnable examples will be documented as they are verified.
