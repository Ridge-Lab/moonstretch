import { transform_pcm, encode_wav } from './engine.js';

self.onmessage = ({ data }) => {
  try {
    const input = Array.from(new Float32Array(data.samples));
    let samples = input;
    let processingMs = 0;
    if (data.mode === 'transform') {
      self.postMessage({ type: 'stage', message: '正在运行 MoonBit DSP…' });
      const started = performance.now();
      samples = transform_pcm(input, data.sampleRate, data.channels, data.tempo, data.pitch, data.rate);
      processingMs = performance.now() - started;
    }
    self.postMessage({ type: 'stage', message: '正在编码 WAV…' });
    const encoded = encode_wav(samples, data.sampleRate, data.channels);
    const wave = Uint8Array.from(encoded);
    const pcm = Float32Array.from(samples);
    self.postMessage({ type: 'result', samples: pcm.buffer, wave: wave.buffer, processingMs }, [pcm.buffer, wave.buffer]);
  } catch (error) {
    self.postMessage({ type: 'error', message: error?.message || String(error) });
  }
};
