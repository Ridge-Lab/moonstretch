///|
/// Fractional filter positions, interpolated rather than sample-quantized.
let phase_count : Int32 = 512

///|
/// Continuous interleaved PCM rate conversion. Rate is input frames advanced
/// per output frame: 2 halves duration and doubles pitch. All channels share
/// the same phase and filter. Rate 1 passes samples through exactly.
pub struct Processor {
  channels : Int32
  rate : Double
  radius : Int32
  coefficients : Array[Array[Double]]
  mut samples : Array[Double]
  mut base_frame : Int64
  mut input_frames : Int64
  mut output_frames : Int64
  mut next_frame : Int64
  mut fraction : Double
  mut finished : Bool
}

///|
/// Original Blackman-windowed sinc converter. Downsampling lowers the cutoff
/// and widens the kernel in input frames, preserving its transition width.
pub fn new(
  channels : Int32,
  rate : Double,
) -> Processor raise @types.AudioError {
  if channels < 1 || channels > 8 {
    raise @types.AudioError("channels must be between 1 and 8")
  }
  @types.validate_ratio(rate, 0.25, 4.0, "rate")
  let stretch = if rate > 1.0 { rate } else { 1.0 }
  let radius = if rate == 1.0 { 0 } else { @math.ceil(48.0 * stretch).to_int() }
  let cutoff = 0.9 / stretch
  let coefficients : Array[Array[Double]] = []
  if radius > 0 {
    for phase = 0; phase <= phase_count; phase = phase + 1 {
      let fraction = phase.to_double() / phase_count.to_double()
      let row : Array[Double] = []
      let mut total = 0.0
      for tap = -radius; tap <= radius; tap = tap + 1 {
        let x = tap.to_double() - fraction
        let normalized = x / radius.to_double()
        let weight = if normalized.abs() >= 1.0 {
          0.0
        } else {
          let sinc_x = @math.PI * cutoff * x
          let sinc = if sinc_x.abs() < 1.0e-12 {
            1.0
          } else {
            @math.sin(sinc_x) / sinc_x
          }
          let window = 0.42 +
            0.5 * @math.cos(@math.PI * normalized) +
            0.08 * @math.cos(2.0 * @math.PI * normalized)
          cutoff * sinc * window
        }
        row.push(weight)
        total += weight
      }
      for i = 0; i < row.length(); i = i + 1 {
        row[i] = row[i] / total
      }
      coefficients.push(row)
    }
  }
  {
    channels,
    rate,
    radius,
    coefficients,
    samples: [],
    base_frame: 0L,
    input_frames: 0L,
    output_frames: 0L,
    next_frame: 0L,
    fraction: 0.0,
    finished: false,
  }
}

///|
/// Push complete frames. Invalid input leaves the processor unchanged.
/// Output is independent of how the input is divided among calls.
pub fn Processor::push(
  self : Processor,
  samples : Array[Double],
) -> Array[Double] raise @types.AudioError {
  if self.finished {
    raise @types.AudioError(
      "cannot push after finish; reset the processor first",
    )
  }
  @types.validate_samples(samples, self.channels)
  let frames = (samples.length() / self.channels).to_int64()
  if self.input_frames > 281474976710656L - frames {
    raise @types.AudioError("stream exceeds the supported frame counter range")
  }
  self.input_frames += frames
  if self.rate == 1.0 {
    self.output_frames += frames
    return samples.copy()
  }
  for sample in samples {
    self.samples.push(sample)
  }
  self.drain(false)
}

///|
/// Finish using endpoint extension. Final length is nearest(input_frames /
/// rate), with half frames rounded upward. Repeated finish calls return empty.
pub fn Processor::finish(self : Processor) -> Array[Double] {
  if self.finished {
    return []
  }
  self.finished = true
  let result = self.drain(true)
  self.samples = []
  result
}

///|
/// Discard sample history and counters, retaining configuration and filters.
pub fn Processor::reset(self : Processor) -> Unit {
  self.samples = []
  self.base_frame = 0L
  self.input_frames = 0L
  self.output_frames = 0L
  self.next_frame = 0L
  self.fraction = 0.0
  self.finished = false
}

///|
/// Input frames retained after a call, excluding returned output.
pub fn Processor::buffered_frames(self : Processor) -> Int32 {
  self.samples.length() / self.channels
}

///|
/// Lookahead in input frames. A shorter stream is emitted by finish.
pub fn Processor::latency_frames(self : Processor) -> Int32 {
  self.radius
}

///|
fn Processor::drain(self : Processor, finishing : Bool) -> Array[Double] {
  let output : Array[Double] = []
  if self.rate == 1.0 || self.input_frames == 0L {
    return output
  }
  let target = (self.input_frames.to_double() / self.rate + 0.5)
    .floor()
    .to_int64()
  while self.output_frames < target &&
        (
          finishing ||
          self.next_frame + self.radius.to_int64() < self.input_frames
        ) {
    let table_position = self.fraction * phase_count.to_double()
    let phase = table_position.floor().to_int()
    let mix = table_position - phase.to_double()
    let low = self.coefficients[phase]
    let high = self.coefficients[phase + 1]
    let center = (self.next_frame - self.base_frame).to_int()
    let last = self.samples.length() / self.channels - 1
    for channel = 0; channel < self.channels; channel = channel + 1 {
      let mut value = 0.0
      for tap = 0; tap < low.length(); tap = tap + 1 {
        let source_frame = center + tap - self.radius
        let source_frame = if source_frame < 0 {
          0
        } else if source_frame > last {
          last
        } else {
          source_frame
        }
        let weight = low[tap] + mix * (high[tap] - low[tap])
        value += self.samples[source_frame * self.channels + channel] * weight
      }
      output.push(value)
    }
    self.output_frames += 1L
    // Fractional phase stays small, avoiding loss of precision from a growing
    // global floating-point timestamp.
    let advanced = self.fraction + self.rate
    let whole = advanced.floor().to_int64()
    self.next_frame += whole
    self.fraction = advanced - whole.to_double()
  }
  if !finishing {
    let earliest = self.next_frame - self.radius.to_int64()
    if earliest > self.base_frame {
      let removable = (earliest - self.base_frame).to_int()
      let available = self.samples.length() / self.channels
      // Retain the endpoint for finish, including after a large rate advance.
      let drop_frames = if removable < available {
        removable
      } else {
        available - 1
      }
      if drop_frames > 0 {
        let replacement : Array[Double] = []
        for i = drop_frames * self.channels
            i < self.samples.length()
            i = i + 1 {
          replacement.push(self.samples[i])
        }
        self.samples = replacement
        self.base_frame += drop_frames.to_int64()
      }
    }
  }
  output
}
