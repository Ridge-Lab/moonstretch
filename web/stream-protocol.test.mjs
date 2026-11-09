import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { StreamPump } from './live-pump.mjs';

const workletSource = await readFile(new URL('./pcm-worklet.mjs', import.meta.url), 'utf8');

function player(channels = 2, capacity = 256) {
  class Port {
    constructor() { this.messages = []; this.closed = false; }
    postMessage(data) { this.messages.push(data); }
    start() {}
    close() { this.closed = true; }
  }
  let Player;
  class Base { constructor() { this.port = new Port(); } }
  vm.runInNewContext(workletSource, {
    AudioWorkletProcessor: Base, Float32Array, sampleRate: 48000,
    registerProcessor: (_name, Constructor) => { Player = Constructor; },
  });
  const value = new Player({ processorOptions: {
    channels, queueFrames: capacity, startFrames: 128,
  } });
  const port = new Port();
  value.port.onmessage({ data: { type: 'connect', port } });
  return { value, port, output: () => Array.from({ length: channels }, () => new Float32Array(128)) };
}

function send(p, frames, requested, ended = false) {
  const samples = Float32Array.from({ length: frames * p.value.channels }, (_, i) => i / 1000);
  p.port.onmessage({ data: { type: 'chunk', samples: samples.buffer, requested, ended } });
  return samples;
}

test('worklet bounds queued plus outstanding demand before and after playback', () => {
  const p = player();
  assert.equal(p.value.pendingFrames, 256);
  for (let i = 0; i < 20; i += 1) p.value.process([], [p.output()]);
  assert.equal(p.port.messages.length, 1);
  assert.equal(p.value.underrunBlocks, 0, 'startup is not an underrun');
  const original = send(p, 256, 256);
  const output = p.output();
  p.value.process([], [output]);
  for (let i = 0; i < 128; i += 1) {
    assert.equal(output[0][i], original[i * 2]);
    assert.equal(output[1][i], original[i * 2 + 1]);
  }
  assert.equal(p.value.queuedFrames + p.value.pendingFrames, 256);
  for (let i = 0; i < 20; i += 1) p.value.process([], [p.output()]);
  assert.equal(p.value.queuedFrames + p.value.pendingFrames, 256);
  assert.ok(p.value.underrunBlocks > 0);
});

test('worklet preserves a short tail and finishes without inventing PCM frames', () => {
  const p = player();
  const original = send(p, 162, 256, true);
  assert.equal(p.value.process([], [p.output()]), true);
  const tail = p.output();
  assert.equal(p.value.process([], [tail]), false);
  for (let frame = 0; frame < 34; frame += 1) {
    assert.equal(tail[0][frame], original[(128 + frame) * 2]);
    assert.equal(tail[1][frame], original[(128 + frame) * 2 + 1]);
  }
  assert.ok(tail[0].subarray(34).every((sample) => sample === 0));
  assert.equal(p.value.playedFrames, 162);
  assert.equal(p.value.underrunBlocks, 0);
  assert.equal(p.value.queuedFrames, 0);
  assert.equal(p.value.port.messages.at(-1).type, 'ended');
});

test('worklet rejects output exceeding granted demand', () => {
  const p = player();
  send(p, 257, 256);
  assert.equal(p.value.stopped, true);
  assert.equal(p.value.queuedFrames, 0);
  assert.equal(p.value.port.messages.at(-1).type, 'error');
});

test('worklet stop closes the stream port and releases pending buffers', () => {
  const p = player();
  send(p, 256, 256);
  p.value.port.onmessage({ data: { type: 'stop' } });
  assert.equal(p.port.closed, true);
  assert.equal(p.value.pendingFrames, 0);
  assert.equal(p.value.queuedFrames, 0);
  assert.equal(p.value.process([], [p.output()]), false);
});

function fakeEngine(holdOutput = false) {
  const states = [];
  return {
    states,
    live_create(sampleRate, channels) {
      const state = { sampleRate, channels, input: 0, output: 0, queue: [],
        puts: 0, controlCalls: 0, finishCalls: 0, clearCalls: 0 };
      states.push(state);
      return state;
    },
    live_put(state, samples) {
      state.input += samples.length / state.channels;
      state.puts += 1;
      if (!holdOutput) state.queue.push(...samples);
    },
    live_read(state, frames) {
      const result = state.queue.splice(0, frames * state.channels);
      state.output += result.length / state.channels;
      return result;
    },
    live_set_controls(state) { state.controlCalls += 1; },
    live_finish(state) { state.finishCalls += 1; },
    live_clear(state) { state.clearCalls += 1; state.queue = []; },
    live_stats(state) {
      return JSON.stringify({ input_frames: state.input, output_frames: state.output,
        available_frames: state.queue.length / state.channels });
    },
  };
}

function source(frames = 48000) {
  return { samples: Float32Array.from({ length: frames * 2 }, (_, i) => Math.sin(i / 25)),
    sampleRate: 48000, channels: 2 };
}
const options = { tempo: 1, pitch: 0, rate: 1, quality: 'balanced' };

test('demand pump starts before reading the full source and controls reuse one processor', async () => {
  const api = fakeEngine();
  const input = source();
  const pump = new StreamPump(api, input, options);
  const first = await pump.pull(512);
  assert.equal(first.samples.length, 1024);
  assert.equal(first.ended, false);
  assert.equal(api.states[0].input, 1024);
  assert.ok(api.states[0].input < input.samples.length / input.channels);
  pump.setControls({ tempo: 0.75, pitch: 3, rate: 1 });
  assert.equal(api.states.length, 1);
  assert.equal(api.states[0].controlCalls, 1);
  let frames = first.samples.length / input.channels;
  let part;
  do { part = await pump.pull(2048); frames += part.samples.length / input.channels; } while (!part.ended);
  assert.equal(frames, input.samples.length / input.channels);
  assert.equal(api.states[0].finishCalls, 1);
  assert.equal(pump.setControls(options), false);
  pump.clear();
  pump.clear();
  assert.equal(api.states[0].clearCalls, 1);
  assert.equal(pump.source.samples.length, 0);
});

test('demand pump rejects invalid reads before advancing input', async () => {
  const api = fakeEngine();
  const pump = new StreamPump(api, source(), options);
  await assert.rejects(pump.pull(0));
  await assert.rejects(pump.pull(4097));
  await assert.rejects(pump.pull(2.5));
  assert.equal(api.states[0].input, 0);
});

test('demand pump yields during startup and cancellation stops further input', async () => {
  const api = fakeEngine(true);
  let pump;
  pump = new StreamPump(api, source(), options, async () => pump.clear());
  const part = await pump.pull(512);
  assert.equal(part.ended, true);
  assert.equal(part.samples.length, 0);
  assert.equal(api.states[0].puts, 4);
  assert.equal(api.states[0].clearCalls, 1);
});
