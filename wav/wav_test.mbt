///|
test "odd PCM24 data includes its pad in RIFF length" {
  let output = @wav.encode([0.25], 8000, 1)
  assert_eq(output.length(), 48)
  assert_eq(output[4].to_int(), 40)
  assert_eq(output[40].to_int(), 3)
  assert_eq(output[47].to_int(), 0)
  assert_eq(@wav.transform(output).length(), 48)
}

///|
test "empty WAV preserves validated format and remains empty" {
  for channels in [1, 2, 8] {
    let input = @wav.encode([], 48000, channels)
    assert_eq(input.length(), 44)
    let output = @wav.transform(
      input,
      tempo=0.5,
      pitch_semitones=12.0,
      rate=2.0,
    )
    assert_eq(output.length(), 44)
    assert_eq(output[22].to_int(), channels)
    assert_eq(output[40].to_int(), 0)
  }
}

///|
test "outer RIFF extent and missing chunk padding are rejected" {
  let valid = @wav.encode([0.1], 8000, 1)
  let wrong = valid.to_array()
  wrong[4] = 39
  assert_true(
    try {
      ignore(@wav.transform(Bytes::from_array(wrong)))
      false
    } catch {
      _ => true
    },
  )
  let truncated = valid[:47].to_owned().to_array()
  truncated[4] = 39
  assert_true(
    try {
      ignore(@wav.transform(Bytes::from_array(truncated)))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(@wav.transform(b"RIFF"))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "WAV rejects non-finite float samples before legacy codec sanitization" {
  let values = @wav.encode([0.0], 8000, 1).to_array()
  values[20] = 3
  values[28] = 0
  values[29] = 125
  values[32] = 4
  values[34] = 32
  values[40] = 4
  values[44] = 0
  values[45] = 0
  values[46] = 192
  values[47] = 127
  assert_true(
    try {
      ignore(@wav.transform(Bytes::from_array(values)))
      false
    } catch {
      _ => true
    },
  )
  values[46] = 128
  assert_true(
    try {
      ignore(@wav.transform(Bytes::from_array(values)))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "empty input still validates requested DSP controls" {
  let input = @wav.encode([], 8000, 1)
  assert_true(
    try {
      ignore(@wav.transform(input, tempo=0.0))
      false
    } catch {
      _ => true
    },
  )
}
