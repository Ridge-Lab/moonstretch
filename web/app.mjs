const $ = (id) => document.getElementById(id);
const MAX_SECONDS = 120;
const MAX_INPUT_SAMPLES = 4_000_000;
const MAX_OUTPUT_SAMPLES = 8_000_000;
const controls = ['tempo', 'pitch', 'rate'];
let source = null;
let result = null;
let sourceUrl = null;
let outputUrl = null;
let worker = null;
let operation = 0;
let busy = false;
let audioContext = null;

function settings() {
  return Object.fromEntries(controls.map((id) => [id, Number($(id).value)]));
}

function sameSettings(a, b) {
  return controls.every((key) => a[key] === b[key]);
}

function duration(seconds) {
  if (!Number.isFinite(seconds)) return '—';
  const centiseconds = Math.round(seconds * 100);
  const minutes = Math.floor(centiseconds / 6000);
  const rest = (centiseconds % 6000) / 100;
  return `${minutes}:${rest.toFixed(2).padStart(5, '0')}`;
}

function setStatus(message, kind = '') {
  $('status').className = `status-bar ${kind}`;
  $('status-text').textContent = message;
  $('status').querySelector('.status-icon').textContent = kind === 'error' ? '!' : kind === 'busy' ? '◌' : '○';
}

function setBusy(kind) {
  busy = Boolean(kind);
  $('process').disabled = busy || !source;
  $('cancel').hidden = kind !== 'transform';
  $('output-card').setAttribute('aria-busy', String(kind === 'transform'));
  $('process').querySelector('span').textContent = kind === 'transform' ? '正在处理…' : '处理音频';
}

function terminateWorker() {
  if (worker) worker.terminate();
  worker = null;
}

function beginOperation(kind) {
  operation += 1;
  terminateWorker();
  setBusy(kind);
  return operation;
}

function runWorker(payload, token) {
  return new Promise((resolve, reject) => {
    const instance = new Worker('./worker.mjs', { type: 'module' });
    worker = instance;
    instance.onmessage = ({ data }) => {
      if (token !== operation) return;
      if (data.type === 'stage') {
        setStatus(data.message, 'busy');
      } else {
        instance.terminate();
        if (worker === instance) worker = null;
        if (data.type === 'result') resolve(data);
        else reject(new Error(data.message || '音频处理失败。'));
      }
    };
    instance.onerror = (event) => {
      instance.terminate();
      if (worker === instance) worker = null;
      reject(new Error(event.message || '处理模块无法加载。请刷新页面；本地运行时请确认已完成构建。'));
    };
    instance.postMessage(payload, [payload.samples]);
  });
}

function clearResult() {
  result = null;
  $('output-audio').pause();
  $('output-audio').removeAttribute('src');
  $('output-audio').load();
  if (outputUrl) URL.revokeObjectURL(outputUrl);
  outputUrl = null;
  $('output-badge').textContent = '尚未处理';
  $('output-badge').className = 'badge';
  $('output-description').textContent = '参数就绪后，点击「处理音频」。';
  ['actual-duration', 'processing-time', 'output-frames', 'output-end'].forEach((id) => { $(id).textContent = '—'; });
  $('output-empty').hidden = false;
  $('download').setAttribute('aria-disabled', 'true');
  $('download').tabIndex = -1;
  $('download').removeAttribute('download');
  $('download').href = '#';
  drawWave($('output-wave'), null, 1, true);
}

function updateControls() {
  const options = settings();
  $('tempo-value').textContent = `${options.tempo.toFixed(2)}×`;
  $('rate-value').textContent = `${options.rate.toFixed(2)}×`;
  $('pitch-value').textContent = `${options.pitch > 0 ? '+' : ''}${options.pitch} 半音`;
  $('predicted-duration').textContent = source ? duration(source.frames / source.sampleRate / (options.tempo * options.rate)) : '—';
  if (result && !sameSettings(options, result.options)) {
    $('output-badge').textContent = '参数已修改';
    $('output-badge').className = 'badge';
    if (!busy) setStatus('当前保留上一次结果；点击「处理音频」应用新参数。');
  } else if (result) {
    $('output-badge').textContent = '处理完成';
    $('output-badge').className = 'badge ready';
  }
}

function drawWave(canvas, pcm, channels, output = false) {
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(1, canvas.clientWidth);
  const height = Math.max(1, canvas.clientHeight);
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  const context = canvas.getContext('2d');
  context.scale(ratio, ratio);
  context.clearRect(0, 0, width, height);
  const center = (height - 18) / 2;
  context.strokeStyle = output ? '#dce1ed' : '#e4e5e5';
  context.lineWidth = 1;
  context.beginPath();
  context.moveTo(0, center + 0.5);
  context.lineTo(width, center + 0.5);
  for (let x = width / 4; x < width; x += width / 4) {
    context.moveTo(x + 0.5, 0);
    context.lineTo(x + 0.5, height);
  }
  context.stroke();
  if (!pcm?.length) return;
  const frames = pcm.length / channels;
  const amplitude = center * 0.78;
  context.strokeStyle = output ? '#505eac' : '#747d91';
  context.lineWidth = 1;
  context.beginPath();
  for (let x = 0; x < width; x += 1) {
    const start = Math.floor(x * frames / width);
    const end = Math.min(frames, Math.max(start + 1, Math.floor((x + 1) * frames / width)));
    let minimum = 1;
    let maximum = -1;
    for (let frame = start; frame < end; frame += 1) {
      const value = Math.max(-1, Math.min(1, pcm[frame * channels]));
      minimum = Math.min(minimum, value);
      maximum = Math.max(maximum, value);
    }
    context.moveTo(x + 0.5, center - maximum * amplitude);
    context.lineTo(x + 0.5, center - minimum * amplitude + 0.5);
  }
  context.stroke();
}

function sourceLimits(pcm, sampleRate, channels) {
  if (!Number.isInteger(channels) || channels < 1 || channels > 8) throw new Error('支持 1–8 声道的音频。');
  if (sampleRate < 8000 || sampleRate > 192000) throw new Error('解码后的采样率需为 8–192 kHz。');
  if (pcm.length === 0) throw new Error('音频没有可处理的采样帧。');
  const seconds = pcm.length / channels / sampleRate;
  if (seconds > MAX_SECONDS + 0.001) throw new Error('浏览器示例最多处理 120 秒，请先截取一段音频。');
  if (pcm.length > MAX_INPUT_SAMPLES) {
    throw new Error(`此音频超过浏览器内存限制。当前采样率与声道数下，请截取不超过 ${Math.floor(MAX_INPUT_SAMPLES / channels / sampleRate)} 秒的片段。`);
  }
}

async function installSource(candidate, token, selectedDemo = null) {
  sourceLimits(candidate.pcm, candidate.sampleRate, candidate.channels);
  const encoded = await runWorker({ mode: 'encode', samples: candidate.pcm.slice().buffer, sampleRate: candidate.sampleRate, channels: candidate.channels }, token);
  if (token !== operation) return;
  source = { ...candidate, frames: candidate.pcm.length / candidate.channels };
  $('source-audio').pause();
  if (sourceUrl) URL.revokeObjectURL(sourceUrl);
  sourceUrl = URL.createObjectURL(new Blob([encoded.wave], { type: 'audio/wav' }));
  $('source-audio').src = sourceUrl;
  $('source-name').textContent = source.name;
  $('source-badge').textContent = '已加载';
  $('source-badge').className = 'badge ready';
  $('source-empty').hidden = true;
  $('source-end').textContent = duration(source.frames / source.sampleRate);
  const metadata = $('source-meta');
  metadata.replaceChildren();
  for (const text of [`${(source.sampleRate / 1000).toFixed(1)} kHz`, `${source.channels} 声道`, `${duration(source.frames / source.sampleRate)}`, `${source.frames.toLocaleString()} 帧`]) {
    const span = document.createElement('span');
    span.textContent = text;
    metadata.append(span);
  }
  document.querySelectorAll('[data-demo]').forEach((button) => button.classList.toggle('selected', button.dataset.demo === selectedDemo));
  clearResult();
  drawWave($('source-wave'), source.pcm, source.channels);
  setBusy(false);
  updateControls();
  setStatus('音源已就绪。调整参数后点击「处理音频」，或先试听原始声音。');
}

async function fileDuration(file) {
  const url = URL.createObjectURL(file);
  const audio = new Audio();
  audio.preload = 'metadata';
  try {
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('读取音频信息超时，请尝试 WAV 文件。')), 15000);
      audio.onloadedmetadata = () => { clearTimeout(timer); resolve(audio.duration); };
      audio.onerror = () => { clearTimeout(timer); reject(new Error('浏览器无法读取这种音频格式，请尝试 WAV、MP3 或 OGG。')); };
      audio.src = url;
    });
  } finally {
    audio.removeAttribute('src');
    audio.load();
    URL.revokeObjectURL(url);
  }
}

async function loadFile(file) {
  if (!file) return;
  const token = beginOperation('source');
  setStatus('正在读取本地音频…', 'busy');
  try {
    if (file.size > 64 * 1024 * 1024) throw new Error('浏览器示例限制文件大小为 64 MiB，请先截取较短片段。');
    const seconds = await fileDuration(file);
    if (token !== operation) return;
    if (Number.isFinite(seconds) && seconds > MAX_SECONDS + 0.01) throw new Error('浏览器示例最多处理 120 秒，请先截取一段音频。');
    const AudioContextType = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextType) throw new Error('此浏览器不支持 Web Audio，请使用较新的浏览器。');
    audioContext ||= new AudioContextType();
    const buffer = await audioContext.decodeAudioData(await file.arrayBuffer());
    if (token !== operation) return;
    if (buffer.numberOfChannels > 8) throw new Error('支持 1–8 声道的音频。');
    if (buffer.length * buffer.numberOfChannels > MAX_INPUT_SAMPLES) throw new Error('解码后的音频超过浏览器内存限制，请截取较短片段。');
    const pcm = new Float32Array(buffer.length * buffer.numberOfChannels);
    for (let channel = 0; channel < buffer.numberOfChannels; channel += 1) {
      const values = buffer.getChannelData(channel);
      for (let frame = 0; frame < buffer.length; frame += 1) pcm[frame * buffer.numberOfChannels + channel] = values[frame];
    }
    await installSource({ name: file.name, pcm, sampleRate: buffer.sampleRate, channels: buffer.numberOfChannels }, token);
  } catch (error) {
    if (token !== operation) return;
    setBusy(false);
    setStatus(error.message || '音频读取失败，请尝试其他文件。', 'error');
  }
}

function generateDemo(kind) {
  const sampleRate = 48000;
  const channels = kind === 'melody' ? 2 : 1;
  const seconds = kind === 'tone' ? 3 : 4;
  const pcm = new Float32Array(sampleRate * seconds * channels);
  const notes = [261.6256, 329.6276, 391.9954, 523.2511, 440, 391.9954, 329.6276, 261.6256];
  for (let frame = 0; frame < sampleRate * seconds; frame += 1) {
    const time = frame / sampleRate;
    let sample;
    if (kind === 'melody') {
      const index = Math.min(notes.length - 1, Math.floor(time / 0.5));
      const local = time % 0.5;
      const envelope = Math.min(1, local / 0.012) * Math.max(0, Math.min(1, (0.46 - local) / 0.1));
      const phase = 2 * Math.PI * notes[index] * local;
      sample = envelope * 0.45 * (Math.sin(phase) + 0.22 * Math.sin(phase * 2) + 0.08 * Math.sin(phase * 3));
    } else if (kind === 'click') {
      const local = time % 0.5;
      sample = local < 0.05 ? 0.7 * Math.exp(-local * 130) * Math.sin(2 * Math.PI * (Math.floor(time / 0.5) % 4 === 0 ? 1600 : 1000) * local) : 0;
    } else {
      const envelope = Math.min(1, time / 0.025, (seconds - time) / 0.025);
      sample = 0.5 * envelope * Math.sin(2 * Math.PI * 440 * time);
    }
    for (let channel = 0; channel < channels; channel += 1) pcm[frame * channels + channel] = sample * (channel === 1 ? 0.8 : 1);
  }
  const names = { melody: '原创合成旋律 · 4 秒', click: '合成节拍 · 120 BPM', tone: '合成正弦 · 440 Hz' };
  return { name: names[kind], pcm, sampleRate, channels };
}

async function loadDemo(kind) {
  const token = beginOperation('source');
  setStatus('正在准备合成小样…', 'busy');
  try {
    await installSource(generateDemo(kind), token, kind);
  } catch (error) {
    if (token !== operation) return;
    setBusy(false);
    setStatus(error.message || '小样加载失败。', 'error');
  }
}

async function processAudio() {
  if (!source || busy) return;
  const options = settings();
  const expectedFrames = Math.round(source.frames / (options.tempo * options.rate));
  if (expectedFrames * source.channels > MAX_OUTPUT_SAMPLES) {
    setStatus('当前慢速参数会使输出超过浏览器内存限制，请缩短片段或提高 Tempo / Rate。', 'error');
    return;
  }
  const token = beginOperation('transform');
  $('source-audio').pause();
  $('output-audio').pause();
  setStatus('正在加载处理模块…', 'busy');
  try {
    const data = await runWorker({ mode: 'transform', samples: source.pcm.slice().buffer, sampleRate: source.sampleRate, channels: source.channels, ...options }, token);
    if (token !== operation) return;
    const pcm = new Float32Array(data.samples);
    result = { pcm, options, frames: pcm.length / source.channels };
    if (outputUrl) URL.revokeObjectURL(outputUrl);
    outputUrl = URL.createObjectURL(new Blob([data.wave], { type: 'audio/wav' }));
    $('output-audio').src = outputUrl;
    $('output-empty').hidden = true;
    $('output-description').textContent = `Tempo ${options.tempo.toFixed(2)}× · Pitch ${options.pitch > 0 ? '+' : ''}${options.pitch} 半音 · Rate ${options.rate.toFixed(2)}×`;
    $('actual-duration').textContent = duration(result.frames / source.sampleRate);
    $('output-end').textContent = duration(result.frames / source.sampleRate);
    $('processing-time').textContent = data.processingMs < 1000 ? `${Math.round(data.processingMs)} ms` : `${(data.processingMs / 1000).toFixed(2)} s`;
    $('output-frames').textContent = result.frames.toLocaleString();
    const filename = source.name.replace(/\.[a-z0-9]{1,6}$/i, '').replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_').slice(0, 90);
    $('download').href = outputUrl;
    $('download').download = `${filename}-moonstretch.wav`;
    $('download').setAttribute('aria-disabled', 'false');
    $('download').tabIndex = 0;
    drawWave($('output-wave'), pcm, source.channels, true);
    setBusy(false);
    updateControls();
    setStatus(sameSettings(options, settings()) ? '处理完成。可以交替试听原始音频与结果，或下载 WAV。' : '处理完成，结果使用开始时的参数。当前参数已修改，可再次处理。');
  } catch (error) {
    if (token !== operation) return;
    setBusy(false);
    setStatus(error.message || '处理失败，请尝试较短片段。', 'error');
  }
}

controls.forEach((id) => $(id).addEventListener('input', updateControls));
$('reset-controls').addEventListener('click', () => {
  $('tempo').value = '1';
  $('pitch').value = '0';
  $('rate').value = '1';
  updateControls();
});
$('audio-file').addEventListener('change', (event) => loadFile(event.target.files?.[0]));
document.querySelectorAll('[data-demo]').forEach((button) => button.addEventListener('click', () => loadDemo(button.dataset.demo)));
$('process').addEventListener('click', processAudio);
$('cancel').addEventListener('click', () => {
  beginOperation(false);
  setStatus('已取消处理。可以调整参数后重试。');
});
$('download').addEventListener('click', (event) => { if (!result) event.preventDefault(); });
const zone = $('drop-zone');
zone.addEventListener('dragover', (event) => { event.preventDefault(); zone.classList.add('dragging'); });
zone.addEventListener('dragleave', () => zone.classList.remove('dragging'));
zone.addEventListener('drop', (event) => {
  event.preventDefault();
  zone.classList.remove('dragging');
  loadFile(event.dataTransfer.files?.[0]);
});
$('source-audio').addEventListener('play', () => $('output-audio').pause());
$('output-audio').addEventListener('play', () => $('source-audio').pause());
let resizeFrame;
window.addEventListener('resize', () => {
  cancelAnimationFrame(resizeFrame);
  resizeFrame = requestAnimationFrame(() => {
    drawWave($('source-wave'), source?.pcm, source?.channels || 1);
    drawWave($('output-wave'), result?.pcm, source?.channels || 1, true);
  });
});
updateControls();
drawWave($('source-wave'), null, 1);
drawWave($('output-wave'), null, 1, true);
