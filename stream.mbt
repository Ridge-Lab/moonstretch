///|
/// Independent tempo, pitch and playback-rate controls over interleaved PCM.
/// Parameters are fixed for a stream. Call finish before starting a new segment.
pub struct Stream {
  sample_rate : Int32
  channels : Int32
  tempo : Double
  playback_rate : Double
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
    playback_rate: rate,
    stretch: @stretch.new(sample_rate, channels, tempo / pitch),
    resampler: @rate_engine.new(channels, pitch * rate),
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
  let permitted = self.target_frames() - self.emitted
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
/// Drain the algorithmic tail once. The complete output contains exactly
/// round(input_frames / (tempo * rate)) frames, including empty/short inputs.
pub fn Stream::finish(self : Stream) -> Array[Double] raise @types.AudioError {
  if self.finished {
    return []
  }
  self.pending.append(self.resampler.push(self.stretch.finish()))
  self.pending.append(self.resampler.finish())
  let out = self.take_ready(true)
  let missing = self.target_frames() - self.emitted
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
/// Offline convenience wrapper using the same incremental implementation.
pub fn process(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
) -> Array[Double] raise @types.AudioError {
  let stream = Stream::new(
    sample_rate,
    channels,
    tempo~,
    pitch_semitones~,
    rate~,
  )
  let out = stream.push(samples)
  out.append(stream.finish())
  out
}
