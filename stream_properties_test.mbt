///|
/// A small specified generator keeps a failure replayable on every backend.
/// Its seed controls scheduling only, never the expected DSP output.
struct ReplayRng {
  mut state : UInt32
}

///|
fn ReplayRng::below(self : ReplayRng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525U + 1013904223U
  ((self.state >> 8) % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
fn replay_pcm(frames : Int32, channels : Int32) -> Array[Double] {
  Array::makei(frames * channels, i => {
    let frame = i / channels
    let a = 0.2 * @math.sin(frame.to_double() * 0.137) +
      ((frame * 37 % 101).to_double() - 50.0) * 0.001
    let b = 0.15 * @math.sin(frame.to_double() * 0.071)
    match i % channels {
      0 => a
      1 => -a
      2 => b
      3 => -b
      4 => 0.0
      5 => 2.0 * a
      6 => a + b
      _ => a - b
    }
  })
}

///|
/// Report the first mismatch and replay key instead of dumping whole recordings.
fn assert_replay_pcm(
  actual : Array[Double],
  expected : Array[Double],
  replay : String,
) -> Unit raise {
  if actual.length() != expected.length() {
    fail("\{replay}: sample count \{actual.length()} != \{expected.length()}")
  }
  for i in 0..<actual.length() {
    if actual[i] != expected[i] {
      fail("\{replay}: sample \{i}: \{actual[i]} != \{expected[i]}")
    }
  }
}

///|
/// Read with changing device quanta and guard samples around its destination.
/// Queue accounting is checked after every operation, not just at EOF.
fn replay_read(
  processor : @moonstretch.Processor,
  output : Array[Double],
  channels : Int32,
  rng : ReplayRng,
) -> Unit raise {
  let count = rng.below(194)
  let destination = Array::make((count + 2) * channels, 77.0)
  let available = processor.num_samples()
  let received = processor.read_into(destination, 1, count)
  assert_eq(received, count.min(available))
  for c in 0..<channels {
    assert_eq(destination[c], 77.0)
  }
  for i = (received + 1) * channels; i < destination.length(); i = i + 1 {
    assert_eq(destination[i], 77.0)
  }
  output.append(destination[channels:(received + 1) * channels].to_owned())
  assert_eq(
    output.length().to_int64() / channels.to_int64() +
    processor.num_samples().to_int64(),
    processor.output_frames(),
  )
}

///|
test "seeded live replay preserves output across producer partitions and consumer schedules" {
  for
    (seed, quality) in [
      (7U, @moonstretch.Speech),
      (73U, @moonstretch.Balanced),
      (20261110U, @moonstretch.Music),
    ] {
    for channels in [1, 2, 8] {
      let rng = ReplayRng::{ state: seed, }
      let reference = @moonstretch.Stream::new_live(8000, channels, quality~)
      let processor = @moonstretch.Processor::new(8000, channels, quality~)
      let input = replay_pcm(4003, channels)
      let expected : Array[Double] = []
      let actual : Array[Double] = []
      let mut cursor = 0
      for
        (end_frame, tempo, pitch, rate) in [
          (1, 1.0, 0.0, 1.0),
          (211, 0.5, 12.0, 2.0),
          (1051, 2.0, -12.0, 0.5),
          (2419, 0.73, 5.0, 1.27),
          (4003, 1.0, 0.0, 1.0),
        ] {
        reference.set_controls(tempo~, pitch_semitones=pitch, rate~)
        processor.set_controls(tempo~, pitch_semitones=pitch, rate~)
        expected.append(
          reference.push(
            input[cursor * channels:end_frame * channels].to_owned(),
          ),
        )
        while cursor < end_frame {
          let end = (cursor + 1 + rng.below(257)).min(end_frame)
          processor.put_samples(
            input[cursor * channels:end * channels].to_owned(),
          )
          assert_eq(processor.input_frames(), end.to_int64())
          // Empty producer calls and empty device reads must not change history.
          if rng.below(4) == 0 {
            processor.put_samples([])
          }
          for _ in 0..<rng.below(4) {
            replay_read(processor, actual, channels, rng)
          }
          cursor = end
        }
      }
      expected.append(reference.finish())
      processor.finish()
      processor.finish()
      // Bound draining so a future no-progress regression fails rather than hangs.
      for _ in 0..<(expected.length() + 1024) {
        if processor.num_samples() == 0 {
          break
        }
        replay_read(processor, actual, channels, rng)
      }
      assert_eq(processor.num_samples(), 0)
      assert_replay_pcm(actual, expected, "seed=\{seed}, channels=\{channels}")
      assert_eq(processor.buffered_frames(), 0)
      if channels == 8 {
        for frame in 0..<(actual.length() / 8) {
          let i = frame * 8
          assert_true((actual[i] + actual[i + 1]).abs() < 1.0e-12)
          assert_true((actual[i + 2] + actual[i + 3]).abs() < 1.0e-12)
          assert_eq(actual[i + 4], 0.0)
          assert_true((actual[i + 5] - 2.0 * actual[i]).abs() < 1.0e-12)
          assert_true(
            (actual[i + 6] - actual[i] - actual[i + 2]).abs() < 1.0e-12,
          )
          assert_true(
            (actual[i + 7] - actual[i] + actual[i + 2]).abs() < 1.0e-12,
          )
        }
      }
    }
  }
}

///|
test "rejected late invalid samples and controls leave subsequent PCM identical to a clean stream" {
  let input = replay_pcm(3101, 8)
  let clean = @moonstretch.Stream::new_live(
    8000,
    8,
    tempo=0.73,
    pitch_semitones=3.0,
  )
  let checked = @moonstretch.Stream::new_live(
    8000,
    8,
    tempo=0.73,
    pitch_semitones=3.0,
  )
  let expected = clean.push(input[:1033 * 8].to_owned())
  let actual = checked.push(input[:1033 * 8].to_owned())
  for bad in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, 1.0e101] {
    let invalid = input.copy()
    invalid[invalid.length() - 1] = bad
    assert_true(
      try {
        ignore(checked.push(invalid))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(checked.push([0.1]))
      false
    } catch {
      _ => true
    },
  )
  for
    (tempo, pitch, rate) in [
      (0.7, 3.0, 0.49),
      (2.1, 3.0, 1.0),
      (0.7, -12.1, 1.0),
      (0.7, 3.0, 0.0 / 0.0),
    ] {
    assert_true(
      try {
        checked.set_controls(tempo~, pitch_semitones=pitch, rate~)
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(checked.input_frames(), clean.input_frames())
  assert_eq(checked.output_frames(), clean.output_frames())
  assert_eq(checked.buffered_frames(), clean.buffered_frames())
  assert_eq(checked.controls(), clean.controls())
  expected.append(clean.push(input[1033 * 8:].to_owned()))
  actual.append(checked.push(input[1033 * 8:].to_owned()))
  expected.append(clean.finish())
  actual.append(checked.finish())
  assert_replay_pcm(actual, expected, "rejected input/control replay")
}
