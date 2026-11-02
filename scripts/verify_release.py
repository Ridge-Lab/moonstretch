#!/usr/bin/env python3
"""Install the public package in a fresh consumer and exercise its APIs."""
import argparse
import pathlib
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--version', default='0.1.0')
p.add_argument('--targets', nargs='+', default=['js', 'wasm', 'wasm-gc', 'native'])
p.add_argument('--output', default='work/release-consumer')
a = p.parse_args()
root = pathlib.Path(a.output).resolve()
root.mkdir(parents=True, exist_ok=True)
(root / 'moon.mod').write_text(f'''name = "verify/moonstretch_consumer"
version = "0.0.0"
import {{ "Ridge-Lab/moonstretch@{a.version}" }}
''', encoding='utf-8')
(root / 'moon.pkg').write_text('''import {
  "Ridge-Lab/moonstretch",
  "Ridge-Lab/moonstretch/wav",
  "moonbitlang/core/math",
}
pkgtype(kind: "executable")
''', encoding='utf-8')
(root / 'main.mbt').write_text('''fn main {
  let input = Array::makei(8000, i => 0.3 * @math.sin(2.0 * @math.PI * 440.0 * i.to_double() / 8000.0))
  let stream = @moonstretch.Stream::new(8000, 1, tempo=0.75, pitch_semitones=3.0) catch { e => abort((e : Error).to_string()) }
  let output : Array[Double] = []
  for part = 0; part < 80; part = part + 1 {
    output.append(stream.push(input[part*100:part*100+100].to_owned()) catch { e => abort((e : Error).to_string()) })
  }
  output.append(stream.finish() catch { e => abort((e : Error).to_string()) })
  if output.length() != 10667 || stream.input_frames() != 8000L || stream.buffered_frames() != 0 { abort("invalid installed DSP result") }
  let bytes = @wav.encode(output, 8000, 1) catch { e => abort((e : Error).to_string()) }
  if bytes.length() != 32046 || bytes.unsafe_read_uint32_le(4).to_int() != bytes.length()-8 { abort("invalid installed WAV result") }
  let again = @wav.transform(bytes) catch { e => abort((e : Error).to_string()) }
  if again.length() != bytes.length() { abort("invalid installed WAV roundtrip") }
  println("Published package: streamed PCM, pitch/tempo, exact length and WAV adapter passed")
}
''', encoding='utf-8')
for command in [['moon', 'update'], ['moon', 'fmt']]:
    subprocess.run(command, cwd=root, check=True)
for target in a.targets:
    subprocess.run(['moon', 'check', '--target', target, '--deny-warn'], cwd=root, check=True)
    subprocess.run(['moon', 'run', '--target', target, '--release', '.'], cwd=root, check=True)
print(f'Published Ridge-Lab/moonstretch@{a.version} verified on: {", ".join(a.targets)}')
