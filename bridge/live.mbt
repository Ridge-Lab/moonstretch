///|
fn quality_named(name : String) -> @moonstretch.Quality raise @types.AudioError {
  match name {
    "speech" => @moonstretch.Speech
    "balanced" => @moonstretch.Balanced
    "music" => @moonstretch.Music
    _ => raise @types.AudioError("quality must be speech, balanced or music")
  }
}

///|
/// JavaScript callers can pass fractional/non-finite numbers to an Int-typed
/// export. Reject these before array offsets or DSP dimensions are calculated.
fn host_integer(
  value : Int32,
  name : String,
  minimum : Int32,
  maximum : Int32,
) -> Unit {
  let number = value.to_double()
  if number.is_nan() ||
    number.is_inf() ||
    number < minimum.to_double() ||
    number > maximum.to_double() ||
    number.to_int().to_double() != number {
    fail(name + " must be a finite integer within the supported range")
  }
}

///|
fn host_format(sample_rate : Int32, channels : Int32) -> Unit {
  host_integer(sample_rate, "sample_rate", 8000, 192000)
  host_integer(channels, "channels", 1, 8)
}

///|
pub fn transform_pcm_quality(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
  tempo : Double,
  pitch : Double,
  rate : Double,
  quality : String,
) -> Array[Double] {
  host_format(sample_rate, channels)
  @moonstretch.process(
    samples,
    sample_rate,
    channels,
    tempo~,
    pitch_semitones=pitch,
    rate~,
    quality=quality_named(quality),
  ) catch {
    error => fail(explain(error))
  }
}

///|
pub fn live_create(
  sample_rate : Int32,
  channels : Int32,
  tempo : Double,
  pitch : Double,
  rate : Double,
  quality : String,
) -> @moonstretch.Processor {
  host_format(sample_rate, channels)
  @moonstretch.Processor::new(
    sample_rate,
    channels,
    tempo~,
    pitch_semitones=pitch,
    rate~,
    quality=quality_named(quality),
  ) catch {
    error => fail(explain(error))
  }
}

///|
/// Fixed-control FIFO for file pipelines requiring the exact target duration.
pub fn fixed_create(
  sample_rate : Int32,
  channels : Int32,
  tempo : Double,
  pitch : Double,
  rate : Double,
  quality : String,
) -> @moonstretch.Processor {
  host_format(sample_rate, channels)
  @moonstretch.Processor::new(
    sample_rate,
    channels,
    tempo~,
    pitch_semitones=pitch,
    rate~,
    quality=quality_named(quality),
    adjustable=false,
  ) catch {
    error => fail(explain(error))
  }
}

///|
pub fn live_put(
  processor : @moonstretch.Processor,
  samples : Array[Double],
) -> Unit {
  processor.put_samples(samples) catch {
    error => fail(explain(error))
  }
}

///|
pub fn live_read(
  processor : @moonstretch.Processor,
  frames : Int32,
) -> Array[Double] {
  host_integer(frames, "frames", 0, 2147483647)
  processor.receive_samples(frames) catch {
    error => fail(explain(error))
  }
}

///|
pub fn live_set_controls(
  processor : @moonstretch.Processor,
  tempo : Double,
  pitch : Double,
  rate : Double,
) -> Unit {
  processor.set_controls(tempo~, pitch_semitones=pitch, rate~) catch {
    error => fail(explain(error))
  }
}

///|
pub fn live_finish(processor : @moonstretch.Processor) -> Unit {
  processor.finish() catch {
    error => fail(explain(error))
  }
}

///|
pub fn live_clear(processor : @moonstretch.Processor) -> Unit {
  processor.clear()
}

///|
pub fn live_stats(processor : @moonstretch.Processor) -> String {
  let (tempo, pitch, rate) = processor.controls()
  let result : Json = {
    "input_frames": processor.input_frames().to_double(),
    "output_frames": processor.output_frames().to_double(),
    "available_frames": processor.num_samples(),
    "buffered_frames": processor.buffered_frames(),
    "latency_frames": processor.latency_frames(),
    "tempo": tempo,
    "pitch": pitch,
    "rate": rate,
  }
  result.stringify()
}

///|
pub fn analyze_bpm(
  samples : Array[Double],
  sample_rate : Int32,
  channels : Int32,
  min_bpm : Double,
  max_bpm : Double,
) -> String {
  host_format(sample_rate, channels)
  try {
    match @bpm.analyze(samples, sample_rate, channels, min_bpm~, max_bpm~) {
      None => "null"
      Some(estimate) =>
        (
          {
            "bpm": estimate.bpm,
            "confidence": estimate.confidence,
            "analyzed_seconds": estimate.analyzed_seconds,
          } : Json).stringify()
    }
  } catch {
    error => fail(explain(error))
  }
}

///|
pub fn wav_decode(input : Bytes) -> @wav.Audio {
  @wav.decode(input) catch {
    error => fail(explain(error))
  }
}

///|
pub fn wav_samples(audio : @wav.Audio) -> Array[Double] {
  audio.samples
}

///|
pub fn wav_sample_rate(audio : @wav.Audio) -> Int32 {
  audio.sample_rate
}

///|
pub fn wav_channels(audio : @wav.Audio) -> Int32 {
  audio.channels
}
