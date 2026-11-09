///|
/// A periodicity estimate, not a probability of musical beat correctness.
/// Half/double-tempo ambiguity remains possible, especially with subdivisions.
pub(all) struct Estimate {
  bpm : Double
  confidence : Double
  analyzed_seconds : Double
}

///|
/// Bounded-memory rhythm analysis. Only a 200 Hz RMS energy envelope is kept,
/// never the original recording. Every channel contributes its own energy, so
/// phase-inverted stereo cannot cancel the detector input.
pub struct Detector {
  sample_rate : Int32
  channels : Int32
  min_bpm : Double
  max_bpm : Double
  envelope : Array[Double]
  mut write_position : Int32
  mut envelope_count : Int32
  mut phase : Int32
  mut bin_frames : Int32
  mut bin_energy : Double
  mut received : Int64
  mut finished : Bool
}

///|
/// Analyze tempos within 30..300 BPM. The window must be 8..60 seconds.
/// At least four seconds and three cycles of the slowest requested tempo are
/// needed before reporting a result. Input amplitude does not set the tempo.
pub fn Detector::new(
  sample_rate : Int32,
  channels : Int32,
  min_bpm~ : Double = 60.0,
  max_bpm~ : Double = 200.0,
  window_seconds~ : Int32 = 20,
) -> Detector raise @types.AudioError {
  @types.validate_format(sample_rate, channels)
  @types.validate_ratio(min_bpm, 30.0, 300.0, "min_bpm")
  @types.validate_ratio(max_bpm, 30.0, 300.0, "max_bpm")
  if min_bpm >= max_bpm {
    raise @types.AudioError("min_bpm must be less than max_bpm")
  }
  if window_seconds < 8 || window_seconds > 60 {
    raise @types.AudioError("window_seconds must be between 8 and 60")
  }
  {
    sample_rate,
    channels,
    min_bpm,
    max_bpm,
    envelope: Array::make(window_seconds * 200, 0.0),
    write_position: 0,
    envelope_count: 0,
    phase: 0,
    bin_frames: 0,
    bin_energy: 0.0,
    received: 0L,
    finished: false,
  }
}

///|
fn Detector::commit_bin(self : Detector) -> Unit {
  if self.bin_frames == 0 {
    return
  }
  self.envelope[self.write_position] = (self.bin_energy /
  self.bin_frames.to_double()).sqrt()
  self.write_position = (self.write_position + 1) % self.envelope.length()
  self.envelope_count = (self.envelope_count + 1).min(self.envelope.length())
  self.bin_frames = 0
  self.bin_energy = 0.0
}

///|
/// Arbitrary complete-frame partitions produce the same envelope. Validation
/// happens before any state changes. A finished instance must be reset first.
pub fn Detector::push(
  self : Detector,
  samples : Array[Double],
) -> Unit raise @types.AudioError {
  if self.finished {
    raise @types.AudioError("push after finish; call reset first")
  }
  @types.validate_samples(samples, self.channels)
  let frames = samples.length() / self.channels
  if self.received > 1000000000000L - frames.to_int64() {
    raise @types.AudioError("detector exceeds the exact timeline limit")
  }
  for frame = 0; frame < frames; frame = frame + 1 {
    let mut energy = 0.0
    for channel = 0; channel < self.channels; channel = channel + 1 {
      let value = samples[frame * self.channels + channel]
      energy = energy + value * value / self.channels.to_double()
    }
    self.bin_energy = self.bin_energy + energy
    self.bin_frames = self.bin_frames + 1
    self.phase = self.phase + 200
    if self.phase >= self.sample_rate {
      self.phase = self.phase - self.sample_rate
      self.commit_bin()
    }
  }
  self.received = self.received + frames.to_int64()
}

///|
/// Centered, normalized lag correlation avoids a DC energy floor masquerading
/// as periodicity. Each lag uses only real overlapping envelope observations.
fn correlation(onsets : Array[Double], lag : Int32, mean : Double) -> Double {
  let mut product = 0.0
  let mut first = 0.0
  let mut second = 0.0
  for i = lag; i < onsets.length(); i = i + 1 {
    let a = onsets[i] - mean
    let b = onsets[i - lag] - mean
    product = product + a * b
    first = first + a * a
    second = second + b * b
  }
  if first == 0.0 || second == 0.0 {
    0.0
  } else {
    product / (first * second).sqrt()
  }
}

///|
/// Estimate the dominant periodic onset interval in the current window.
/// Silence, low-dynamic steady signals, insufficient data and weak/non-peaked
/// correlations return None. Confidence measures periodicity, not beat labels.
pub fn Detector::estimate(self : Detector) -> Estimate? {
  let n = self.envelope_count
  let required = @math.ceil((180.0 / self.min_bpm).max(4.0) * 200.0).to_int()
  if n < required {
    return None
  }
  let start = if n == self.envelope.length() { self.write_position } else { 0 }
  let values = Array::makei(n, i => {
    self.envelope[(start + i) % self.envelope.length()]
  })
  let mut scale = 0.0
  for value in values {
    scale = scale.max(value)
  }
  if scale == 0.0 {
    return None
  }
  // A symmetric triangular 155 ms smoother suppresses carrier-envelope
  // ripple (including low bass tones) while retaining 30..300 BPM modulation.
  // Positive 20 ms energy differences form the onset-strength function.
  let smooth = Array::makei(n, i => {
    let mut sum = 0.0
    let mut weight_sum = 0.0
    for offset = -15; offset <= 15; offset = offset + 1 {
      let j = (i + offset).max(0).min(n - 1)
      let weight = (16 - offset.abs()).to_double()
      sum = sum + values[j] / scale * weight
      weight_sum = weight_sum + weight
    }
    sum / weight_sum
  })
  let mut mean_energy = 0.0
  for value in smooth {
    mean_energy = mean_energy + value / n.to_double()
  }
  let mut variance = 0.0
  for value in smooth {
    let difference = value - mean_energy
    variance = variance + difference * difference / n.to_double()
  }
  if mean_energy == 0.0 || variance.sqrt() / mean_energy < 0.08 {
    return None
  }
  let onsets = Array::makei(n, i => {
    if i < 4 {
      0.0
    } else {
      (smooth[i] - smooth[i - 4]).max(0.0)
    }
  })
  let mut mean = 0.0
  for value in onsets {
    mean = mean + value / n.to_double()
  }
  if mean == 0.0 {
    return None
  }
  let low = @math.floor(12000.0 / self.max_bpm).to_int().max(2)
  let high = @math.ceil(12000.0 / self.min_bpm).to_int()
  let correlations = Array::makei(high + 2, lag => {
    if lag < low - 1 {
      0.0
    } else {
      correlation(onsets, lag, mean)
    }
  })
  let mut best_lag = 0
  let mut best_score = 0.0
  for lag = low; lag <= high; lag = lag + 1 {
    let score = correlations[lag]
    if score >= correlations[lag - 1] &&
      score >= correlations[lag + 1] &&
      score > best_score {
      best_lag = lag
      best_score = score
    }
  }
  if best_lag == 0 || best_score < 0.35 {
    return None
  }
  // Repeated onsets produce peaks at integer multiples of their period. Prefer
  // the shortest comparably strong period, while preserving an actual stronger
  // low-tempo pattern when its faster subdivision is substantially weaker.
  for lag = low; lag < best_lag; lag = lag + 1 {
    let score = correlations[lag]
    if score >= correlations[lag - 1] &&
      score >= correlations[lag + 1] &&
      score >= best_score * 0.92 {
      best_lag = lag
      best_score = score
      break
    }
  }
  let flank = (best_lag / 8).max(3)
  let left = correlation(onsets, (best_lag - flank).max(1), mean)
  let right = correlation(onsets, best_lag + flank, mean)
  if best_score - (left + right) * 0.5 < 0.10 {
    return None
  }
  let before = correlations[best_lag - 1]
  let after = correlations[best_lag + 1]
  let denominator = before - 2.0 * best_score + after
  let offset = if denominator.abs() > 1.0e-12 {
    (0.5 * (before - after) / denominator).max(-0.5).min(0.5)
  } else {
    0.0
  }
  let bpm = 12000.0 / (best_lag.to_double() + offset)
  if bpm < self.min_bpm * 0.995 || bpm > self.max_bpm * 1.005 {
    return None
  }
  let duration = (self.received.to_double() / self.sample_rate.to_double()).min(
    n.to_double() / 200.0,
  )
  Some({
    bpm: bpm.max(self.min_bpm).min(self.max_bpm),
    confidence: best_score.max(0.0).min(1.0),
    analyzed_seconds: duration,
  })
}

///|
/// Finalize the last partial energy bin. Repeated calls return the same result.
pub fn Detector::finish(self : Detector) -> Estimate? {
  if !self.finished {
    self.commit_bin()
    self.finished = true
  }
  self.estimate()
}

///|
/// Start a new recording with the same format, search range and memory budget.
pub fn Detector::reset(self : Detector) -> Unit {
  self.write_position = 0
  self.envelope_count = 0
  self.phase = 0
  self.bin_frames = 0
  self.bin_energy = 0.0
  self.received = 0L
  self.finished = false
}

///|
pub fn Detector::input_frames(self : Detector) -> Int64 {
  self.received
}

///|
/// Number of 5 ms energy observations retained, not original PCM frames.
pub fn Detector::buffered_envelope_frames(self : Detector) -> Int32 {
  self.envelope_count
}

///|
/// Convenience analysis through the same bounded streaming detector.
pub fn analyze(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
  min_bpm~ : Double = 60.0,
  max_bpm~ : Double = 200.0,
) -> Estimate? raise @types.AudioError {
  let detector = Detector::new(sample_rate, channels, min_bpm~, max_bpm~)
  detector.push(samples)
  detector.finish()
}
