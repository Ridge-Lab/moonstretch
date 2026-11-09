///|
fn rhythm(sample_rate : Int32, seconds : Int32, bpm : Double) -> Array[Double] {
  Array::makei(sample_rate * seconds, i => {
    let time = i.to_double() / sample_rate.to_double() - 0.125
    if time < 0.0 {
      return 0.0
    }
    let beat = @math.floor(time * bpm / 60.0)
    let elapsed = time - beat * 60.0 / bpm
    if elapsed >= 0.10 {
      return 0.0
    }
    let strength = 0.7 + (beat.to_int() % 5).to_double() * 0.075
    strength *
    @math.exp(-elapsed * 45.0) *
    (
      0.7 * @math.sin(2.0 * @math.PI * 140.0 * elapsed) +
      0.3 * @math.sin(2.0 * @math.PI * 910.0 * elapsed)
    )
  })
}

///|
fn result(value : @bpm.Estimate?) -> @bpm.Estimate {
  match value {
    Some(estimate) => estimate
    None => abort("expected a periodic rhythm estimate")
  }
}

///|
test "tempo estimates follow multiple periods and interpolated fractional lags" {
  for bpm in [60.0, 70.0, 90.0, 120.0, 137.0, 180.0, 200.0] {
    let estimate = result(@bpm.analyze(rhythm(8000, 12, bpm), 8000, 1))
    assert_true((estimate.bpm - bpm).abs() / bpm < 0.015)
    assert_true(estimate.confidence > 0.65 && estimate.confidence <= 1.0)
    assert_eq(estimate.analyzed_seconds, 12.0)
  }
}

///|
test "sample rate rational envelope clock and stereo phase do not alter tempo" {
  for sample_rate in [8000, 11025, 16000, 44100, 48000, 192000] {
    let mono = rhythm(sample_rate, 8, 123.0)
    let stereo = Array::makei(mono.length() * 2, i => {
      if i % 2 == 0 {
        mono[i / 2]
      } else {
        -mono[i / 2]
      }
    })
    let estimate = result(@bpm.analyze(stereo, sample_rate, 2))
    assert_true((estimate.bpm - 123.0).abs() / 123.0 < 0.015)
  }
}

///|
test "stream partitions including single frames preserve results exactly" {
  let input = rhythm(11025, 8, 137.0)
  input.append([0.1, -0.2, 0.4, 0.2, -0.1, 0.0, 0.0])
  let expected = result(@bpm.analyze(input, 11025, 1))
  for chunk in [1, 127, 4096, input.length()] {
    let detector = @bpm.Detector::new(11025, 1)
    let mut cursor = 0
    while cursor < input.length() {
      let end = (cursor + chunk).min(input.length())
      detector.push(input[cursor:end].to_owned())
      cursor = end
    }
    let actual = result(detector.finish())
    assert_eq(actual.bpm, expected.bpm)
    assert_eq(actual.confidence, expected.confidence)
    assert_eq(detector.input_frames(), input.length().to_int64())
    assert_eq(detector.buffered_envelope_frames(), 1601)
    assert_eq(result(detector.finish()).bpm, expected.bpm)
  }
}

///|
test "silence steady tones noise and insufficient recordings have no estimate" {
  assert_true(@bpm.analyze([], 8000, 1) is None)
  assert_true(@bpm.analyze(rhythm(8000, 3, 120.0), 8000, 1) is None)
  assert_true(@bpm.analyze(Array::make(80000, 0.0), 8000, 1) is None)
  for hz in [20.0, 25.0, 30.0, 41.0, 73.0, 99.0, 440.0, 1000.0] {
    let tone = Array::makei(80000, i => {
      0.5 * @math.sin(2.0 * @math.PI * hz * i.to_double() / 8000.0)
    })
    assert_true(@bpm.analyze(tone, 8000, 1) is None)
  }
  let mut seed = 731U
  let noise = Array::makei(80000, _ => {
    seed = seed * 1664525U + 1013904223U
    (seed >> 16).reinterpret_as_int().to_double() / 32768.0 - 1.0
  })
  assert_true(@bpm.analyze(noise, 8000, 1) is None)
  let mut strength = 0.0
  let mut next_change = 0
  let aperiodic = Array::makei(160000, i => {
    if i == next_change {
      seed = seed * 1664525U + 1013904223U
      strength = (seed >> 16).reinterpret_as_int().to_double() / 65536.0
      seed = seed * 1664525U + 1013904223U
      next_change = i + 400 + (seed >> 16).reinterpret_as_int() % 4000
    }
    noise[i % noise.length()] * strength
  })
  assert_true(@bpm.analyze(aperiodic, 8000, 1) is None)
}

///|
test "energy normalization tolerates quiet loud and multichannel material" {
  let source = rhythm(8000, 8, 117.0)
  let expected = result(@bpm.analyze(source, 8000, 1))
  for gain in [1.0e-12, 0.001, 2.0, 1.0e90] {
    let scaled = source.map(x => x * gain)
    let actual = result(@bpm.analyze(scaled, 8000, 1))
    assert_true((actual.bpm - expected.bpm).abs() < 1.0e-9)
  }
  let eight = Array::makei(source.length() * 8, i => {
    let channel = i % 8
    if channel % 2 == 0 {
      source[i / 8] * (channel + 1).to_double() / 8.0
    } else {
      -source[i / 8] * (channel + 1).to_double() / 8.0
    }
  })
  assert_true((result(@bpm.analyze(eight, 8000, 8)).bpm - 117.0).abs() < 1.0)
}

///|
test "bounded rolling window tracks new material and reset discards history" {
  let detector = @bpm.Detector::new(8000, 1, window_seconds=8)
  let slow = rhythm(8000, 8, 90.0)
  detector.push(slow)
  assert_true((result(detector.estimate()).bpm - 90.0).abs() < 1.0)
  let fast = rhythm(8000, 8, 150.0)
  for _ in 0..<5 {
    detector.push(fast)
    assert_true(detector.buffered_envelope_frames() <= 1600)
  }
  assert_eq(detector.input_frames(), 384000L)
  assert_true((result(detector.finish()).bpm - 150.0).abs() < 1.0)
  detector.reset()
  assert_eq(detector.input_frames(), 0L)
  assert_eq(detector.buffered_envelope_frames(), 0)
  assert_true(detector.estimate() is None)
  detector.push(slow)
  assert_true((result(detector.finish()).bpm - 90.0).abs() < 1.0)
}

///|
test "configured extended tempo range and exact range boundaries" {
  for bpm in [30.0, 45.0, 240.0, 300.0] {
    let estimate = result(
      @bpm.analyze(rhythm(8000, 16, bpm), 8000, 1, min_bpm=30.0, max_bpm=300.0),
    )
    assert_true((estimate.bpm - bpm).abs() / bpm < 0.015)
  }
}

///|
test "invalid formats ranges samples and lifecycle fail without input consumption" {
  for sample_rate in [0, 7999, 192001] {
    assert_true(
      try {
        ignore(@bpm.Detector::new(sample_rate, 1))
        false
      } catch {
        _ => true
      },
    )
  }
  for channels in [0, 9] {
    assert_true(
      try {
        ignore(@bpm.Detector::new(8000, channels))
        false
      } catch {
        _ => true
      },
    )
  }
  for minimum in [0.0, 301.0, 200.0, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      try {
        ignore(@bpm.Detector::new(8000, 1, min_bpm=minimum))
        false
      } catch {
        _ => true
      },
    )
  }
  for maximum in [59.0, 301.0, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      try {
        ignore(@bpm.Detector::new(8000, 1, max_bpm=maximum))
        false
      } catch {
        _ => true
      },
    )
  }
  for window in [0, 7, 61] {
    assert_true(
      try {
        ignore(@bpm.Detector::new(8000, 1, window_seconds=window))
        false
      } catch {
        _ => true
      },
    )
  }
  let detector = @bpm.Detector::new(8000, 2)
  for input in [[0.0], [0.0, 1.0 / 0.0], [0.0, 0.0 / 0.0], [0.0, 1.1e100]] {
    assert_true(
      try {
        detector.push(input)
        false
      } catch {
        _ => true
      },
    )
    assert_eq(detector.input_frames(), 0L)
  }
  ignore(detector.finish())
  assert_true(
    try {
      detector.push([])
      false
    } catch {
      _ => true
    },
  )
}
