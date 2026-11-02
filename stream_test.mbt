///|
test "composed controls preserve exact duration for short clips and extreme combinations" {
  for tempo in [0.5, 2.0] {
    for pitch in [-12.0, 12.0] {
      for rate in [0.5, 2.0] {
        for frames in [0, 1, 3, 127, 1001] {
          let input = Array::makei(frames * 2, i => {
            if i % 2 == 0 {
              0.2
            } else {
              -0.2
            }
          })
          let out = @moonstretch.process(
            input,
            8000,
            2,
            tempo~,
            pitch_semitones=pitch,
            rate~,
          )
          let expected = (frames.to_double() / (tempo * rate) + 0.5).to_int()
          assert_eq(out.length(), expected * 2)
          for i = 0; i < expected; i = i + 1 {
            assert_true(!out[2 * i].is_nan() && !out[2 * i].is_inf())
            assert_true((out[2 * i] + out[2 * i + 1]).abs() < 1.0e-12)
          }
        }
      }
    }
  }
}

///|
test "composed stream equals batch for different frame partitions" {
  let input = Array::makei(8000, i => (i % 97).to_double() / 97.0 - 0.5)
  let expected = @moonstretch.process(
    input,
    8000,
    1,
    tempo=0.83,
    pitch_semitones=5.0,
    rate=1.27,
  )
  for chunk in [1, 31, 333, 4000] {
    let stream = @moonstretch.Stream::new(
      8000,
      1,
      tempo=0.83,
      pitch_semitones=5.0,
      rate=1.27,
    )
    let out : Array[Double] = []
    let mut pos = 0
    while pos < input.length() {
      let end = (pos + chunk).min(input.length())
      out.append(stream.push(input[pos:end].to_owned()))
      pos = end
    }
    out.append(stream.finish())
    assert_eq(out.length(), expected.length())
    for i = 0; i < out.length(); i = i + 1 {
      assert_eq(out[i], expected[i])
    }
    assert_eq(stream.input_frames(), 8000L)
    assert_eq(stream.output_frames(), out.length().to_int64())
    assert_eq(stream.buffered_frames(), 0)
  }
}

///|
test "identity preserves signed zero and stream reset reproduces output" {
  let input = [0.0, -0.0, 0.25, -0.5, 0.0, 1.0]
  let stream = @moonstretch.Stream::new(48000, 2)
  for _ in 0..<2 {
    let out = stream.push(input)
    out.append(stream.finish())
    for i = 0; i < input.length(); i = i + 1 {
      assert_eq(out[i].reinterpret_as_int64(), input[i].reinterpret_as_int64())
    }
    assert_eq(stream.finish().length(), 0)
    stream.reset()
  }
}

///|
test "invalid input is rejected before consuming the stream" {
  let stream = @moonstretch.Stream::new(16000, 2, tempo=0.75)
  assert_true(
    try {
      ignore(stream.push([0.1]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(stream.push([0.0, 0.0 / 0.0]))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(stream.input_frames(), 0L)
  ignore(stream.push([0.1, -0.1]))
  ignore(stream.finish())
  assert_true(
    try {
      ignore(stream.push([]))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(stream.sample_rate(), 16000)
  assert_eq(stream.channels(), 2)
}

///|
test "controls reject nonfinite and out of range parameters" {
  for tempo in [0.0, 2.1, 1.0 / 0.0, 0.0 / 0.0] {
    assert_true(
      try {
        ignore(@moonstretch.Stream::new(8000, 1, tempo~))
        false
      } catch {
        _ => true
      },
    )
  }
  for pitch in [-13.0, 13.0, 0.0 / 0.0] {
    assert_true(
      try {
        ignore(@moonstretch.Stream::new(8000, 1, pitch_semitones=pitch))
        false
      } catch {
        _ => true
      },
    )
  }
}
