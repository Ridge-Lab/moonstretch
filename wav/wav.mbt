///|
/// WAV integration using the existing MoonWavKit decoder and encoder.
/// Container framing checks and the documented MoonWavKit 0.1.3 compatibility
/// shims below do not implement a second sample codec. Output is 24-bit PCM.
pub fn transform(
  input : Bytes,
  tempo~ : Double = 1.0,
  pitch_semitones~ : Double = 0.0,
  rate~ : Double = 1.0,
) -> Bytes raise @types.AudioError {
  let bytes = input.to_array().map(b => b.to_int())
  let data_offset = checked_data_offset(bytes)
  let source = decode_with_empty_support(bytes, data_offset)
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
  // MoonWavKit 0.1.3 pads odd-sized PCM data but omits that byte from the
  // outer RIFF length. Correct the container length, leaving its codec intact.
  write_u32(encoded.bytes, 4, encoded.bytes.length() - 8)
  Bytes::from_array(encoded.bytes.map(b => b.to_byte()))
}

///|
fn write_u32(bytes : Array[Int32], offset : Int32, value : Int32) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    bytes[offset + i] = (value >> (8 * i)) & 255
  }
}

///|
/// Verify one complete RIFF/WAVE container and complete padded chunks. Sample
/// formats and values remain the existing codec's responsibility. Duplicate
/// fmt/data chunks are refused rather than silently choosing the last one.
fn checked_data_offset(bytes : Array[Int32]) -> Int32 raise @types.AudioError {
  let reader = @wavkit.ByteReader::new(bytes)
  if bytes.length() < 12 ||
    !reader.matches_ascii(0, 82, 73, 70, 70) ||
    !reader.matches_ascii(8, 87, 65, 86, 69) {
    raise @types.AudioError("WAV input must be a RIFF/WAVE container")
  }
  if reader.u32_le_at(4) != bytes.length() - 8 {
    raise @types.AudioError(
      "WAV RIFF size does not match the input byte length",
    )
  }
  let mut offset = 12
  let mut data_offset = -1
  let mut formats = 0
  while offset < bytes.length() {
    if bytes.length() - offset < 8 {
      raise @types.AudioError("WAV contains a truncated chunk header")
    }
    let size = reader.u32_le_at(offset + 4)
    let remaining = bytes.length() - offset - 8
    if size < 0 || size > remaining || size % 2 > remaining - size {
      raise @types.AudioError("WAV chunk payload or padding is truncated")
    }
    let id = reader.fourcc_at(offset)
    if id == "fmt " {
      formats = formats + 1
      if formats > 1 {
        raise @types.AudioError("WAV has more than one fmt chunk")
      }
    }
    if id == "data" {
      if data_offset >= 0 {
        raise @types.AudioError("WAV has more than one data chunk")
      }
      data_offset = offset + 8
    }
    offset = offset + 8 + size + size % 2
  }
  if data_offset < 0 {
    raise @types.AudioError("WAV is missing its data chunk")
  }
  data_offset
}

///|
/// MoonWavKit 0.1.3 rejects an otherwise valid empty data chunk and discards
/// the parsed format on that error. Insert a two-byte probe into a private copy
/// solely to reuse its fmt validation, then return an empty PCM buffer. The
/// dummy byte is never decoded, processed, or emitted.
fn decode_with_empty_support(
  bytes : Array[Int32],
  data_offset : Int32,
) -> @wavkit.FloatBuffer raise @types.AudioError {
  let reader = @wavkit.ByteReader::new(bytes)
  if reader.u32_le_at(data_offset - 4) == 0 {
    let probe = bytes[:data_offset].to_owned()
    probe.append([0, 0])
    probe.append(bytes[data_offset:].to_owned())
    write_u32(probe, data_offset - 4, 1)
    write_u32(probe, 4, probe.length() - 8)
    let parsed = @wavkit.parse_wav(probe)
    if !parsed.ok {
      raise @types.AudioError("WAV format: " + parsed.error.message)
    }
    if !parsed.wav.format.is_supported() {
      raise @types.AudioError("unsupported WAV sample format")
    }
    return @wavkit.FloatBuffer::new(
      parsed.wav.format.channels,
      parsed.wav.format.sample_rate,
      [],
    )
  }
  let parsed = @wavkit.parse_wav(bytes)
  if !parsed.ok {
    raise @types.AudioError("WAV parse: " + parsed.error.message)
  }
  if parsed.wav.format.is_float() && parsed.wav.format.bits_per_sample == 32 {
    // The old decoder maps NaN and infinities to zero. Reject those values
    // before decoding so malformed floating PCM cannot silently become silence.
    let mut offset = parsed.wav.data_offset
    let end = offset + parsed.wav.data_size
    while end - offset >= 4 {
      if (reader.u32_le_at(offset) & 0x7f800000) == 0x7f800000 {
        raise @types.AudioError("WAV floating samples must be finite")
      }
      offset = offset + 4
    }
  }
  let decoded = @wavkit.decode_pcm(
    bytes,
    parsed.wav,
    options=@wavkit.DecodeOptions::new(clamp=false),
  )
  if !decoded.ok {
    raise @types.AudioError("WAV decode: " + decoded.error.message)
  }
  decoded.float_buffer
}
