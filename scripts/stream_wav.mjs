import fs from 'node:fs';
import {
  wav_decode, wav_samples, wav_sample_rate, wav_channels, encode_wav,
  fixed_create, live_put, live_read, live_finish, live_stats,
} from '../_build/js/release/build/bridge/bridge.js';

// Node owns file positions, RIFF framing and backpressure. The existing MoonBit
// WAV adapter owns format validation/sample decoding/encoding; MoonBit owns DSP.
// There is deliberately no second sample codec in this host adapter.
function readAt(fd, count, position) {
  const bytes = Buffer.alloc(count);
  let read = 0;
  while (read < count) {
    const n = fs.readSync(fd, bytes, read, count - read, position + read);
    if (n === 0) throw new Error('WAV input ended before its declared length');
    read += n;
  }
  return bytes;
}

function writeAll(fd, bytes) {
  let written = 0;
  while (written < bytes.length) {
    const n = fs.writeSync(fd, bytes, written, bytes.length - written);
    if (n === 0) throw new Error('WAV output made no write progress');
    written += n;
  }
}

function packet(format, payload) {
  const formatPad = format.length % 2, dataPad = payload.length % 2;
  const b = Buffer.alloc(28 + format.length + formatPad + payload.length + dataPad);
  b.write('RIFF', 0); b.writeUInt32LE(b.length - 8, 4); b.write('WAVEfmt ', 8);
  b.writeUInt32LE(format.length, 16); format.copy(b, 20);
  const data = 20 + format.length + formatPad;
  b.write('data', data); b.writeUInt32LE(payload.length, data + 4);
  payload.copy(b, data + 8);
  return b;
}

function inspect(fd) {
  const stat = fs.fstatSync(fd);
  if (!stat.isFile()) throw new Error('--stream requires a seekable regular input file');
  if (stat.size < 12) throw new Error('WAV input must be a RIFF/WAVE container');
  const header = readAt(fd, 12, 0);
  // Node's 'ascii' decoder clears the high bit; FOURCC identifiers must match
  // exact bytes, so use the one-byte Latin-1 mapping instead.
  if (header.toString('latin1', 0, 4) !== 'RIFF' || header.toString('latin1', 8, 12) !== 'WAVE')
    throw new Error('WAV input must be a RIFF/WAVE container');
  if (header.readUInt32LE(4) + 8 !== stat.size) throw new Error('WAV RIFF size does not match file length');
  let offset = 12, format = null, data = null;
  while (offset < stat.size) {
    if (stat.size - offset < 8) throw new Error('WAV contains a truncated chunk header');
    const chunk = readAt(fd, 8, offset);
    const size = chunk.readUInt32LE(4), next = offset + 8 + size + size % 2;
    if (next > stat.size) throw new Error('WAV chunk payload or padding is truncated');
    const id = chunk.toString('latin1', 0, 4);
    if (id === 'fmt ') {
      if (format) throw new Error('WAV has more than one fmt chunk');
      if (size < 16 || size > 65536) throw new Error('WAV fmt chunk must be 16..65536 bytes');
      format = readAt(fd, size, offset + 8);
    } else if (id === 'data') {
      if (data) throw new Error('WAV has more than one data chunk');
      data = { offset: offset + 8, bytes: size };
    }
    // Unknown chunks are validated and skipped by seeking, never buffered.
    offset = next;
  }
  if (!format || !data) throw new Error('WAV needs exactly one fmt and one data chunk');
  const probe = wav_decode(packet(format, Buffer.alloc(0)));
  const channels = wav_channels(probe), sampleRate = wav_sample_rate(probe);
  const frameBytes = format.readUInt16LE(12);
  if (frameBytes < 1 || data.bytes % frameBytes !== 0) throw new Error('WAV data must contain complete PCM frames');
  return { format, data, frameBytes, channels, sampleRate, frames: data.bytes / frameBytes };
}

export function streamWav(inputPath, outputPath, options, blockFrames = 4096) {
  if (!Number.isInteger(blockFrames) || blockFrames < 1 || blockFrames > 65536)
    throw new Error('stream block size must be 1..65536 frames');
  let input = null, output = null, created = false, complete = false;
  try {
    input = fs.openSync(inputPath, 'r');
    const source = inspect(input);
    const { channels, sampleRate, frames } = source;
    const processor = fixed_create(sampleRate, channels, options.tempo, options.pitch, options.rate, options.quality);
    const targetFrames = Math.floor(frames / (options.tempo * options.rate) + 0.5);
    const dataBytes = targetFrames * channels * 3, padding = dataBytes % 2;
    if (!Number.isSafeInteger(dataBytes) || dataBytes + padding + 36 > 0xffffffff)
      throw new Error('Output exceeds the RIFF/WAVE 32-bit size limit; choose a shorter file');
    const header = Buffer.from(encode_wav([], sampleRate, channels));
    if (header.length !== 44 || header.toString('latin1', 36, 40) !== 'data')
      throw new Error('Unexpected WAV encoder header');
    header.writeUInt32LE(dataBytes, 40); header.writeUInt32LE(36 + dataBytes + padding, 4);
    output = fs.openSync(outputPath, 'wx'); created = true;
    writeAll(output, header);
    let inputFrames = 0, outputFrames = 0, peakRetained = 0, firstOutputAt = null;
    let maxReadBytes = 0;
    function drain() {
      peakRetained = Math.max(peakRetained, JSON.parse(live_stats(processor)).buffered_frames);
      for (;;) {
        const pcm = live_read(processor, blockFrames);
        if (pcm.length === 0) break;
        if (firstOutputAt === null) firstOutputAt = inputFrames;
        const encoded = Buffer.from(encode_wav(pcm, sampleRate, channels));
        const size = pcm.length * 3;
        if (encoded.readUInt32LE(40) !== size || encoded.length !== 44 + size + size % 2)
          throw new Error('Unexpected WAV encoder block framing');
        writeAll(output, encoded.subarray(44, 44 + size));
        outputFrames += pcm.length / channels;
      }
    }
    while (inputFrames < frames) {
      const count = Math.min(blockFrames, frames - inputFrames);
      const bytes = readAt(input, count * source.frameBytes, source.data.offset + inputFrames * source.frameBytes);
      maxReadBytes = Math.max(maxReadBytes, bytes.length);
      live_put(processor, wav_samples(wav_decode(packet(source.format, bytes))));
      inputFrames += count;
      drain();
    }
    live_finish(processor); drain();
    if (outputFrames !== targetFrames) throw new Error('Stream output length differs from the fixed-control contract');
    if (padding) writeAll(output, Buffer.alloc(1));
    const final = JSON.parse(live_stats(processor));
    if (final.available_frames !== 0 || final.buffered_frames !== 0) throw new Error('Stream failed to drain');
    complete = true;
    return {
      mode: 'stream', input_frames: frames, output_frames: outputFrames,
      sample_rate: sampleRate, channels, tempo: options.tempo, pitch: options.pitch,
      rate: options.rate, quality: options.quality, block_frames: blockFrames,
      max_input_read_bytes: maxReadBytes, peak_retained_pcm_frames: peakRetained,
      first_output_after_input_frames: firstOutputAt,
    };
  } finally {
    if (input !== null) fs.closeSync(input);
    if (output !== null) fs.closeSync(output);
    // Only remove the new file successfully created by this invocation. Existing
    // destinations are refused by 'wx' and are never removed or overwritten.
    if (created && !complete) fs.unlinkSync(outputPath);
  }
}
