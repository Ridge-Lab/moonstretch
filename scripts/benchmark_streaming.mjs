#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { spawnSync } from 'node:child_process';
import {
  live_create, live_put, live_read, live_finish, live_set_controls, live_stats,
} from '../_build/js/release/build/bridge/bridge.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sampleRate = 48000, channels = 2, seconds = 6;
const controls = [[0.8, 3, 1], [1.25, -4, 0.9], [0.9, 0, 1.15]];
// PCM generation and all input slicing occur before the measured processing.
const pcm = Array.from({ length: sampleRate * channels * seconds }, (_, i) => {
  const frame = Math.floor(i / channels), t = frame / sampleRate;
  const melody = 0.22 * Math.sin(2 * Math.PI * 220 * t) + 0.07 * Math.sin(2 * Math.PI * 660 * t);
  return i % channels ? melody * 0.7 + 0.04 * Math.sin(2 * Math.PI * 330 * t) : melody;
});
const inputs = new Map();
for (const blockFrames of [512, 1024]) {
  const chunks = [];
  for (let start = 0; start < sampleRate * seconds;) {
    const nextControl = start < sampleRate * 2 ? sampleRate * 2 : start < sampleRate * 4 ? sampleRate * 4 : sampleRate * seconds;
    const end = Math.min(start + blockFrames, nextControl);
    chunks.push({ start, samples: pcm.slice(start * channels, end * channels) });
    start = end;
  }
  inputs.set(blockFrames, chunks);
}
function summary(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const pick = percentile => sorted[Math.max(0, Math.ceil(percentile * sorted.length) - 1)] ?? 0;
  return { calls: values.length, p50_ms: pick(0.5), p95_ms: pick(0.95),
    max_ms: sorted.at(-1) ?? 0, total_ms: values.reduce((a, b) => a + b, 0) };
}
function warmup(quality) {
  const p = live_create(sampleRate, channels, ...controls[0], quality);
  for (const chunk of inputs.get(1024)) {
    if (chunk.start >= sampleRate) break;
    live_put(p, chunk.samples); live_read(p, 100000);
  }
  live_set_controls(p, ...controls[1]);
  live_finish(p); live_read(p, 100000);
}

const rows = [];
for (const quality of ['speech', 'balanced', 'music']) {
  warmup(quality);
  for (const blockFrames of [512, 1024]) {
    const putTimes = [], readTimes = [], controlTimes = [];
    const beginInit = performance.now();
    const p = live_create(sampleRate, channels, ...controls[0], quality);
    const initMs = performance.now() - beginInit;
    let observedPeak = 0, peakQueue = 0, emitted = 0, emptyReads = 0, checksum = 0;
    let firstOutputAt = null;
    const sampleStats = () => {
      const current = JSON.parse(live_stats(p));
      observedPeak = Math.max(observedPeak, current.buffered_frames);
      peakQueue = Math.max(peakQueue, current.available_frames);
      return current;
    };
    const drain = acceptedFrames => {
      while (true) {
        const begin = performance.now();
        const output = live_read(p, blockFrames);
        readTimes.push(performance.now() - begin);
        if (!output.length) { emptyReads++; break; }
        assert.equal(output.length % channels, 0);
        if (firstOutputAt === null) firstOutputAt = acceptedFrames;
        emitted += output.length / channels;
        // Validation stays outside the timed API call; loop wall time includes it.
        for (const value of output) { assert.ok(Number.isFinite(value)); checksum += value; }
        sampleStats();
      }
    };
    const loopBegin = performance.now();
    for (const chunk of inputs.get(blockFrames)) {
      if (chunk.start === sampleRate * 2 || chunk.start === sampleRate * 4) {
        const next = chunk.start === sampleRate * 2 ? controls[1] : controls[2];
        const begin = performance.now(); live_set_controls(p, ...next);
        controlTimes.push({ at_input_frame: chunk.start, controls: next, elapsed_ms: performance.now() - begin });
      }
      const begin = performance.now(); live_put(p, chunk.samples);
      putTimes.push(performance.now() - begin);
      sampleStats(); drain(chunk.start + chunk.samples.length / channels);
    }
    const beginFinish = performance.now(); live_finish(p);
    const finishMs = performance.now() - beginFinish;
    sampleStats(); drain(sampleRate * seconds);
    const loopWallMs = performance.now() - loopBegin;
    const final = sampleStats();
    assert.equal(final.input_frames, sampleRate * seconds);
    assert.equal(final.output_frames, emitted);
    assert.equal(final.available_frames, 0); assert.equal(final.buffered_frames, 0);
    const put = summary(putTimes), read = summary(readTimes);
    const update = summary(controlTimes.map(item => item.elapsed_ms));
    const computeMs = initMs + put.total_ms + read.total_ms + update.total_ms + finishMs;
    rows.push({ quality, input_block_frames: blockFrames, output_read_frames: blockFrames,
      initialization_ms: initMs, put, read, control_updates: controlTimes,
      control_update_summary: update, finish_ms: finishMs,
      timed_api_total_ms: computeMs, processing_loop_wall_ms: loopWallMs,
      input_audio_seconds_per_compute_second: seconds * 1000 / computeMs,
      observed_peak_retained_pcm_frames: observedPeak, peak_unread_output_frames: peakQueue,
      first_output_at_input_frame: firstOutputAt, output_frames: emitted,
      empty_read_calls: emptyReads, output_checksum: checksum });
  }
}
const gitArgs = [`--git-dir=${path.join(root, '.git')}`, `--work-tree=${root}`];
const commit = spawnSync('git', [...gitArgs, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
const status = spawnSync('git', [...gitArgs, 'status', '--porcelain'], { encoding: 'utf8' });
const report = {
  description: 'Single-host JS release measurements; throughput is not a hard-real-time or cross-device guarantee.',
  generated_at: new Date().toISOString(), backend: 'MoonBit JavaScript release',
  node: process.version, platform: `${process.platform}/${process.arch}`, cpu: os.cpus()[0]?.model,
  logical_cpu_count: os.cpus().length, source_commit: commit.status === 0 ? commit.stdout.trim() : null,
  source_dirty: status.status === 0 ? status.stdout.length > 0 : null,
  sample_rate: sampleRate, channels, input_seconds_per_case: seconds,
  initial_controls: controls[0], control_change_input_seconds: [2, 4],
  warmup: 'One second per quality plus one control update and finish before measured instances.',
  timing: 'Initialization, put, receive, set_controls and finish are timed separately; generated input, slicing, statistics, assertions and file I/O are outside API timings. Loop wall time includes instrumentation and output validation. Empty reads are included in read distributions.',
  rows,
};
const output = process.argv[2] ? path.resolve(process.argv[2]) : path.join(root, 'work', 'streaming-benchmark.json');
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
console.log(`Measured ${rows.length} streaming configurations; report: ${output}`);
