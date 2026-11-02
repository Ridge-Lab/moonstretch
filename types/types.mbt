///|
pub(all) suberror AudioError {
  AudioError(String)
}

///|
/// Interleaved PCM uses 1 to 8 channels and a declared sample rate.
pub fn validate_format(
  sample_rate : Int32,
  channels : Int32,
) -> Unit raise AudioError {
  if sample_rate < 8000 || sample_rate > 192000 {
    raise AudioError("sample_rate must be between 8000 and 192000 Hz")
  }
  if channels < 1 || channels > 8 {
    raise AudioError("channels must be between 1 and 8")
  }
}

///|
pub fn validate_samples(
  samples : Array[Double],
  channels : Int32,
) -> Unit raise AudioError {
  if channels < 1 || samples.length() % channels != 0 {
    raise AudioError("interleaved input must contain complete frames")
  }
  for sample in samples {
    if sample.is_nan() || sample.is_inf() || sample.abs() > 1.0e100 {
      raise AudioError(
        "PCM samples must be finite and have absolute value <= 1e100",
      )
    }
  }
}

///|
pub fn validate_ratio(
  value : Double,
  minimum : Double,
  maximum : Double,
  name : String,
) -> Unit raise AudioError {
  if value.is_nan() || value.is_inf() || value < minimum || value > maximum {
    raise AudioError("\{name} must be between \{minimum} and \{maximum}")
  }
}
