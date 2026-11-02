///|
test "existing WAV codec decodes and encodes the transformed recording" {
  let input = @wavkit.build_wav_from_float(
    @wavkit.FloatBuffer::new(1, 16000, Array::make(1000, 0.125)),
    encoding=@wavkit.PcmS16,
  )
  assert_true(input.ok)
  let result = @wav.transform(
    Bytes::from_array(input.bytes.map(b => b.to_byte())),
    tempo=0.5,
  )
  let decoded = @wavkit.parse_and_decode(result.to_array().map(b => b.to_int()))
  assert_true(decoded.ok)
  assert_eq(decoded.float_buffer.sample_rate, 16000)
  assert_eq(decoded.float_buffer.channels, 1)
  assert_eq(decoded.float_buffer.samples.length(), 2000)
}

///|
test "malformed WAV is rejected" {
  assert_true(
    try {
      ignore(@wav.transform(b"not wave"))
      false
    } catch {
      _ => true
    },
  )
}
