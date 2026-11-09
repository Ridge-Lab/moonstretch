///|
test "pull processor handles decoder blocks and fixed device quanta" {
  let input = Array::makei(4000, i => @math.sin(i.to_double() * 0.07) * 0.2)
  let expected = @moonstretch.process(
    input,
    8000,
    2,
    tempo=0.7,
    pitch_semitones=3.0,
  )
  let processor = @moonstretch.Processor::new(
    8000,
    2,
    tempo=0.7,
    pitch_semitones=3.0,
    adjustable=false,
  )
  let output : Array[Double] = []
  let block = Array::make(260, 99.0)
  let mut cursor = 0
  while cursor < input.length() {
    let end = (cursor + 74).min(input.length())
    processor.put_samples(input[cursor:end].to_owned())
    while processor.num_samples() >= 128 {
      assert_eq(processor.read_into(block, 1, 128), 128)
      assert_eq(block[0], 99.0)
      assert_eq(block[259], 99.0)
      output.append(block[2:258].to_owned())
    }
    cursor = end
  }
  processor.finish()
  processor.finish()
  while processor.num_samples() > 0 {
    output.append(processor.receive_samples(31))
  }
  assert_eq(output, expected)
  assert_eq(processor.output_frames(), (expected.length() / 2).to_int64())
  assert_eq(processor.buffered_frames(), 0)
  assert_eq(processor.read_into(block, 0, 0), 0)
}

///|
test "FIFO rejects invalid reads without consuming queued audio" {
  let processor = @moonstretch.Processor::new(8000, 2, adjustable=false)
  processor.put_samples([0.1, 0.2, 0.3, 0.4])
  processor.finish()
  for (offset, count) in [(-1, 1), (0, -1), (3, 0), (1, 2), (0, 2147483647)] {
    assert_true(
      try {
        ignore(processor.read_into(Array::make(4, 0.0), offset, count))
        false
      } catch {
        _ => true
      },
    )
    assert_eq(processor.num_samples(), 2)
  }
  assert_true(
    try {
      ignore(processor.read_into([0.0], 0, 0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(processor.receive_samples(-1))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(processor.receive_samples(999), [0.1, 0.2, 0.3, 0.4])
}

///|
test "quality profiles retain the fixed duration and channel contracts" {
  for
    quality in [@moonstretch.Speech, @moonstretch.Balanced, @moonstretch.Music] {
    let samples = Array::makei(2400, i => if i % 2 == 0 { 0.25 } else { -0.25 })
    let stream = @moonstretch.Stream::new(
      8000,
      2,
      tempo=0.8,
      pitch_semitones=2.0,
      quality~,
    )
    assert_eq(stream.quality(), quality)
    let out = stream.push(samples)
    out.append(stream.finish())
    assert_eq(out.length(), 3000)
    for i in 0..<1500 {
      assert_true((out[2 * i] + out[2 * i + 1]).abs() < 1.0e-12)
    }
  }
  let speech = @moonstretch.Stream::new_live(
    48000,
    1,
    quality=@moonstretch.Speech,
  )
  let music = @moonstretch.Stream::new_live(
    48000,
    1,
    quality=@moonstretch.Music,
  )
  assert_true(speech.latency_frames() < music.latency_frames())
}

///|
test "live controls reject atomically and preserve the latest configuration on clear" {
  let processor = @moonstretch.Processor::new(8000, 1)
  processor.put_samples(Array::make(1600, 0.1))
  let before = processor.input_frames()
  assert_true(
    try {
      processor.set_controls(tempo=0.75, pitch_semitones=13.0, rate=1.0)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(processor.controls(), (1.0, 0.0, 1.0))
  assert_eq(processor.input_frames(), before)
  processor.set_controls(tempo=0.75, pitch_semitones=5.0, rate=0.9)
  processor.put_samples(Array::make(1600, -0.1))
  processor.finish()
  assert_true(
    try {
      processor.set_controls(tempo=1.0, pitch_semitones=0.0, rate=1.0)
      false
    } catch {
      _ => true
    },
  )
  processor.clear()
  assert_eq(processor.controls(), (0.75, 5.0, 0.9))
  assert_eq(processor.num_samples(), 0)
  assert_eq(processor.input_frames(), 0L)
  let first : Array[Double] = []
  processor.put_samples(Array::make(1000, 0.2))
  processor.finish()
  first.append(processor.receive_samples(10000))
  processor.clear()
  processor.put_samples(Array::make(1000, 0.2))
  processor.finish()
  assert_eq(processor.receive_samples(10000), first)
}

///|
test "live tempo pitch rate changes retain finite aligned multichannel output" {
  let processor = @moonstretch.Processor::new(8000, 2)
  let output : Array[Double] = []
  for
    (tempo, pitch, rate) in [
      (1.0, 0.0, 1.0),
      (0.7, 7.0, 1.2),
      (1.5, -5.0, 0.8),
      (1.0, 0.0, 1.0),
    ] {
    processor.set_controls(tempo~, pitch_semitones=pitch, rate~)
    processor.put_samples(
      Array::makei(8000, i => {
        let v = 0.2 * @math.sin((i / 2).to_double() * 0.2)
        if i % 2 == 0 {
          v
        } else {
          -v
        }
      }),
    )
    output.append(processor.receive_samples(100000))
  }
  processor.finish()
  output.append(processor.receive_samples(100000))
  assert_true(output.length() > 0)
  assert_eq(processor.input_frames(), 16000L)
  assert_eq(output.length().to_int64(), processor.output_frames() * 2L)
  for i in 0..<(output.length() / 2) {
    assert_true(!output[2 * i].is_nan() && !output[2 * i].is_inf())
    assert_true((output[2 * i] + output[2 * i + 1]).abs() < 1.0e-12)
  }
  assert_eq(processor.buffered_frames(), 0)
}
