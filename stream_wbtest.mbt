///|
test "timeline limit rejects atomically before either processing stage" {
  let stream = Stream::new(8000, 1)
  stream.received = 1000000000000L
  assert_true(
    try {
      ignore(stream.push([0.5]))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(stream.input_frames(), 1000000000000L)
  assert_eq(stream.stretch.input_frames(), 0L)
  assert_eq(stream.last_frame[0], 0.0)
}

///|
test "unsafe amplitudes fail before consuming a mixed valid and invalid chunk" {
  let stream = Stream::new(8000, 1, rate=0.7)
  for sample in [1.0e101, -1.0e101, 1.7976931348623157e308] {
    assert_true(
      try {
        ignore(stream.push([0.1, sample]))
        false
      } catch {
        _ => true
      },
    )
    assert_eq(stream.input_frames(), 0L)
    assert_eq(stream.buffered_frames(), 0)
  }
  let output = stream.push(Array::make(100, 1.0e99))
  output.append(stream.finish())
  for sample in output {
    assert_true(!sample.is_nan() && !sample.is_inf())
  }
}
