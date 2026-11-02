#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { transform_wav } from '../_build/js/release/build/bridge/bridge.js';

const usage = 'Usage: node scripts/moonstretch.mjs INPUT.wav OUTPUT.wav [--tempo 0.5..2] [--pitch -12..12] [--rate 0.5..2]';
try {
  const args = process.argv.slice(2);
  if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
    console.log(usage);
  } else {
    if (args.length < 2 || (args.length - 2) % 2) throw new Error(usage);
    const [input, output] = args;
    if (path.resolve(input) === path.resolve(output)) throw new Error('Input and output must be different files.');
    const controls = { '--tempo': 1, '--pitch': 0, '--rate': 1 };
    const seen = new Set();
    for (let i = 2; i < args.length; i += 2) {
      const key = args[i];
      if (!(key in controls) || seen.has(key)) throw new Error(`Unknown or repeated option: ${key}`);
      seen.add(key);
      const value = Number(args[i + 1]);
      const [lo, hi] = key === '--pitch' ? [-12, 12] : [0.5, 2];
      if (!Number.isFinite(value) || value < lo || value > hi) throw new Error(`${key} must be ${lo}..${hi}`);
      controls[key] = value;
    }
    const data = fs.readFileSync(input);
    const result = transform_wav(data, controls['--tempo'], controls['--pitch'], controls['--rate']);
    // Exclusive creation protects an existing recording from accidental replacement.
    fs.writeFileSync(output, result, { flag: 'wx' });
    console.log(`${path.basename(input)} -> ${output} (${result.length} bytes, 24-bit PCM)`);
  }
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
