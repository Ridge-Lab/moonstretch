///|
test "dynamic constant ratios retain rounded duration and partition invariance" {
  let input = tone(1903, 0.037)
  for ratio in [0.25, 0.73, 1.0, 1.7, 4.0] {
    let expected = new(1, ratio, dynamic=true)
    let whole = expected.push(input)
    whole.append(expected.finish())
    assert_eq(whole.length(), (1903.0 / ratio + 0.5).floor().to_int())
    for chunk in [1, 37, 256] {
      let processor = new(1, ratio, dynamic=true)
      let output : Array[Double] = []
      let mut cursor = 0
      while cursor < input.length() {
        let end = (cursor + chunk).min(input.length())
        output.append(processor.push(input[cursor:end].to_owned()))
        cursor = end
      }
      output.append(processor.finish())
      assert_eq(output, whole)
      assert_eq(processor.buffered_frames(), 0)
    }
  }
}

///|
test "dynamic unity keeps signed samples while retaining transition history" {
  let input = Array::makei(400, i => if i % 2 == 0 { -0.0 } else { 0.25 })
  let processor = new(1, 1.0, dynamic=true)
  let output = processor.push(input)
  assert_true(output.length() > 0 && output.length() < input.length())
  assert_true(processor.buffered_frames() >= 192)
  output.append(processor.finish())
  for i = 0; i < input.length(); i = i + 1 {
    assert_eq(output[i].reinterpret_as_int64(), input[i].reinterpret_as_int64())
  }
}

///|
test "dynamic rate changes cross unity without phase reset or pitch discontinuity" {
  let input = tone(16000, 0.013)
  let processor = new(1, 0.75, dynamic=true)
  let first = processor.push(input[:4000].to_owned())
  let mut source_clock = first.length().to_double() * 0.75
  let mut input_cursor = 4000
  for ratio in [2.0, 1.0, 0.5] {
    let old_frame = processor.next_frame
    let old_fraction = processor.fraction
    processor.set_rate(ratio)
    assert_eq(processor.next_frame, old_frame)
    assert_eq(processor.fraction, old_fraction)
    let output = processor.push(
      input[input_cursor:input_cursor + 4000].to_owned(),
    )
    assert_true(output.length() > 1000)
    for i = 0; i < output.length(); i = i + 1 {
      let expected = @math.sin(
        2.0 * @math.PI * 0.013 * (source_clock + i.to_double() * ratio),
      )
      assert_true((output[i] - expected).abs() < 0.0001)
    }
    source_clock += output.length().to_double() * ratio
    input_cursor += 4000
    assert_true(processor.buffered_frames() <= 388)
  }
  let tail = processor.finish()
  assert_true(tail.length() > 0)
  assert_eq(processor.buffered_frames(), 0)
  assert_eq(processor.finish(), [])
}

///|
test "dynamic rate lifecycle rejects invalid updates atomically and resets current controls" {
  expect_error(() => new(1, 1.0).set_rate(0.5))
  let processor = new(2, 1.0, dynamic=true)
  ignore(processor.push([0.3, -0.3]))
  for rate in [0.0, 4.1, 0.0 / 0.0, 1.0 / 0.0] {
    expect_error(() => processor.set_rate(rate))
    assert_eq(processor.rate, 1.0)
    assert_eq(processor.input_frames, 1L)
    assert_eq(processor.next_frame, 0L)
  }
  processor.set_rate(0.5)
  let output = processor.finish()
  assert_eq(output.length(), 4)
  assert_true((output[0] - 0.3).abs() < 1.0e-12)
  assert_true((output[1] + 0.3).abs() < 1.0e-12)
  expect_error(() => processor.set_rate(1.0))
  processor.reset()
  assert_eq(processor.rate, 0.5)
  assert_eq(processor.next_frame, 0L)
  assert_eq(processor.fraction, 0.0)
  ignore(processor.push([0.3, -0.3]))
  assert_eq(processor.finish(), output)
  processor.reset()
  assert_eq(processor.finish(), [])
}

///|
test "dynamic short tails round once at unity and both ratio extremes" {
  for ratio in [0.25, 0.33, 0.7, 0.999999, 1.0, 1.000001, 1.6, 4.0] {
    let processor = new(1, ratio, dynamic=true)
    for frames in [0, 1, 2, 7, 47, 48, 49, 191, 192, 193, 997] {
      processor.reset()
      let input = Array::make(frames, 0.375)
      let output = processor.push(input)
      output.append(processor.finish())
      assert_eq(
        output.length(),
        (frames.to_double() / ratio + 0.5).floor().to_int(),
      )
      for sample in output {
        assert_true((sample - 0.375).abs() < 1.0e-12)
      }
    }
  }
}

///|
test "dynamic maximum filter expansion uses retained history without lost channels" {
  let processor = new(8, 0.25, dynamic=true)
  for block = 0; block < 32; block = block + 1 {
    if block == 10 {
      processor.set_rate(4.0)
    }
    if block == 20 {
      processor.set_rate(1.0)
    }
    let input = Array::makei(127 * 8, i => (i % 8).to_double() * 0.1)
    let output = processor.push(input)
    for i = 0; i < output.length(); i = i + 1 {
      assert_true((output[i] - (i % 8).to_double() * 0.1).abs() < 1.0e-12)
    }
    assert_true(processor.buffered_frames() <= 388)
  }
  let tail = processor.finish()
  for i = 0; i < tail.length(); i = i + 1 {
    assert_true((tail[i] - (i % 8).to_double() * 0.1).abs() < 1.0e-12)
  }
}
