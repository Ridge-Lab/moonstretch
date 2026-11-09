// This worklet only consumes already transformed PCM. DSP runs in MoonBit.
class MoonStretchPlayer extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const configuration = options.processorOptions || {};
    this.channels = configuration.channels || 1;
    this.capacity = Math.max(128, Math.min(65536,
      Math.floor(configuration.queueFrames || sampleRate * 0.16)));
    this.startThreshold = Math.min(this.capacity,
      Math.max(128, Math.floor(configuration.startFrames || sampleRate * 0.08)));
    this.queue = [];
    this.head = 0;
    this.queuedFrames = 0;
    this.pendingFrames = 0;
    this.playedFrames = 0;
    this.underrunBlocks = 0;
    this.reportFrames = 0;
    this.started = false;
    this.ended = false;
    this.stopped = false;
    this.streamPort = null;
    this.port.onmessage = ({ data }) => {
      if (data.type === 'connect' && !this.streamPort && !this.stopped) {
        this.streamPort = data.port;
        this.streamPort.onmessage = ({ data: chunk }) => this.accept(chunk);
        this.streamPort.start();
        this.request();
      } else if (data.type === 'stop') {
        this.stop();
      }
    };
  }

  stop() {
    this.stopped = true;
    this.queue = [];
    this.head = 0;
    this.queuedFrames = 0;
    this.pendingFrames = 0;
    this.streamPort?.close();
    this.streamPort = null;
  }

  fail(message) {
    this.port.postMessage({ type: 'error', message });
    this.stop();
  }

  accept(data) {
    if (this.stopped || data.type !== 'chunk') return;
    const pcm = new Float32Array(data.samples);
    const frames = pcm.length / this.channels;
    if (!Number.isInteger(data.requested) || data.requested < 1
        || data.requested > this.pendingFrames || !Number.isInteger(frames)
        || frames > data.requested || this.queuedFrames + frames > this.capacity) {
      this.fail('播放缓冲协议错误。请停止后重试。');
      return;
    }
    this.pendingFrames -= data.requested;
    if (frames) {
      this.queue.push(pcm);
      this.queuedFrames += frames;
    }
    if (data.ended) this.ended = true;
    this.request();
  }

  request() {
    if (!this.streamPort || this.ended || this.stopped) return;
    while (this.queuedFrames + this.pendingFrames < this.capacity) {
      const frames = Math.min(2048, this.capacity - this.queuedFrames - this.pendingFrames);
      this.pendingFrames += frames;
      this.streamPort.postMessage({ type: 'request', frames });
    }
  }

  report() {
    this.port.postMessage({
      type: 'stats', queuedFrames: this.queuedFrames, pendingFrames: this.pendingFrames,
      playedFrames: this.playedFrames, underrunBlocks: this.underrunBlocks,
    });
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output?.length) return !this.stopped;
    for (const channel of output) channel.fill(0);
    if (this.stopped) return false;
    const frames = output[0].length;
    if (!this.started && (this.queuedFrames >= this.startThreshold
        || (this.ended && this.queuedFrames > 0))) {
      this.started = true;
      this.port.postMessage({ type: 'playing' });
    }
    let written = 0;
    if (this.started) {
      while (written < frames && this.queue.length) {
        const chunk = this.queue[0];
        const count = Math.min(frames - written, chunk.length / this.channels - this.head);
        for (let frame = 0; frame < count; frame += 1) {
          for (let channel = 0; channel < output.length; channel += 1) {
            output[channel][written + frame] = channel < this.channels
              ? chunk[(this.head + frame) * this.channels + channel] : 0;
          }
        }
        this.head += count;
        written += count;
        this.playedFrames += count;
        this.queuedFrames -= count;
        if (this.head === chunk.length / this.channels) {
          this.queue.shift();
          this.head = 0;
        }
      }
      if (written < frames && !this.ended) this.underrunBlocks += 1;
    }
    this.request();
    this.reportFrames += frames;
    if (this.reportFrames >= sampleRate / 5) {
      this.reportFrames = 0;
      this.report();
    }
    if (this.ended && this.queuedFrames === 0 && this.pendingFrames === 0) {
      this.report();
      this.port.postMessage({ type: 'ended', playedFrames: this.playedFrames,
        underrunBlocks: this.underrunBlocks });
      this.stop();
      return false;
    }
    return true;
  }
}

registerProcessor('moonstretch-player', MoonStretchPlayer);
