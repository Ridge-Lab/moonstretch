///|
/// Independent tempo, pitch and playback-rate controls over interleaved PCM.
/// Fixed streams retain exact duration accounting; new_live permits controls
/// to change without resetting the analysis clock or resampler phase.
pub struct Stream {
  sample_rate : Int32
  channels : Int32
  mut tempo : Double
  mut pitch_semitones : Double
  mut playback_rate : Double
  dynamic : Bool
  quality : Quality
  stretch : @stretch.Processor
  resampler : @rate_engine.Processor
  pending : Array[Double]
  last_frame : Array[Double]
  mut received : Int64
  mut emitted : Int64
  mut finished : Bool
}

///|
pub fn Stream::new(
  sample_rate : Int32,
  channels : Int32,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
  quality~ : Quality = Balanced,
) -> Stream raise @types.AudioError {
  make_stream(
    sample_rate, channels, tempo, pitch_semitones, rate, quality, false,
  )
}

///|
/// A continuous stream with live controls. Changes affect subsequent DSP work,
/// including unprocessed lookahead, not already emitted audio. No state is reset.
pub fn Stream::new_live(
  sample_rate : Int32,
  channels : Int32,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
  quality~ : Quality = Balanced,
) -> Stream raise @types.AudioError {
  make_stream(
    sample_rate, channels, tempo, pitch_semitones, rate, quality, true,
  )
}

///|
fn make_stream(
  sample_rate : Int32,
  channels : Int32,
  tempo : Double,
  pitch_semitones : Double,
  rate : Double,
  quality : Quality,
  dynamic : Bool,
) -> Stream raise @types.AudioError {
  @types.validate_format(sample_rate, channels)
  @types.validate_ratio(tempo, 0.5, 2.0, "tempo")
  @types.validate_ratio(pitch_semitones, -12.0, 12.0, "pitch_semitones")
  @types.validate_ratio(rate, 0.5, 2.0, "rate")
  let pitch = @math.pow(2.0, pitch_semitones / 12.0)
  {
    sample_rate,
    channels,
    tempo,
    pitch_semitones,
    playback_rate: rate,
    dynamic,
    quality,
    stretch: @stretch.new(
      sample_rate,
      channels,
      tempo / pitch,
      hop_ms=quality.hop_ms(),
      search_ms=quality.search_ms(),
      quick=quality.quick(),
      dynamic~,
    ),
    resampler: @rate_engine.new(channels, pitch * rate, dynamic~),
    pending: [],
    last_frame: Array::make(channels, 0.0),
    received: 0L,
    emitted: 0L,
    finished: false,
  }
}

///|
fn Stream::target_frames(self : Stream) -> Int64 {
  (self.received.to_double() / (self.tempo * self.playback_rate) + 0.5).to_int64()
}

///|
/// Withhold a few frames so two stages' independent rounding cannot leak
/// an extra frame to a downstream audio device before the final length is known.
fn Stream::take_ready(self : Stream, draining : Bool) -> Array[Double] {
  let available = self.pending.length() / self.channels
  let permitted = if self.dynamic {
    available.to_int64()
  } else {
    self.target_frames() - self.emitted
  }
  let count = (if draining {
    available.to_int64().min(permitted).to_int()
  } else {
    (available - 8).max(0).to_int64().min(permitted).to_int()
  }).max(0)
  let n = count * self.channels
  let out = self.pending[:n].to_owned()
  let rest = self.pending[n:].to_owned()
  self.pending.clear()
  self.pending.append(rest)
  self.emitted = self.emitted + count.to_int64()
  out
}

///|
/// Returns all currently available output. The caller may pass arbitrary
/// complete-frame chunks. Rejected input leaves the stream untouched.
pub fn Stream::push(
  self : Stream,
  samples : Array[Double],
) -> Array[Double] raise @types.AudioError {
  if self.finished {
    raise @types.AudioError("push after finish; call reset first")
  }
  @types.validate_samples(samples, self.channels)
  if self.received + (samples.length() / self.channels).to_int64() >
    1000000000000L {
    raise @types.AudioError("stream exceeds the exact timeline limit")
  }
  let out : Array[Double] = []
  let chunk_samples = 1024 * self.channels
  let mut start = 0
  while start < samples.length() {
    let end = (start + chunk_samples).min(samples.length())
    let chunk = samples[start:end].to_owned()
    self.received = self.received + (chunk.length() / self.channels).to_int64()
    for c = 0; c < self.channels; c = c + 1 {
      self.last_frame[c] = chunk[chunk.length() - self.channels + c]
    }
    self.pending.append(self.resampler.push(self.stretch.push(chunk)))
    out.append(self.take_ready(false))
    start = end
  }
  out
}

///|
/// Drain the algorithmic tail once. Fixed streams contain exactly
/// round(input_frames / (tempo * rate)) frames. Live streams finish from their
/// cumulative analysis/phase clocks; the latest controls do not retime history.
pub fn Stream::finish(self : Stream) -> Array[Double] raise @types.AudioError {
  if self.finished {
    return []
  }
  self.pending.append(self.resampler.push(self.stretch.finish()))
  self.pending.append(self.resampler.finish())
  let out = self.take_ready(true)
  let missing = if self.dynamic {
    0L
  } else {
    self.target_frames() - self.emitted
  }
  // Only rounding of intermediate lengths may need correction, never a window.
  if missing > 8L {
    raise @types.AudioError("internal output accounting error")
  }
  if missing > 0L {
    let edge = if out.length() >= self.channels {
      out[out.length() - self.channels:].to_owned()
    } else {
      self.last_frame.copy()
    }
    for i = 0; i < missing.to_int(); i = i + 1 {
      out.append(edge)
    }
    self.emitted = self.emitted + missing
  }
  self.pending.clear()
  self.finished = true
  out
}

///|
/// Discard all buffered input/output while keeping the configured controls.
pub fn Stream::reset(self : Stream) -> Unit {
  self.stretch.reset()
  self.resampler.reset()
  self.pending.clear()
  for c = 0; c < self.channels; c = c + 1 {
    self.last_frame[c] = 0.0
  }
  self.received = 0L
  self.emitted = 0L
  self.finished = false
}

///|
pub fn Stream::input_frames(self : Stream) -> Int64 {
  self.received
}

///|
pub fn Stream::output_frames(self : Stream) -> Int64 {
  self.emitted
}

///|
/// Retained PCM frames across both algorithm stages; excludes returned output.
pub fn Stream::buffered_frames(self : Stream) -> Int32 {
  self.stretch.buffered_frames() +
  self.resampler.buffered_frames() +
  self.pending.length() / self.channels
}

///|
/// Conservative input lookahead budget, in input-rate frames. This does not
/// include device, host or scheduling latency.
pub fn Stream::latency_frames(self : Stream) -> Int32 {
  self.stretch.latency_frames() + 4 * self.resampler.latency_frames() + 32
}

///|
pub fn Stream::sample_rate(self : Stream) -> Int32 {
  self.sample_rate
}

///|
pub fn Stream::channels(self : Stream) -> Int32 {
  self.channels
}

///|
/// Atomically validate all controls. Dynamic changes apply at future processing
/// windows, not at an exact accepted input frame. See docs/API.md for timing.
pub fn Stream::set_controls(
  self : Stream,
  tempo~ : Double,
  pitch_semitones~ : Double,
  rate~ : Double,
) -> Unit raise @types.AudioError {
  if !self.dynamic {
    raise @types.AudioError("live controls require Stream::new_live")
  }
  if self.finished {
    raise @types.AudioError("cannot change controls after finish; reset first")
  }
  @types.validate_ratio(tempo, 0.5, 2.0, "tempo")
  @types.validate_ratio(pitch_semitones, -12.0, 12.0, "pitch_semitones")
  @types.validate_ratio(rate, 0.5, 2.0, "rate")
  let pitch = @math.pow(2.0, pitch_semitones / 12.0)
  self.stretch.set_tempo(tempo / pitch)
  self.resampler.set_rate(pitch * rate)
  self.tempo = tempo
  self.pitch_semitones = pitch_semitones
  self.playback_rate = rate
}

///|
pub fn Stream::controls(self : Stream) -> (Double, Double, Double) {
  (self.tempo, self.pitch_semitones, self.playback_rate)
}

///|
pub fn Stream::quality(self : Stream) -> Quality {
  self.quality
}

///|
/// Offline convenience wrapper using the same incremental implementation.
pub fn process(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
  quality~ : Quality = Balanced,
) -> Array[Double] raise @types.AudioError {
  let stream = Stream::new(
    sample_rate,
    channels,
    tempo~,
    pitch_semitones~,
    rate~,
    quality~,
  )
  let out = stream.push(samples)
  out.append(stream.finish())
  out
}
