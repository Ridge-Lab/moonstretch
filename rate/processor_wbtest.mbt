///|
fn expect_error(action : () -> Unit raise @types.AudioError) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("expected AudioError")
  }
}

///|
fn convert(
  input : Array[Double],
  channels : Int32,
  ratio : Double,
  chunk : Int32,
) -> Array[Double] raise {
  let processor = new(channels, ratio)
  let output : Array[Double] = []
  let mut start = 0
  while start < input.length() {
    let stop = (start + chunk * channels).min(input.length())
    let block : Array[Double] = []
    for i = start; i < stop; i = i + 1 {
      block.push(input[i])
    }
    for sample in processor.push(block) {
      output.push(sample)
    }
    start = stop
  }
  for sample in processor.finish() {
    output.push(sample)
  }
  output
}

///|
fn tone(frames : Int32, frequency : Double) -> Array[Double] {
  Array::makei(frames, i => {
    @math.sin(2.0 * @math.PI * frequency * i.to_double())
  })
}

///|
fn interior_rms(samples : Array[Double], margin : Int32) -> Double {
  let mut sum = 0.0
  for i = margin; i < samples.length() - margin; i = i + 1 {
    sum += samples[i] * samples[i]
  }
  (sum / (samples.length() - 2 * margin).to_double()).sqrt()
}

///|
test "identity is bit exact and immediately available without retaining PCM" {
  let processor = new(2, 1.0)
  let input = [-0.0, 0.0, -0.123456789123, 0.987654321987, 1.0e-250, -3.0]
  let output = processor.push(input)
  assert_eq(output.length(), input.length())
  for i = 0; i < input.length(); i = i + 1 {
    assert_eq(output[i].reinterpret_as_int64(), input[i].reinterpret_as_int64())
  }
  output[0] = 1.0
  assert_eq(input[0].reinterpret_as_int64(), (-0.0).reinterpret_as_int64())
  assert_eq(processor.buffered_frames(), 0)
  assert_eq(processor.latency_frames(), 0)
  assert_eq(processor.finish().length(), 0)
}

///|
test "final duration and DC endpoints at both ratio limits and fractional ratios" {
  for ratio in [0.25, 0.73, 1.0, 1.7, 4.0] {
    let input = Array::make(103, 0.375)
    let output = convert(input, 1, ratio, 13)
    assert_eq(output.length(), (103.0 / ratio + 0.5).floor().to_int())
    for sample in output {
      assert_true((sample - 0.375).abs() < 1.0e-12)
    }
  }
}

///|
test "input partition does not change any output or stereo phase" {
  let input : Array[Double] = []
  for i = 0; i < 997; i = i + 1 {
    let value = @math.sin(i.to_double() * 0.17) +
      0.1 * @math.cos(i.to_double() * 0.59)
    input.push(value)
    input.push(-value)
  }
  let whole = convert(input, 2, 1.371, 997)
  let single = convert(input, 2, 1.371, 1)
  let blocks = convert(input, 2, 1.371, 37)
  assert_eq(single, whole)
  assert_eq(blocks, whole)
  for i = 0; i < whole.length(); i = i + 2 {
    assert_true((whole[i] + whole[i + 1]).abs() < 1.0e-14)
  }
}

///|
test "empty and single frame streams have defined length and reset semantics" {
  let processor = new(1, 0.5)
  assert_eq(processor.push([]), [])
  assert_eq(processor.finish(), [])
  assert_eq(processor.finish(), [])
  expect_error(() => ignore(processor.push([])))
  processor.reset()
  assert_eq(processor.push([0.7]), [])
  let output = processor.finish()
  assert_eq(output.length(), 2)
  assert_true((output[0] - 0.7).abs() < 1.0e-12)
  assert_true((output[1] - 0.7).abs() < 1.0e-12)
  assert_eq(processor.buffered_frames(), 0)
  processor.reset()
  assert_eq(processor.push([0.7]), [])
  assert_eq(processor.finish(), output)
}

///|
test "invalid frames and nonfinite values are rejected without state mutation" {
  expect_error(() => ignore(new(0, 1.0)))
  expect_error(() => ignore(new(9, 1.0)))
  expect_error(() => ignore(new(2, 0.249)))
  expect_error(() => ignore(new(2, 4.001)))
  expect_error(() => ignore(new(2, 0.0 / 0.0)))
  expect_error(() => ignore(new(2, 1.0 / 0.0)))
  let processor = new(2, 0.5)
  ignore(processor.push([0.2, -0.2]))
  expect_error(() => ignore(processor.push([0.3])))
  expect_error(() => ignore(processor.push([0.3, 0.0 / 0.0])))
  expect_error(() => ignore(processor.push([1.0 / 0.0, -0.3])))
  assert_eq(processor.buffered_frames(), 1)
  assert_eq(processor.finish(), convert([0.2, -0.2], 2, 0.5, 1))
}

///|
test "rate conversion preserves passband tone at the predicted output frequency" {
  let ratio = 1.37
  let input = tone(8192, 0.037)
  let output = convert(input, 1, ratio, 127)
  let mut squared_error = 0.0
  for i = 80; i < output.length() - 80; i = i + 1 {
    let expected = @math.sin(2.0 * @math.PI * 0.037 * i.to_double() * ratio)
    let error = output[i] - expected
    squared_error += error * error
  }
  let rms_error = (squared_error / (output.length() - 160).to_double()).sqrt()
  assert_true(rms_error < 0.0001)
}

///|
test "downsampling rejects out of band tones by more than sixty decibels" {
  for ratio in [2.0, 4.0] {
    let passband = convert(tone(8192, 0.03), 1, ratio, 191)
    let stopband = convert(tone(8192, 0.3), 1, ratio, 191)
    let pass_rms = interior_rms(passband, 80)
    let stop_rms = interior_rms(stopband, 80)
    assert_true(pass_rms > 0.70 && pass_rms < 0.72)
    assert_true(stop_rms / pass_rms < 0.001)
  }
}

///|
test "fractional and extreme downsampling suppress tones just above output Nyquist" {
  for ratio in [1.37, 4.0] {
    let output = convert(tone(8192, 0.52 / ratio), 1, ratio, 83)
    // Compare to unit-amplitude sine RMS. A threshold of 0.0007 corresponds
    // to slightly more than 60 dB rejection, away from startup/tail padding.
    assert_true(interior_rms(output, 80) < 0.0007)
  }
}

///|
test "reported lookahead agrees with first available output" {
  let processor = new(1, 2.0)
  let lookahead = processor.latency_frames()
  assert_eq(processor.push(Array::make(lookahead, 0.0)), [])
  assert_eq(processor.push([0.0]), [0.0])
  let tail = processor.finish()
  assert_eq(
    tail.length() + 1,
    ((lookahead + 1).to_double() / 2.0 + 0.5).floor().to_int(),
  )
  for sample in tail {
    assert_eq(sample, 0.0)
  }
}

///|
test "near unity noninteger ratios retain exact rounded duration under small pushes" {
  for ratio in [0.999999, 1.000001] {
    let input = tone(1001, 0.1)
    let reference = convert(input, 1, ratio, 1001)
    let chunked = convert(input, 1, ratio, 3)
    assert_eq(reference.length(), 1001)
    assert_eq(reference, chunked)
  }
}

///|
test "impulse retains its nominal time without an unreported filter delay" {
  let input = Array::make(1000, 0.0)
  input[400] = 1.0
  let output = convert(input, 1, 1.25, 73)
  let mut peak = 0
  for i = 1; i < output.length(); i = i + 1 {
    if output[i].abs() > output[peak].abs() {
      peak = i
    }
  }
  assert_eq(peak, 320)
  assert_true(output[peak] > 0.5)
}

///|
test "streaming keeps a bounded history and emits before finish" {
  let processor = new(1, 0.77)
  let mut emitted = 0
  for block = 0; block < 200; block = block + 1 {
    emitted += processor.push(Array::make(31, 0.2)).length()
    assert_true(
      processor.buffered_frames() <= 2 * processor.latency_frames() + 4,
    )
  }
  assert_true(emitted > 7900)
  emitted += processor.finish().length()
  assert_eq(emitted, (6200.0 / 0.77 + 0.5).floor().to_int())
  assert_eq(processor.buffered_frames(), 0)
}

///|
test "eight independent channels remain independent" {
  let input : Array[Double] = []
  for frame = 0; frame < 257; frame = frame + 1 {
    for channel = 0; channel < 8; channel = channel + 1 {
      input.push(channel.to_double() * 0.1)
    }
  }
  let output = convert(input, 8, 2.5, 17)
  for i = 0; i < output.length(); i = i + 1 {
    assert_true((output[i] - (i % 8).to_double() * 0.1).abs() < 1.0e-12)
  }
}
