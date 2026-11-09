///|
/// Pull-style PCM processor for a decoder/player pipeline. Output remains queued
/// until received. Hosts should drain it and limit input based on num_samples().
/// This queue is not an allocation-free hard-real-time device callback.
pub struct Processor {
  stream : Stream
  queue : Array[Double]
  mut head : Int32
}

///|
pub fn Processor::new(
  sample_rate : Int32,
  channels : Int32,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
  quality~ : Quality = Balanced,
  adjustable~ : Bool = true,
) -> Processor raise @types.AudioError {
  {
    stream: make_stream(
      sample_rate, channels, tempo, pitch_semitones, rate, quality, adjustable,
    ),
    queue: [],
    head: 0,
  }
}

///|
pub fn Processor::put_samples(
  self : Processor,
  samples : Array[Double],
) -> Unit raise @types.AudioError {
  self.queue.append(self.stream.push(samples))
}

///|
pub fn Processor::finish(self : Processor) -> Unit raise @types.AudioError {
  self.queue.append(self.stream.finish())
}

///|
pub fn Processor::num_samples(self : Processor) -> Int32 {
  (self.queue.length() - self.head) / self.stream.channels()
}

///|
fn Processor::compact(self : Processor) -> Unit {
  if self.head == self.queue.length() {
    self.queue.clear()
    self.head = 0
  } else if self.head >= 8192 && self.head >= self.queue.length() / 2 {
    let rest = self.queue[self.head:].to_owned()
    self.queue.clear()
    self.queue.append(rest)
    self.head = 0
  }
}

///|
/// Fill up to max_frames at a complete-frame offset, returning frames written.
/// Unwritten destination samples are preserved. Invalid requests consume nothing.
pub fn Processor::read_into(
  self : Processor,
  destination : Array[Double],
  offset_frames : Int32,
  max_frames : Int32,
) -> Int32 raise @types.AudioError {
  let channels = self.stream.channels()
  let capacity = destination.length() / channels
  if destination.length() % channels != 0 ||
    offset_frames < 0 ||
    max_frames < 0 ||
    offset_frames > capacity ||
    max_frames > capacity - offset_frames {
    raise @types.AudioError(
      "read_into requires a complete-frame destination and valid frame range",
    )
  }
  let frames = max_frames.min(self.num_samples())
  let start = offset_frames * channels
  for i = 0; i < frames * channels; i = i + 1 {
    destination[start + i] = self.queue[self.head + i]
  }
  self.head += frames * channels
  self.compact()
  frames
}

///|
pub fn Processor::receive_samples(
  self : Processor,
  max_frames : Int32,
) -> Array[Double] raise @types.AudioError {
  if max_frames < 0 {
    raise @types.AudioError("max_frames must be nonnegative")
  }
  let frames = max_frames.min(self.num_samples())
  let out = self.queue[self.head:self.head + frames * self.stream.channels()].to_owned()
  self.head += out.length()
  self.compact()
  out
}

///|
pub fn Processor::set_controls(
  self : Processor,
  tempo~ : Double,
  pitch_semitones~ : Double,
  rate~ : Double,
) -> Unit raise @types.AudioError {
  self.stream.set_controls(tempo~, pitch_semitones~, rate~)
}

///|
/// Discard queued audio and DSP history, preserving the latest controls.
pub fn Processor::clear(self : Processor) -> Unit {
  self.queue.clear()
  self.head = 0
  self.stream.reset()
}

///|
pub fn Processor::latency_frames(self : Processor) -> Int32 {
  self.stream.latency_frames()
}

///|
pub fn Processor::input_frames(self : Processor) -> Int64 {
  self.stream.input_frames()
}

///|
/// Total generated frames (including unread output).
pub fn Processor::output_frames(self : Processor) -> Int64 {
  self.stream.output_frames()
}

///|
/// Retained PCM includes the consumed FIFO prefix until compaction releases it.
/// This excludes unused array capacity, caller buffers and filter coefficients.
pub fn Processor::buffered_frames(self : Processor) -> Int32 {
  self.stream.buffered_frames() + self.queue.length() / self.stream.channels()
}

///|
pub fn Processor::controls(self : Processor) -> (Double, Double, Double) {
  self.stream.controls()
}
