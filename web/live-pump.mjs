// Browser-independent demand adapter. The MoonBit processor owns all DSP state.
export class StreamPump {
  constructor(api, source, options, yieldTask = () => Promise.resolve()) {
    if (!(source.samples instanceof Float32Array) || !Number.isInteger(source.channels)
        || source.channels < 1 || source.channels > 8
        || source.samples.length % source.channels !== 0) {
      throw new Error('Invalid interleaved source');
    }
    this.api = api;
    this.source = source;
    this.offset = 0;
    this.finished = false;
    this.closed = false;
    this.yieldTask = yieldTask;
    this.processor = api.live_create(source.sampleRate, source.channels,
      options.tempo, options.pitch, options.rate, options.quality);
  }

  stats() {
    return JSON.parse(this.api.live_stats(this.processor));
  }

  setControls(options) {
    if (this.closed) throw new Error('Stream is closed');
    // Already rendered tail samples cannot be changed retroactively.
    if (this.finished) return false;
    this.api.live_set_controls(this.processor, options.tempo, options.pitch, options.rate);
    return true;
  }

  async pull(frames) {
    if (!Number.isInteger(frames) || frames < 1 || frames > 4096) {
      throw new Error('Requested output block must contain 1–4096 frames');
    }
    if (this.closed) return { samples: new Float32Array(), ended: true };
    const { samples, channels } = this.source;
    let turns = 0;
    while (this.stats().available_frames < frames && !this.finished && !this.closed) {
      if (this.offset < samples.length) {
        const end = Math.min(samples.length, this.offset + 1024 * channels);
        this.api.live_put(this.processor, Array.from(samples.subarray(this.offset, end)));
        this.offset = end;
      } else {
        this.api.live_finish(this.processor);
        this.finished = true;
      }
      turns += 1;
      if (turns % 4 === 0) await this.yieldTask();
    }
    if (this.closed) return { samples: new Float32Array(), ended: true };
    const output = Float32Array.from(this.api.live_read(this.processor, frames));
    return { samples: output, ended: this.finished && this.stats().available_frames === 0 };
  }

  clear() {
    if (this.closed) return;
    this.closed = true;
    this.api.live_clear(this.processor);
    this.source = { ...this.source, samples: new Float32Array() };
  }
}
