///|
fn main {
  let samples = Array::makei(16000, i => {
    0.3 * @math.sin(2.0 * @math.PI * 440.0 * i.to_double() / 16000.0)
  })
  let output = @moonstretch.process(
    samples,
    16000,
    1,
    tempo=0.75,
    pitch_semitones=3.0,
  ) catch {
    error => abort((error : Error).to_string())
  }
  println("MoonStretch: 16000 input frames -> \{output.length()} output frames")
  println("0.75x tempo, +3 semitones, 16000 Hz mono PCM")
}
