///|
test "configured windows preserve pitch and duration across speech balanced and music settings" {
  let input = tone(6000, 8000, 233.0)
  for
    (hop_ms, search_ms, quick) in [
      (10, 5, true),
      (20, 10, true),
      (40, 15, false),
    ] {
    let processor = new(8000, 1, 0.75, hop_ms~, search_ms~, quick~)
    let output = processor.push(input)
    output.append(processor.finish())
    assert_eq(output.length(), 8000)
    assert_true((measured_frequency(output, 8000.0) - 233.0).abs() < 3.0)
  }
  let no_search = new(8000, 1, 0.75, hop_ms=10, search_ms=0)
  let output = no_search.push(input)
  output.append(no_search.finish())
  assert_eq(output.length(), 8000)
  for (hop_ms, search_ms) in [(0, 5), (81, 5), (10, -1), (10, 41)] {
    assert_true(
      try {
        ignore(new(8000, 1, 1.0, hop_ms~, search_ms~))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "dynamic fixed controls have exact duration and chunk-independent samples" {
  let input = tone(3017, 8000, 233.0)
  for tempo in [0.25, 0.73, 1.0, 1.7, 4.0] {
    let whole_stream = new(8000, 1, tempo, dynamic=true)
    let whole = whole_stream.push(input)
    whole.append(whole_stream.finish())
    assert_eq(whole.length(), (3017.0 / tempo + 0.5).floor().to_int())
    for chunk in [1, 37, 199] {
      let processor = new(8000, 1, tempo, dynamic=true)
      let output : Array[Double] = []
      let mut cursor = 0
      while cursor < input.length() {
        let end = (cursor + chunk).min(input.length())
        output.append(processor.push(input[cursor:end].to_owned()))
        cursor = end
      }
      output.append(processor.finish())
      assert_eq(output, whole)
    }
  }
}

///|
test "dynamic tempo crosses unity with continuous source clock linked channels and stable pitch" {
  let input = tone(24000, 8000, 233.0)
  let stereo = Array::makei(input.length() * 2, i => {
    if i % 2 == 0 {
      input[i / 2]
    } else {
      -input[i / 2]
    }
  })
  let processor = new(8000, 2, 1.0, dynamic=true)
  let mut cursor = 0
  for tempo in [1.0, 0.5, 2.0, 1.0] {
    let old_clock = processor.analysis_frame
    let old_fraction = processor.analysis_fraction
    let old_emitted = processor.output_frames()
    processor.set_tempo(tempo)
    assert_eq(processor.analysis_frame, old_clock)
    assert_eq(processor.analysis_fraction, old_fraction)
    let output = processor.push(stereo[cursor:cursor + 12000].to_owned())
    assert_true(output.length() > 3000)
    assert_true(processor.analysis_frame > old_clock)
    assert_true(processor.output_frames() > old_emitted)
    assert_true(processor.buffered_frames() <= 1400)
    for frame = 0; frame < output.length() / 2; frame = frame + 1 {
      assert_true((output[frame * 2] + output[frame * 2 + 1]).abs() < 1.0e-12)
    }
    let left = Array::makei(output.length() / 2, i => output[i * 2])
    assert_true((measured_frequency(left, 8000.0) - 233.0).abs() < 3.0)
    cursor += 12000
  }
  ignore(processor.finish())
  assert_eq(processor.buffered_frames(), 0)
  assert_eq(processor.finish(), [])
}

///|
test "dynamic tempo validates before mutation and reset retains latest control" {
  let fixed = new(8000, 1, 1.0)
  assert_true(
    try {
      fixed.set_tempo(0.5)
      false
    } catch {
      _ => true
    },
  )
  let processor = new(8000, 1, 1.0, dynamic=true)
  ignore(processor.push([0.3]))
  for tempo in [0.0, 4.1, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      try {
        processor.set_tempo(tempo)
        false
      } catch {
        _ => true
      },
    )
    assert_eq(processor.tempo, 1.0)
    assert_eq(processor.analysis_frame, 0L)
    assert_eq(processor.input_frames(), 1L)
  }
  processor.set_tempo(0.5)
  let output = processor.finish()
  assert_eq(output.length(), 2)
  assert_true(
    try {
      processor.set_tempo(1.0)
      false
    } catch {
      _ => true
    },
  )
  processor.reset()
  assert_eq(processor.tempo, 0.5)
  assert_eq(processor.analysis_frame, 0L)
  assert_eq(processor.analysis_fraction, 0.0)
  ignore(processor.push([0.3]))
  assert_eq(processor.finish(), output)
  processor.reset()
  assert_eq(processor.finish(), [])
}

///|
test "dynamic short tails have one rounded duration including window boundaries" {
  for tempo in [0.25, 0.33, 0.7, 1.0, 1.6, 4.0] {
    let processor = new(8000, 1, tempo, dynamic=true)
    for frames in [0, 1, 2, 7, 159, 160, 161, 319, 320, 321, 997] {
      processor.reset()
      let output = processor.push(tone(frames, 8000, 313.0))
      output.append(processor.finish())
      assert_eq(
        output.length(),
        (frames.to_double() / tempo + 0.5).floor().to_int(),
      )
      for sample in output {
        assert_true(!sample.is_nan() && !sample.is_inf())
      }
    }
  }
}

///|
test "lookahead budget covers steady search and startup for each profile" {
  for
    (hop_ms, search_ms, quick) in [
      (10, 5, true),
      (20, 10, true),
      (40, 15, false),
    ] {
    for tempo in [0.25, 1.0, 4.0] {
      let processor = new(
        8000,
        1,
        tempo,
        hop_ms~,
        search_ms~,
        quick~,
        dynamic=true,
      )
      let budget = processor.latency_frames()
      assert_true(budget >= processor.search + 2 * processor.hop)
      let mut first_output_at = 0
      for frame = 1; frame <= budget; frame = frame + 1 {
        if processor.push([0.1]).length() > 0 && first_output_at == 0 {
          first_output_at = frame
        }
      }
      assert_true(first_output_at > 0 && first_output_at <= budget)
    }
  }
}
