///|
/// A decoder/player adapter: input arrives in 256-frame blocks, a device consumes
/// 128-frame blocks, and the same processor receives a live control change.
fn main {
  try {
    let processor = @moonstretch.Processor::new(
      16000,
      2,
      quality=@moonstretch.Speech,
    )
    let device = Array::make(256, 0.0)
    let mut consumed = 0L
    for block in 0..<125 {
      if block == 60 {
        processor.set_controls(tempo=0.75, pitch_semitones=3.0, rate=1.0)
      }
      let input = Array::makei(512, i => {
        let phase = (block * 256 + i / 2).to_double() *
          2.0 *
          @math.PI *
          440.0 /
          16000.0
        @math.sin(phase) * (if i % 2 == 0 { 0.2 } else { -0.2 })
      })
      processor.put_samples(input)
      while processor.num_samples() >= 128 {
        consumed += processor.read_into(device, 0, 128).to_int64()
        // Supply the populated frames to an existing audio device here.
      }
    }
    processor.finish()
    while processor.num_samples() > 0 {
      consumed += processor.read_into(device, 0, 128).to_int64()
    }
    assert_eq(consumed, processor.output_frames())
    assert_eq(processor.buffered_frames(), 0)
    println(
      "Live decoder/player pipeline: \{processor.input_frames()} input frames, \{consumed} consumed frames",
    )
  } catch {
    error => abort((error : Error).to_string())
  }
}
