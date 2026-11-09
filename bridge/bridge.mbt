///|
fn number(
  obj : Map[String, Json],
  key : String,
  fallback : Double,
) -> Double raise @types.AudioError {
  match obj.get(key) {
    None => fallback
    Some(Number(n, ..)) => n
    _ => raise @types.AudioError("expected numeric " + key)
  }
}

///|
fn integer(
  obj : Map[String, Json],
  key : String,
  fallback : Int32,
) -> Int32 raise @types.AudioError {
  let value = number(obj, key, fallback.to_double())
  if value.is_nan() ||
    value.is_inf() ||
    value < 0.0 ||
    value > 2147483647.0 ||
    value.to_int().to_double() != value {
    raise @types.AudioError("expected nonnegative integer " + key)
  }
  value.to_int()
}

///|
/// JSON test/host interface; the DSP runs in MoonBit, hosts only move data.
pub fn run(request : String) -> String {
  try {
    let obj = match @json.parse(request) {
      Object(obj) => obj
      _ => raise @types.AudioError("expected request object")
    }
    let sample_rate = integer(obj, "sample_rate", 48000)
    let channels = integer(obj, "channels", 1)
    let tempo = number(obj, "tempo", 1.0)
    let pitch_semitones = number(obj, "pitch_semitones", 0.0)
    let rate = number(obj, "rate", 1.0)
    let chunk_frames = integer(obj, "chunk_frames", 1024)
    if chunk_frames < 1 || chunk_frames > 1048576 {
      raise @types.AudioError("chunk_frames must be 1..1048576")
    }
    let samples : Array[Double] = match obj.get("samples") {
      Some(Array(items)) =>
        items.map(fn(item) raise @types.AudioError {
          match item {
            Number(n, ..) => n
            _ => raise @types.AudioError("samples must be numbers")
          }
        })
      _ => raise @types.AudioError("expected samples array")
    }
    @types.validate_samples(samples, channels)
    let stream = @moonstretch.Stream::new(
      sample_rate,
      channels,
      tempo~,
      pitch_semitones~,
      rate~,
    )
    let output : Array[Double] = []
    let mut start = 0
    let mut peak_buffered = 0
    let mut first_output_at = -1
    while start < samples.length() {
      let end = (start + chunk_frames * channels).min(samples.length())
      let part = stream.push(samples[start:end].to_owned())
      if part.length() > 0 && first_output_at < 0 {
        first_output_at = end / channels
      }
      output.append(part)
      peak_buffered = peak_buffered.max(stream.buffered_frames())
      start = end
    }
    output.append(stream.finish())
    let result : Json = {
      "samples": Json::array(output.map(n => Json::number(n))),
      "sample_rate": sample_rate,
      "channels": channels,
      "peak_buffered_frames": peak_buffered,
      "first_output_at_input_frame": first_output_at,
      "latency_frames": stream.latency_frames(),
    }
    result.stringify()
  } catch {
    error => ({ "error": explain(error) } : Json).stringify()
  }
}

///|
/// Browser PCM bridge: returns interleaved PCM. Host UI supplies decoded PCM.
pub fn transform_pcm(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
  tempo : Double,
  pitch_semitones : Double,
  rate : Double,
) -> Array[Double] {
  host_format(sample_rate, channels)
  @moonstretch.process(
    samples,
    sample_rate,
    channels,
    tempo~,
    pitch_semitones~,
    rate~,
  ) catch {
    error => fail(explain(error))
  }
}

///|
/// WAV host bridge; decoding and encoding are provided by MoonWavKit.
pub fn transform_wav(
  input : Bytes,
  tempo : Double,
  pitch_semitones : Double,
  rate : Double,
) -> Bytes {
  @wav.transform(input, tempo~, pitch_semitones~, rate~) catch {
    error => fail(explain(error))
  }
}

///|
/// File export delegates to the existing WAV codec.
pub fn encode_wav(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
) -> Bytes {
  host_format(sample_rate, channels)
  @wav.encode(samples, sample_rate, channels) catch {
    error => fail(explain(error))
  }
}

///|
/// Preserve diagnostics across the JavaScript boundary. Native/Wasm hosts use
/// the explicit JSON interface when a recoverable error value is required.
fn[T] fail(message : String) -> T {
  host_fail(message)
  abort(message)
}

///|
/// Error::to_string identifies a suberror constructor but does not include
/// its String payload. Keep the actionable validation message at the host edge.
fn explain(error : Error) -> String {
  match error {
    @types.AudioError(message) => message
    _ => error.to_string()
  }
}
