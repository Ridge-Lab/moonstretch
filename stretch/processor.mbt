///|
/// Streaming WSOLA. Channels share one alignment offset. The analysis clock
/// follows requested ratios rather than previous correlation winners. Dynamic
/// streams integrate ratio changes without recalculating their earlier clock.
pub struct Processor {
  channels : Int32
  mut tempo : Double
  hop : Int32
  search : Int32
  quick : Bool
  dynamic : Bool
  mut analysis_frame : Int64
  mut analysis_fraction : Double
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
  hop_ms~ : Int32 = 20,
  search_ms~ : Int32 = 10,
  quick~ : Bool = true,
  dynamic~ : Bool = false,
) -> Processor raise @types.AudioError {
  @types.validate_format(sample_rate, channels)
  @types.validate_ratio(tempo, 0.25, 4.0, "tempo")
  if hop_ms < 1 || hop_ms > 80 || search_ms < 0 || search_ms > 40 {
    raise @types.AudioError("hop_ms must be 1..80 and search_ms 0..40")
  }
  {
    channels,
    tempo,
    hop: (sample_rate * hop_ms / 1000).max(1),
    search: sample_rate * search_ms / 1000,
    quick,
    dynamic,
    analysis_frame: 0L,
    analysis_fraction: 0.0,
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
/// Update the ratio without flushing the overlap or restarting the analysis
/// clock. Applies to the next analysis hop, including queued lookahead.
pub fn Processor::set_tempo(
  self : Processor,
  tempo : Double,
) -> Unit raise @types.AudioError {
  @types.validate_ratio(tempo, 0.25, 4.0, "tempo")
  if !self.dynamic || self.finished {
    raise @types.AudioError(
      "set_tempo requires an unfinished dynamic processor",
    )
  }
  if tempo != self.tempo {
    self.tempo = tempo
  }
}

///|
/// Retained PCM including the overlap tail, measured in frames.
pub fn Processor::buffered_frames(self : Processor) -> Int32 {
  (self.input.length() + self.tail.length()) / self.channels
}

///|
/// Conservative lookahead for startup and steady analysis, in input frames.
/// Fixed identity has no lookahead; live identity preserves its overlap state.
pub fn Processor::latency_frames(self : Processor) -> Int32 {
  if self.tempo == 1.0 && !self.dynamic {
    0
  } else {
    let clock = @math.ceil(self.hop.to_double() * self.tempo).to_int()
    let window = self.search + self.hop * 2
    if clock > window {
      clock
    } else {
      window
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
  self.analysis_frame = 0L
  self.analysis_fraction = 0.0
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
  if self.dynamic {
    self.analysis_frame + (self.analysis_fraction + 0.5).floor().to_int64()
  } else {
    @math.floor(self.emitted.to_double() * self.tempo + 0.5).to_int64()
  }
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
  // Both modes use a bounded coarse search followed by local full-overlap
  // refinement. The detailed mode doubles coarse density, not an exhaustive
  // scan of every offset at the highest supported sample rates.
  let density = if self.quick { 128 } else { 256 }
  let candidates = if self.quick { 96 } else { 192 }
  let stride = (self.hop + density - 1) / density
  let step = ((self.search * 2 + candidates - 1) / candidates).max(1)
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
  if self.dynamic {
    let advance = self.analysis_fraction + frames.to_double() * self.tempo
    let whole = advance.floor().to_int64()
    self.analysis_frame += whole
    self.analysis_fraction = advance - whole.to_double()
  }
  self.compact()
}

///|
fn Processor::ready(self : Processor) -> Bool {
  let needed = if self.started {
    self.nominal() + (self.search + self.hop * 2).to_int64()
  } else {
    (self.hop * 2).to_int64()
  }
  let clock_ready = if self.dynamic {
    self.analysis_fraction + self.hop.to_double() * self.tempo <=
    (self.received - self.analysis_frame).to_double()
  } else {
    (self.emitted + self.hop.to_int64()).to_double() * self.tempo <=
    self.received.to_double()
  }
  needed <= self.received && clock_ready
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
  if self.tempo == 1.0 && !self.dynamic {
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
/// Drain using zero extension. Fixed controls yield round(input/tempo) frames;
/// dynamic controls finish the unconsumed source-clock distance at the current
/// tempo. Repeated finish calls return empty output; reset starts a new stream.
pub fn Processor::finish(self : Processor) -> Array[Double] {
  if self.finished {
    return []
  }
  self.finished = true
  let target = if self.dynamic {
    let remaining = (self.received - self.analysis_frame).to_double() -
      self.analysis_fraction
    self.emitted + (remaining / self.tempo + 0.5).floor().max(0.0).to_int64()
  } else {
    @math.floor(self.received.to_double() / self.tempo + 0.5).to_int64()
  }
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
