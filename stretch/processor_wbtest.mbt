///|
fn tone(frames : Int32, rate : Int32, frequency : Double) -> Array[Double] {
  Array::makei(frames, fn(i) {
    0.7 *
    @math.sin(6.283185307179586 * frequency * i.to_double() / rate.to_double())
  })
}

///|
fn run_chunks(
  samples : Array[Double],
  channels : Int32,
  tempo : Double,
  chunk_frames : Int32,
) -> Array[Double] raise {
  let processor = new(8000, channels, tempo)
  let output : Array[Double] = []
  let mut cursor = 0
  while cursor < samples.length() {
    let end = if cursor + chunk_frames * channels < samples.length() {
      cursor + chunk_frames * channels
    } else {
      samples.length()
    }
    for value in processor.push(samples[cursor:end].to_owned()) {
      output.push(value)
    }
    assert_true(processor.buffered_frames() <= 1200)
    cursor = end
  }
  for value in processor.finish() {
    output.push(value)
  }
  assert_eq(processor.buffered_frames(), 0)
  assert_eq(processor.input_frames(), (samples.length() / channels).to_int64())
  assert_eq(processor.output_frames(), (output.length() / channels).to_int64())
  output
}

///|
/// Independent pitch measure from positive-going zero crossings, ignoring
/// startup and drained boundaries. This checks signal behavior, not internals.
fn measured_frequency(samples : Array[Double], rate : Double) -> Double {
  let start = samples.length() / 5
  let end = samples.length() * 4 / 5
  let mut first = -1.0
  let mut last = -1.0
  let mut count = 0
  for i = start + 1; i < end; i = i + 1 {
    if samples[i - 1] <= 0.0 && samples[i] > 0.0 {
      let x = (i - 1).to_double() -
        samples[i - 1] / (samples[i] - samples[i - 1])
      if first < 0.0 {
        first = x
      }
      last = x
      count = count + 1
    }
  }
  if count < 2 {
    0.0
  } else {
    (count - 1).to_double() * rate / (last - first)
  }
}

///|
test "identity is immediate exact and returns independent storage" {
  let processor = new(44100, 2, 1.0)
  let input = [0.0, -0.0, 0.25, -0.25, 1.0, -1.0]
  let output = processor.push(input)
  for i = 0; i < input.length(); i = i + 1 {
    assert_eq(
      output[i].reinterpret_as_uint64(),
      input[i].reinterpret_as_uint64(),
    )
  }
  input[2] = 10.0
  assert_eq(output[2], 0.25)
  assert_eq(processor.latency_frames(), 0)
  assert_eq(processor.buffered_frames(), 0)
  assert_eq(processor.finish().length(), 0)
}

///|
test "WSOLA preserves tone pitch across its tempo range" {
  let input = tone(12000, 8000, 233.0)
  for tempo in [0.25, 0.5, 0.73, 1.3, 2.0, 4.0] {
    let output = run_chunks(input, 1, tempo, 137)
    let expected = @math.floor(12000.0 / tempo + 0.5).to_int()
    assert_eq(output.length(), expected)
    let measured = measured_frequency(output, 8000.0)
    assert_true(
      (measured - 233.0).abs() < 3.0,
      msg="tempo=\{tempo}, frequency=\{measured}",
    )
  }
}

///|
test "input partition does not affect samples or output length" {
  let input = Array::makei(7123, fn(i) {
    let t = i.to_double()
    0.4 * @math.sin(t * 0.173) +
    0.2 * @math.sin(t * 0.037) +
    (if i % 503 == 0 { 0.15 } else { 0.0 })
  })
  for tempo in [0.25, 0.61, 1.7, 4.0] {
    let whole = run_chunks(input, 1, tempo, 10000)
    for chunk in [1, 7, 159, 160, 161, 601] {
      assert_eq(run_chunks(input, 1, tempo, chunk), whole)
    }
  }
}

///|
test "all channels share alignment including anti-phase stereo" {
  let mono = tone(6400, 8000, 197.0)
  let stereo = Array::makei(mono.length() * 2, fn(i) {
    if i % 2 == 0 {
      mono[i / 2]
    } else {
      -mono[i / 2]
    }
  })
  for tempo in [0.5, 1.5, 3.0] {
    let output = run_chunks(stereo, 2, tempo, 113)
    for frame = 0; frame < output.length() / 2; frame = frame + 1 {
      assert_true((output[frame * 2] + output[frame * 2 + 1]).abs() < 1.0e-14)
    }
    let left = Array::makei(output.length() / 2, fn(i) { output[i * 2] })
    assert_true((measured_frequency(left, 8000.0) - 197.0).abs() < 3.0)
  }
}

///|
test "short empty and exact tail lengths finish once" {
  for frames in [0, 1, 2, 7, 159, 160, 161, 319, 320, 321, 997] {
    for tempo in [0.25, 0.33, 0.7, 1.0, 1.6, 2.0, 4.0] {
      let processor = new(8000, 1, tempo)
      let output = processor.push(tone(frames, 8000, 313.0))
      for value in processor.finish() {
        output.push(value)
      }
      assert_eq(
        output.length(),
        @math.floor(frames.to_double() / tempo + 0.5).to_int(),
      )
      assert_eq(processor.finish().length(), 0)
      assert_eq(processor.buffered_frames(), 0)
      for value in output {
        assert_true(!value.is_nan() && !value.is_inf())
      }
    }
  }
}

///|
test "incremental output and bounded retained PCM on a long stream" {
  let input = tone(317, 8000, 123.0)
  for tempo in [0.25, 0.91, 1.7, 4.0] {
    let processor = new(8000, 1, tempo)
    let mut frames_out = 0
    for block = 0; block < 150; block = block + 1 {
      frames_out = frames_out + processor.push(input).length()
      assert_true(processor.buffered_frames() <= 1200)
      if block >= 3 {
        assert_true(frames_out > 0)
      }
    }
    frames_out = frames_out + processor.finish().length()
    assert_eq(
      frames_out,
      @math.floor((150 * 317).to_double() / tempo + 0.5).to_int(),
    )
  }
}

///|
test "invalid input is rejected without advancing the stream" {
  let processor = new(8000, 2, 1.3)
  assert_true(
    try {
      ignore(processor.push([0.2]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(processor.push([0.0 / 0.0, 0.0]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(processor.push([1.0 / 0.0, 0.0]))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(processor.input_frames(), 0L)
  assert_eq(processor.output_frames(), 0L)
  assert_eq(processor.buffered_frames(), 0)
  ignore(processor.push([0.1, -0.1]))
  ignore(processor.finish())
  assert_true(
    try {
      ignore(processor.push([]))
      false
    } catch {
      _ => true
    },
  )
  processor.reset()
  assert_eq(processor.input_frames(), 0L)
  assert_eq(processor.output_frames(), 0L)
  assert_eq(processor.buffered_frames(), 0)
  ignore(processor.push([0.1, -0.1]))
}

///|
test "format and tempo reject invalid constructor parameters" {
  assert_true(
    try {
      ignore(new(7999, 1, 1.0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(new(192001, 1, 1.0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(new(48000, 0, 1.0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(new(48000, 9, 1.0))
      false
    } catch {
      _ => true
    },
  )
  for tempo in [-1.0, 0.0, 0.249, 4.001, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      try {
        ignore(new(48000, 1, tempo))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "192 kHz eight-channel stream remains finite and aligned" {
  let processor = new(192000, 8, 1.5)
  let input = Array::makei(16000 * 8, fn(i) {
    let wave = @math.sin((i / 8).to_double() * 0.037)
    if i % 8 % 2 == 0 {
      wave
    } else {
      -wave
    }
  })
  let output = processor.push(input)
  assert_true(processor.buffered_frames() < 20000)
  for value in processor.finish() {
    output.push(value)
  }
  assert_eq(output.length(), 10667 * 8)
  for i = 0; i < output.length(); i = i + 2 {
    assert_true((output[i] + output[i + 1]).abs() < 1.0e-14)
  }
}

///|
test "large finite sample magnitudes do not overflow correlation" {
  let input = Array::makei(2000, fn(i) {
    @math.sin(i.to_double() * 0.071) * 1.0e100
  })
  let output = run_chunks(input, 1, 0.7, 103)
  for value in output {
    assert_true(!value.is_nan() && !value.is_inf())
  }
  let near_max = run_chunks(Array::make(1500, 1.0e100), 1, 0.7, 103)
  for value in near_max {
    assert_true(!value.is_nan() && !value.is_inf())
  }
}

///|
test "silence and constant tails do not depend on search ordering" {
  for level in [0.0, 0.3, -0.3] {
    let input = Array::make(4800, level)
    let output = run_chunks(input, 1, 0.5, 103)
    for i = 640; i < output.length() - 960; i = i + 1 {
      assert_true((output[i] - level).abs() < 1.0e-14)
    }
  }
}
