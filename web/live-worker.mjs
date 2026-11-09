import * as engine from './engine.js';
import { StreamPump } from './live-pump.mjs';

let pump = null;
let streamPort = null;
let requests = [];
let pumping = false;
let stopped = false;

function fail(error) {
  self.postMessage({ type: 'error', message: error?.message || String(error) });
  stop();
}

function stop() {
  stopped = true;
  requests = [];
  pump?.clear();
  pump = null;
  streamPort?.close();
  streamPort = null;
}

async function drain() {
  if (pumping || stopped) return;
  pumping = true;
  try {
    while (requests.length && !stopped) {
      const requested = requests.shift();
      const part = await pump.pull(requested);
      if (stopped) break;
      const stats = pump.stats();
      streamPort.postMessage({
        type: 'chunk', samples: part.samples.buffer, requested, ended: part.ended,
      }, [part.samples.buffer]);
      self.postMessage({ type: 'stats', stats, sourceFinished: pump.finished });
    }
  } catch (error) {
    fail(error);
  } finally {
    pumping = false;
  }
}

self.onmessage = ({ data }) => {
  try {
    if (data.type === 'start') {
      if (pump || stopped) throw new Error('A worker can process one playback session');
      pump = new StreamPump(engine, {
        samples: new Float32Array(data.samples),
        sampleRate: data.sampleRate, channels: data.channels,
      }, data, () => new Promise((resolve) => setTimeout(resolve, 0)));
      streamPort = data.port;
      streamPort.onmessage = ({ data: request }) => {
        if (request.type !== 'request' || stopped) return;
        if (!Number.isInteger(request.frames) || request.frames < 1 || request.frames > 4096
            || requests.length >= 32) {
          fail(new Error('Invalid playback demand'));
          return;
        }
        requests.push(request.frames);
        void drain();
      };
      streamPort.start();
      self.postMessage({ type: 'ready', stats: pump.stats() });
    } else if (data.type === 'controls' && pump && !stopped) {
      const applied = pump.setControls(data);
      self.postMessage({ type: 'controls', applied, stats: pump.stats() });
    } else if (data.type === 'stop') {
      stop();
      self.postMessage({ type: 'stopped' });
      self.close();
    }
  } catch (error) {
    fail(error);
  }
};
