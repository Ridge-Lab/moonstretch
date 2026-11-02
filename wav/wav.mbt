///|
/// WAV integration using the existing MoonWavKit decoder and encoder.
/// This package contains no second RIFF parser. The processing core itself has
/// no file format dependency. Output is 24-bit PCM at the source sample rate.
pub fn transform(
  input : Bytes,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
) -> Bytes raise @types.AudioError {
  let decoded = @wavkit.parse_and_decode(input.to_array().map(b => b.to_int()))
  if !decoded.ok {
    raise @types.AudioError("WAV decode: " + decoded.error.message)
  }
  let source = decoded.float_buffer
  let output = @moonstretch.process(
    source.samples,
    source.sample_rate,
    source.channels,
    tempo~,
    pitch_semitones~,
    rate~,
  )
  encode(output, source.sample_rate, source.channels)
}

///|
/// Encode 24-bit PCM using MoonWavKit. Samples outside [-1,1] are clipped
/// by the integer encoder; the floating-point processing core does not clip.
pub fn encode(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
) -> Bytes raise @types.AudioError {
  @types.validate_format(sample_rate, channels)
  @types.validate_samples(samples, channels)
  let encoded = @wavkit.build_wav_from_float(
    @wavkit.FloatBuffer::new(channels, sample_rate, samples),
    encoding=@wavkit.PcmS24,
  )
  if !encoded.ok {
    raise @types.AudioError("WAV encode: " + encoded.error.message)
  }
  Bytes::from_array(encoded.bytes.map(b => b.to_byte()))
}
