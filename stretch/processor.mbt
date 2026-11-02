///|
/// Streaming WSOLA. Channels share one alignment offset. The analysis clock
/// is anchored to output frames rather than previous correlation winners.
pub struct Processor {
  channels : Int32
  tempo : Double
  hop : Int32
  search : Int32
  mut input : Array[Double]
  mut base : Int64
  mut received : Int64
  mut emitted : Int64
  mut tail : Array[Double]
  mut started : Bool
  mut finished : Bool
}

///|
/// A tempo of 2 halves duration without changing the intended pitch.
pub fn new(
  sample_rate : Int32,
  channels : Int32,
  tempo : Double,
) -> Processor raise @types.AudioError {
  @types.validate_format(sample_rate, channels)
  @types.validate_ratio(tempo, 0.25, 4.0, "tempo")
  {
    channels,
    tempo,
    hop: sample_rate / 50,
    search: sample_rate / 100,
    input: [],
    base: 0L,
    received: 0L,
    emitted: 0L,
    tail: [],
    started: false,
    finished: false,
  }
}

///|
/// Retained PCM including the overlap tail, measured in frames.
pub fn Processor::buffered_frames(self : Processor) -> Int32 {
  (self.input.length() + self.tail.length()) / self.channels
}

///|
/// Startup lookahead in input frames; identity has no latency.
pub fn Processor::latency_frames(self : Processor) -> Int32 {
  if self.tempo == 1.0 {
    0
  } else {
    let clock = @math.ceil(self.hop.to_double() * self.tempo).to_int()
    if clock > self.hop * 2 {
      clock
    } else {
      self.hop * 2
    }
  }
}

///|
pub fn Processor::input_frames(self : Processor) -> Int64 {
  self.received
}

///|
pub fn Processor::output_frames(self : Processor) -> Int64 {
  self.emitted
}

///|
/// Start another stream with unchanged format and tempo.
pub fn Processor::reset(self : Processor) -> Unit {
  self.input = []
  self.tail = []
  self.base = 0L
  self.received = 0L
  self.emitted = 0L
  self.started = false
  self.finished = false
}

///|
/// Out-of-stream samples are zero when draining the finite tail.
fn Processor::sample(
  self : Processor,
  frame : Int64,
  channel : Int32,
) -> Double {
  if frame < self.base || frame >= self.received {
    0.0
  } else {
    self.input[(frame - self.base).to_int() * self.channels + channel]
  }
}

///|
fn Processor::nominal(self : Processor) -> Int64 {
  @math.floor(self.emitted.to_double() * self.tempo + 0.5).to_int64()
}

///|
/// Shared scaling prevents finite large PCM from overflowing correlation.
fn Processor::score(
  self : Processor,
  position : Int64,
  stride : Int32,
  scale : Double,
  reference_energy : Double,
) -> Double {
  if scale == 0.0 || reference_energy == 0.0 {
    return 0.0
  }
  let mut product = 0.0
  let mut energy = 0.0
  let mut frame = 0
  while frame < self.hop {
    for channel = 0; channel < self.channels; channel = channel + 1 {
      let reference = self.tail[frame * self.channels + channel] / scale
      let candidate = self.sample(position + frame.to_int64(), channel) / scale
      product = product + reference * candidate
      energy = energy + candidate * candidate
    }
    frame = frame + stride
  }
  if energy == 0.0 {
    0.0
  } else {
    product / (reference_energy.sqrt() * energy.sqrt())
  }
}

///|
fn Processor::reference_energy(
  self : Processor,
  stride : Int32,
  scale : Double,
) -> Double {
  if scale == 0.0 {
    return 0.0
  }
  let mut result = 0.0
  let mut frame = 0
  while frame < self.hop {
    for channel = 0; channel < self.channels; channel = channel + 1 {
      let value = self.tail[frame * self.channels + channel] / scale
      result = result + value * value
    }
    frame = frame + stride
  }
  result
}

///|
fn closer(candidate : Int64, current : Int64, nominal : Int64) -> Bool {
  let a = if candidate >= nominal {
    candidate - nominal
  } else {
    nominal - candidate
  }
  let b = if current >= nominal { current - nominal } else { nominal - current }
  a < b || (a == b && candidate < current)
}

///|
/// Sparse correlations locate a region; every frame in it is then checked
/// using the full overlap. Equal scores prefer the nominal analysis clock.
fn Processor::choose(self : Processor, nominal : Int64) -> Int64 {
  let low = if nominal > self.search.to_int64() {
    nominal - self.search.to_int64()
  } else {
    0L
  }
  let high = nominal + self.search.to_int64()
  let mut scale = 0.0
  let mut scale_frame = low
  while scale_frame < high + self.hop.to_int64() {
    for channel = 0; channel < self.channels; channel = channel + 1 {
      let magnitude = self.sample(scale_frame, channel).abs()
      if magnitude > scale {
        scale = magnitude
      }
    }
    scale_frame = scale_frame + 1L
  }
  for value in self.tail {
    let magnitude = value.abs()
    if magnitude > scale {
      scale = magnitude
    }
  }
  if scale == 0.0 {
    return nominal
  }
  let stride = (self.hop + 127) / 128
  let step = (self.search * 2 + 95) / 96
  let ref_coarse = self.reference_energy(stride, scale)
  let mut best = nominal
  let mut best_score = self.score(nominal, stride, scale, ref_coarse)
  let mut position = low
  while position <= high {
    let score = self.score(position, stride, scale, ref_coarse)
    if score > best_score + 1.0e-12 ||
      ((score - best_score).abs() <= 1.0e-12 && closer(position, best, nominal)) {
      best = position
      best_score = score
    }
    position = position + step.to_int64()
  }
  let refine_low = if best - step.to_int64() > low {
    best - step.to_int64()
  } else {
    low
  }
  let refine_high = if best + step.to_int64() < high {
    best + step.to_int64()
  } else {
    high
  }
  let ref_full = self.reference_energy(1, scale)
  best_score = self.score(best, 1, scale, ref_full)
  position = refine_low
  while position <= refine_high {
    let score = self.score(position, 1, scale, ref_full)
    if score > best_score + 1.0e-12 ||
      ((score - best_score).abs() <= 1.0e-12 && closer(position, best, nominal)) {
      best = position
      best_score = score
    }
    position = position + 1L
  }
  best
}

///|
/// Release PCM that cannot be selected by any later analysis window.
fn Processor::compact(self : Processor) -> Unit {
  if !self.started {
    return
  }
  let nominal = self.nominal()
  let keep = if nominal > self.search.to_int64() {
    nominal - self.search.to_int64()
  } else {
    0L
  }
  let limit = if keep < self.received { keep } else { self.received }
  if limit > self.base {
    let drop = (limit - self.base).to_int() * self.channels
    self.input = self.input[drop:].to_owned()
    self.base = limit
  }
}

///|
/// Convex interpolation without overflow when both finite endpoints have the
/// same sign and are close to the maximum representable floating point value.
fn blend(a : Double, b : Double, mix : Double) -> Double {
  if (a >= 0.0 && b >= 0.0) || (a <= 0.0 && b <= 0.0) {
    if a >= b {
      a - (a - b) * mix
    } else {
      b - (b - a) * (1.0 - mix)
    }
  } else {
    a * (1.0 - mix) + b * mix
  }
}

///|
fn Processor::emit(
  self : Processor,
  frames : Int32,
  output : Array[Double],
) -> Unit {
  let position = if self.started { self.choose(self.nominal()) } else { 0L }
  for frame = 0; frame < frames; frame = frame + 1 {
    let mix = frame.to_double() / self.hop.to_double()
    for channel = 0; channel < self.channels; channel = channel + 1 {
      let current = self.sample(position + frame.to_int64(), channel)
      output.push(
        if self.started {
          blend(self.tail[frame * self.channels + channel], current, mix)
        } else {
          current
        },
      )
    }
  }
  self.tail = Array::makei(self.hop * self.channels, fn(index) {
    self.sample(
      position + (self.hop + index / self.channels).to_int64(),
      index % self.channels,
    )
  })
  self.started = true
  self.emitted = self.emitted + frames.to_int64()
  self.compact()
}

///|
fn Processor::ready(self : Processor) -> Bool {
  let needed = if self.started {
    self.nominal() + (self.search + self.hop * 2).to_int64()
  } else {
    (self.hop * 2).to_int64()
  }
  needed <= self.received &&
  (self.emitted + self.hop.to_int64()).to_double() * self.tempo <=
  self.received.to_double()
}

///|
/// Consume complete frames, returning available PCM. Validation errors leave
/// state unchanged. A large input is internally consumed in short blocks.
pub fn Processor::push(
  self : Processor,
  samples : Array[Double],
) -> Array[Double] raise @types.AudioError {
  if self.finished {
    raise @types.AudioError("push after finish; call reset first")
  }
  @types.validate_samples(samples, self.channels)
  let frames = samples.length() / self.channels
  if self.received > 1_000_000_000_000L - frames.to_int64() {
    raise @types.AudioError("stream exceeds exact analysis clock range")
  }
  if self.tempo == 1.0 {
    self.received = self.received + frames.to_int64()
    self.emitted = self.received
    return samples.copy()
  }
  let output : Array[Double] = []
  let mut cursor = 0
  let block = self.hop * self.channels
  while cursor < samples.length() {
    let end = if samples.length() - cursor > block {
      cursor + block
    } else {
      samples.length()
    }
    for index = cursor; index < end; index = index + 1 {
      self.input.push(samples[index])
    }
    self.received = self.received + ((end - cursor) / self.channels).to_int64()
    while self.ready() {
      self.emit(self.hop, output)
    }
    self.compact()
    cursor = end
  }
  output
}

///|
/// Drain with zero extension to exactly round(input/tempo) frames.
/// Repeated finish calls return empty output; reset starts a new stream.
pub fn Processor::finish(self : Processor) -> Array[Double] {
  if self.finished {
    return []
  }
  self.finished = true
  let target = @math.floor(self.received.to_double() / self.tempo + 0.5).to_int64()
  let output : Array[Double] = []
  while self.emitted < target {
    let remaining = target - self.emitted
    let frames = if remaining > self.hop.to_int64() {
      self.hop
    } else {
      remaining.to_int()
    }
    self.emit(frames, output)
  }
  self.input = []
  self.tail = []
  self.base = self.received
  output
}
