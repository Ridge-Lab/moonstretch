#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { streamWav } from './stream_wav.mjs';
import {
  wav_decode, wav_samples, wav_sample_rate, wav_channels,
  transform_pcm_quality, encode_wav, analyze_bpm,
} from '../_build/js/release/build/bridge/bridge.js';

const usage = `Usage: node scripts/moonstretch.mjs INPUT.wav [OUTPUT.wav] [options]
  --tempo 0.5..2       Change duration while keeping target pitch
  --pitch -12..12      Semitone transposition
  --rate 0.5..2        Coupled speed/pitch control
  --quality speech|balanced|music
  --stream             Incremental file-to-file processing, bounded PCM buffers
  --detect-bpm         Report a BPM estimate; OUTPUT may be omitted
  --target-bpm 30..300 Match a target beat rate (requires OUTPUT)
  --source-bpm 30..300 Use a known source tempo with --target-bpm
  --bpm-min 30..300    Search lower bound (default 60)
  --bpm-max 30..300    Search upper bound (default 200)
Use - for stdin/stdout WAV bytes. Diagnostics go to stderr.
Default mode buffers WAV input/output. --stream requires regular file paths;
automatic BPM detection and stdin/stdout use the default mode.`;

function number(text, key, lo, hi) {
  const value = Number(text);
  if (!text?.trim() || !Number.isFinite(value) || value < lo || value > hi)
    throw new Error(`${key} must be ${lo}..${hi}`);
  return value;
}
try {
  const args = process.argv.slice(2);
  if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
    console.log(usage);
  } else {
    if (!args.length || args[0].startsWith('--')) throw new Error(usage);
    const input = args.shift();
    const output = args.length && !args[0].startsWith('--') ? args.shift() : null;
    const options = { tempo: 1, pitch: 0, rate: 1, quality: 'balanced', min: 60, max: 200 };
    const seen = new Set();
    for (let i = 0; i < args.length; i += 1) {
      const key = args[i];
      if (seen.has(key)) throw new Error(`Unknown or repeated option: ${key}`);
      seen.add(key);
      if (key === '--detect-bpm') { options.detect = true; continue; }
      if (key === '--stream') { options.stream = true; continue; }
      const value = args[++i];
      if (value === undefined) throw new Error(`Missing value for ${key}`);
      switch (key) {
        case '--tempo': options.tempo = number(value, key, 0.5, 2); break;
        case '--pitch': options.pitch = number(value, key, -12, 12); break;
        case '--rate': options.rate = number(value, key, 0.5, 2); break;
        case '--quality':
          if (!['speech', 'balanced', 'music'].includes(value)) throw new Error('quality must be speech, balanced or music');
          options.quality = value; break;
        case '--target-bpm': options.target = number(value, key, 30, 300); break;
        case '--source-bpm': options.source = number(value, key, 30, 300); break;
        case '--bpm-min': options.min = number(value, key, 30, 300); break;
        case '--bpm-max': options.max = number(value, key, 30, 300); break;
        default: throw new Error(`Unknown or repeated option: ${key}`);
      }
    }
    if (!output && (!options.detect || options.target)) throw new Error(usage);
    if (!output && ['--tempo', '--pitch', '--rate', '--quality'].some(key => seen.has(key)))
      throw new Error('Transformation options require an output file.');
    if (options.source && !options.target) throw new Error('--source-bpm requires --target-bpm');
    if (options.target && seen.has('--tempo')) throw new Error('--target-bpm and --tempo are mutually exclusive.');
    if (options.min >= options.max) throw new Error('--bpm-min must be less than --bpm-max');
    if (output && input !== '-' && output !== '-' && path.resolve(input) === path.resolve(output))
      throw new Error('Input and output must be different files.');
    if (options.stream) {
      if (!output || input === '-' || output === '-') throw new Error('--stream requires input and output file paths');
      if (options.detect || (options.target && !options.source))
        throw new Error('--stream requires known --source-bpm for tempo matching; automatic BPM detection uses the default mode');
      if (options.target) {
        options.tempo = options.target / (options.source * options.rate);
        if (options.tempo < 0.5 || options.tempo > 2)
          throw new Error('Target BPM requires tempo outside 0.5..2; choose a closer target or another rate.');
      }
      const report = streamWav(input, output, options);
      if (options.target) Object.assign(report, { source_bpm: options.source, target_bpm: options.target });
      process.stderr.write(`${JSON.stringify(report)}\n`);
    } else {
      const audio = wav_decode(fs.readFileSync(input === '-' ? 0 : input));
      const samples = wav_samples(audio);
      const sampleRate = wav_sample_rate(audio);
      const channels = wav_channels(audio);
      const estimate = options.detect || (options.target && !options.source)
        ? JSON.parse(analyze_bpm(samples, sampleRate, channels, options.min, options.max)) : null;
      const sourceBpm = options.source ?? estimate?.bpm;
      if (options.target) {
        if (!sourceBpm) throw new Error('No reliable periodic tempo found. Supply a known --source-bpm or different audio.');
        options.tempo = options.target / (sourceBpm * options.rate);
        if (options.tempo < 0.5 || options.tempo > 2)
          throw new Error('Target BPM requires tempo outside 0.5..2; choose a closer target or another rate.');
      }
      if (!output) {
        console.log(JSON.stringify({ estimate, sample_rate: sampleRate, channels, input_frames: samples.length / channels }));
      } else {
        const transformed = transform_pcm_quality(samples, sampleRate, channels, options.tempo, options.pitch, options.rate, options.quality);
        const result = encode_wav(transformed, sampleRate, channels);
        fs.writeFileSync(output === '-' ? 1 : output, result, output === '-' ? undefined : { flag: 'wx' });
        const report = {
          input_frames: samples.length / channels, output_frames: transformed.length / channels,
          sample_rate: sampleRate, channels, tempo: options.tempo, pitch: options.pitch,
          rate: options.rate, quality: options.quality,
          ...(options.detect || options.target ? { estimate, source_bpm: sourceBpm ?? null, target_bpm: options.target ?? null } : {}),
        };
        process.stderr.write(`${JSON.stringify(report)}\n`);
      }
    }
  }
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
