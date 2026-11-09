///|
/// Stable 120 BPM training pulses -> estimate -> 90 BPM practice PCM.
fn main {
  try {
    let sample_rate = 8000
    let input = Array::makei(sample_rate * 8, i => {
      let position = i % 4000
      if position < 400 {
        0.4 *
        @math.exp(-position.to_double() / 80.0) *
        @math.sin(2.0 * @math.PI * 140.0 * i.to_double() / 8000.0)
      } else {
        0.0
      }
    })
    let estimate = @bpm.analyze(input, sample_rate, 1)
    match estimate {
      None => abort("expected stable beat estimate")
      Some(beat) => {
        let output = @moonstretch.process(
          input,
          sample_rate,
          1,
          tempo=90.0 / beat.bpm,
          pitch_semitones=2.0,
        )
        println(
          "Estimated \{beat.bpm} BPM (periodicity \{beat.confidence}); target 90 BPM; \{output.length()} output frames",
        )
      }
    }
  } catch {
    error => abort((error : Error).to_string())
  }
}
