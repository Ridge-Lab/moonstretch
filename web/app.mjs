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
let live = null;
let liveGeneration = 0;
let controlTimer;
let bpmEstimate = null;

function settings() {
  return { ...Object.fromEntries(controls.map((id) => [id, Number($(id).value)])), quality: $('quality').value };
}

function sameSettings(a, b) {
  return [...controls, 'quality'].every((key) => a[key] === b[key]);
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
  syncPlaybackButtons();
}

function terminateWorker() {
  if (worker) worker.terminate();
  worker = null;
}

function beginOperation(kind) {
  if (live) stopLive();
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

function updateControls(sendLive = true) {
  const options = settings();
  $('tempo-value').textContent = `${options.tempo.toFixed(2)}×`;
  $('rate-value').textContent = `${options.rate.toFixed(2)}×`;
  $('pitch-value').textContent = `${options.pitch > 0 ? '+' : ''}${options.pitch} 半音`;
  $('predicted-duration').textContent = live ? '随播放调整' : source ? duration(source.frames / source.sampleRate / (options.tempo * options.rate)) : '—';
  if (sendLive && live) scheduleLiveControls();
  if (result && !sameSettings(options, result.options)) {
    $('output-badge').textContent = '参数已修改';
    $('output-badge').className = 'badge';
    if (!busy && !live) setStatus('当前保留上一次结果；点击「处理音频」应用新参数。');
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
  bpmEstimate = null;
  $('bpm-result').textContent = '适合有稳定节拍的音乐；纯音或节拍不明确时可能无法估计。';
  clearLiveMeters();
  $('live-state').textContent = '等待播放';
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
  setStatus('音源已就绪。点击「开始流式试听」边听边调整，或处理整段音频并导出。');
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
  const seconds = kind === 'tone' ? 8 : 12;
  const pcm = new Float32Array(sampleRate * seconds * channels);
  const notes = [261.6256, 329.6276, 391.9954, 523.2511, 440, 391.9954, 329.6276, 261.6256];
  for (let frame = 0; frame < sampleRate * seconds; frame += 1) {
    const time = frame / sampleRate;
    let sample;
    if (kind === 'melody') {
      const index = Math.floor(time / 0.5) % notes.length;
      const local = time % 0.5;
      const envelope = Math.min(1, local / 0.012) * Math.max(0, Math.min(1, (0.46 - local) / 0.1));
      const phase = 2 * Math.PI * notes[index] * local;
      sample = envelope * 0.45 * (Math.sin(phase) + 0.22 * Math.sin(phase * 2) + 0.08 * Math.sin(phase * 3));
    } else if (kind === 'click') {
      const local = time % 0.5;
      sample = local < 0.15 ? 0.6 * Math.exp(-local * 32) * (Math.sin(2 * Math.PI * (Math.floor(time / 0.5) % 4 === 0 ? 85 : 65) * local) + 0.15 * Math.sin(2 * Math.PI * 1600 * local)) : 0;
    } else {
      const envelope = Math.min(1, time / 0.025, (seconds - time) / 0.025);
      sample = 0.5 * envelope * Math.sin(2 * Math.PI * 440 * time);
    }
    for (let channel = 0; channel < channels; channel += 1) pcm[frame * channels + channel] = sample * (channel === 1 ? 0.8 : 1);
  }
  const names = { melody: '原创合成旋律 · 12 秒', click: '合成节拍 · 120 BPM · 12 秒', tone: '合成正弦 · 440 Hz · 8 秒' };
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
  if (!source || busy || live) return;
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


function syncPlaybackButtons() {
  $('live-start').disabled = busy || !source || Boolean(live);
  $('live-stop').disabled = !live;
  $('process').disabled = busy || !source || Boolean(live);
  $('detect-bpm').disabled = busy || !source || Boolean(live);
  $('apply-bpm').disabled = busy || !bpmEstimate;
  $('quality').disabled = busy || Boolean(live);
}

function clearLiveMeters() {
  $('live-time').textContent = '0:00.00';
  $('live-latency').textContent = '—';
  $('live-buffer').textContent = '—';
  $('live-underruns').textContent = '0';
  $('live-progress').value = 0;
}

function stopLive(message = null) {
  const previous = live;
  live = null;
  liveGeneration += 1;
  clearTimeout(controlTimer);
  if (previous) {
    previous.node?.port.postMessage({ type: 'stop' });
    previous.node?.disconnect();
    if (previous.worker) {
      previous.worker.postMessage({ type: 'stop' });
      // Give the worker a chance to clear the MoonBit processor and close its port.
      previous.shutdownTimer = setTimeout(() => previous.worker.terminate(), 250);
    }
    if (previous.context.state !== 'closed') void previous.context.close().catch(() => {});
  }
  $('live-state').textContent = message === '播放完成' ? '播放完成' : '已停止';
  $('live-state').className = 'badge';
  $('live-title').closest('article').dataset.playing = 'false';
  if (message) $('live-note').textContent = message;
  syncPlaybackButtons();
  updateControls(false);
}

function updateLiveProcessor(session, stats) {
  if (live !== session || !stats) return;
  $('live-latency').textContent = `${Math.round(stats.latency_frames / session.sampleRate * 1000)} ms`;
  $('live-progress').value = Math.min(1, stats.input_frames / session.sourceFrames);
}

function scheduleLiveControls() {
  if (!live?.worker) return;
  const session = live;
  clearTimeout(controlTimer);
  controlTimer = setTimeout(() => {
    if (live !== session) return;
    session.worker.postMessage({ type: 'controls', ...settings() });
  }, 35);
}

async function startLive() {
  if (!source || busy || live) return;
  const AudioContextType = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextType || !window.AudioWorkletNode) {
    setStatus('此浏览器不支持流式试听。仍可使用「处理音频」试听和导出。', 'error');
    return;
  }
  const options = settings();
  const token = ++liveGeneration;
  let session;
  try {
    const context = new AudioContextType({ sampleRate: source.sampleRate, latencyHint: 'interactive' });
    session = { token, context, worker: null, node: null,
      sampleRate: source.sampleRate, sourceFrames: source.frames };
    live = session;
    clearLiveMeters();
    syncPlaybackButtons();
    updateControls(false);
    $('source-audio').pause();
    $('output-audio').pause();
    $('live-state').textContent = '正在准备';
    $('live-note').textContent = '准备短暂的播放缓冲后开始；随后可以直接移动滑块。';
    setStatus('正在准备流式试听…', 'busy');
    if (context.sampleRate !== source.sampleRate) {
      throw new Error('当前设备不支持音源采样率，请重新加载文件，让浏览器按设备采样率解码。');
    }
    await context.resume();
    if (live !== session) return;
    if (!context.audioWorklet) throw new Error('流式试听需要 HTTPS 或 localhost。');
    await context.audioWorklet.addModule('./pcm-worklet.mjs');
    if (live !== session) return;
    const node = new AudioWorkletNode(context, 'moonstretch-player', {
      numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [source.channels],
      channelCount: source.channels, channelCountMode: 'explicit', channelInterpretation: 'discrete',
      processorOptions: { channels: source.channels,
        queueFrames: Math.ceil(source.sampleRate * 0.16 / 128) * 128,
        startFrames: Math.ceil(source.sampleRate * 0.08 / 128) * 128 },
    });
    session.node = node;
    const instance = new Worker('./live-worker.mjs', { type: 'module' });
    session.worker = instance;
    const ports = new MessageChannel();
    node.port.onmessage = ({ data }) => {
      if (live !== session) return;
      if (data.type === 'playing') {
        $('live-state').textContent = '正在播放';
        $('live-state').className = 'badge ready';
        $('live-title').closest('article').dataset.playing = 'true';
        $('live-note').textContent = '移动滑块可调整正在播放的声音；已缓冲的短片段会先播放。';
        setStatus('正在流式试听。可以边听边调整速度、音调与倍率。');
      } else if (data.type === 'stats' || data.type === 'ended') {
        $('live-time').textContent = duration(data.playedFrames / session.sampleRate);
        $('live-underruns').textContent = data.underrunBlocks.toLocaleString();
        if (data.type === 'stats') $('live-buffer').textContent = `${Math.round(data.queuedFrames / session.sampleRate * 1000)} ms`;
        if (data.type === 'ended') {
          $('live-progress').value = 1;
          $('live-buffer').textContent = '0 ms';
          stopLive('播放完成');
          setStatus(data.underrunBlocks ? '试听完成；设备处理速度不足时出现过欠载，可选择语音预设后重试。'
            : '流式试听完成。可以重新播放，或按当前固定参数生成 WAV。');
        }
      } else if (data.type === 'error') {
        stopLive();
        setStatus(data.message, 'error');
      }
    };
    node.onprocessorerror = () => {
      if (live !== session) return;
      stopLive();
      setStatus('播放器发生错误，请停止后重新试听。', 'error');
    };
    instance.onmessage = ({ data }) => {
      if (data.type === 'stopped') {
        clearTimeout(session.shutdownTimer);
        instance.terminate();
        return;
      }
      if (live !== session) return;
      if (data.type === 'ready' || data.type === 'stats' || data.type === 'controls') {
        updateLiveProcessor(session, data.stats);
        if (data.type === 'controls' && !data.applied) {
          $('live-note').textContent = '尾部音频已完成处理；新参数会用于下一次播放。';
        }
      } else if (data.type === 'error') {
        stopLive();
        setStatus(data.message || '流式处理失败。', 'error');
      }
    };
    instance.onerror = (event) => {
      if (live !== session) return;
      stopLive();
      setStatus(event.message || '无法加载流式处理模块，请刷新后重试。', 'error');
    };
    const copy = source.pcm.slice().buffer;
    instance.postMessage({ type: 'start', samples: copy, sampleRate: source.sampleRate,
      channels: source.channels, ...options, port: ports.port2 }, [copy, ports.port2]);
    node.port.postMessage({ type: 'connect', port: ports.port1 }, [ports.port1]);
    node.connect(context.destination);
  } catch (error) {
    if (session && live !== session) return;
    stopLive();
    setStatus(error.message || '无法开始流式试听。', 'error');
  }
}

async function detectBpm() {
  if (!source || busy || live) return;
  const token = beginOperation('bpm');
  bpmEstimate = null;
  syncPlaybackButtons();
  $('bpm-result').textContent = '正在分析稳定节拍…';
  try {
    const data = await runWorker({ mode: 'bpm', samples: source.pcm.slice().buffer,
      sampleRate: source.sampleRate, channels: source.channels }, token);
    if (token !== operation) return;
    const estimate = data.estimate;
    if (estimate && Number.isFinite(estimate.bpm) && estimate.bpm > 0
        && Number.isFinite(estimate.confidence)) {
      bpmEstimate = estimate;
      $('bpm-result').textContent = `估计 ${estimate.bpm.toFixed(1)} BPM · 周期强度 ${Math.round(estimate.confidence * 100)}%。`;
      setStatus('节拍估计完成。可设置目标 BPM，再试听是否符合实际节奏。');
    } else {
      $('bpm-result').textContent = '没有找到可靠的稳定节拍。请尝试节拍更明显或更长的音乐片段。';
      setStatus('当前音源没有可靠的 BPM 估计；仍可手动调整速度。');
    }
  } catch (error) {
    if (token !== operation) return;
    $('bpm-result').textContent = '节拍分析未完成。';
    setStatus(error.message || '节拍分析失败。', 'error');
  } finally {
    if (token === operation) setBusy(false);
  }
}

function applyTargetBpm() {
  if (!bpmEstimate || busy) return;
  const target = Number($('target-bpm').value);
  const options = settings();
  if (!Number.isFinite(target) || target < 30 || target > 300) {
    setStatus('目标 BPM 需为 30–300。', 'error');
    return;
  }
  const tempo = target / (bpmEstimate.bpm * options.rate);
  if (tempo < 0.5 || tempo > 2) {
    setStatus('此目标超出当前 Rate 下的速度范围，请调整 Rate 或目标 BPM。', 'error');
    return;
  }
  $('tempo').value = String(tempo);
  updateControls();
  setStatus(`已按 ${bpmEstimate.bpm.toFixed(1)} → ${target} BPM 设置速度，并计入 Rate ${options.rate.toFixed(2)}×。`);
}

controls.forEach((id) => $(id).addEventListener('input', () => updateControls()));
$('quality').addEventListener('change', () => updateControls());
$('live-start').addEventListener('click', startLive);
$('live-stop').addEventListener('click', () => { stopLive('已停止，可重新播放。'); setStatus('已停止流式试听。'); });
$('detect-bpm').addEventListener('click', detectBpm);
$('apply-bpm').addEventListener('click', applyTargetBpm);
$('reset-controls').addEventListener('click', () => {
  $('tempo').value = '1';
  $('pitch').value = '0';
  $('rate').value = '1';
  if (!live) $('quality').value = 'balanced';
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
$('source-audio').addEventListener('play', () => { $('output-audio').pause(); if (live) stopLive(); });
$('output-audio').addEventListener('play', () => { $('source-audio').pause(); if (live) stopLive(); });
window.addEventListener('pagehide', () => { if (live) stopLive(); terminateWorker(); });
let resizeFrame;
window.addEventListener('resize', () => {
  cancelAnimationFrame(resizeFrame);
  resizeFrame = requestAnimationFrame(() => {
    drawWave($('source-wave'), source?.pcm, source?.channels || 1);
    drawWave($('output-wave'), result?.pcm, source?.channels || 1, true);
  });
});
syncPlaybackButtons();
updateControls();
drawWave($('source-wave'), null, 1);
drawWave($('output-wave'), null, 1, true);
