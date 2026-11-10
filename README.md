# MoonStretch

[![Checks](https://github.com/Ridge-Lab/moonstretch/actions/workflows/ci.yml/badge.svg)](https://github.com/Ridge-Lab/moonstretch/actions/workflows/ci.yml)

MoonStretch 是 MoonBit 原生的音频流处理库：在同一处理器中调整速度、音高和播放倍率，接收解码器送来的 PCM，按播放器要求的帧数取出结果。它提供连续处理状态、共享多声道对齐、质量/延迟配置和 BPM 到目标练习速度的完整流程。

MoonBit 生态已有 MoonMel 的离线 `time_stretch`、`pitch_shift` 和节拍分析。MoonStretch 的独立价值是可在运行中调参的 PCM 流、FIFO 消费接口及实际播放器接入。已有能力、版本依据和与 SoundTouch 的逐项功能对照见 [生态与成熟工具对照](docs/ECOSYSTEM.md)。

[打开本地音频演示](https://ridge-lab.github.io/moonstretch/)：整段处理与 WAV 导出，或边处理边播放并调整参数。音频不上传；MoonBit 负责 DSP，浏览器负责解码、调度和播放。

## 功能与范围

| 能力 | 接口或交付 |
| --- | --- |
| 固定参数变速、移调、倍率组合 | `process` / `Stream::new`；结束后精确输出帧数 |
| 连续流调参 | `Stream::new_live` / `set_controls`；保持分析时钟、采样相位与历史 |
| 播放器取样 | `Processor::put_samples / receive_samples / read_into / finish / clear` |
| 质量与延迟配置 | `Speech`、`Balanced`、`Music`，不同重叠窗口及搜索密度 |
| BPM 估计 | `bpm/Detector` 有界能量包络、周期强度、无可靠结果时返回 `None` |
| 节拍匹配 | CLI/网页估计后匹配目标 BPM；CLI 另支持指定已知源 BPM |
| 示例与验证 | MoonBit 播放管线、BPM 练习示例、浏览器流式播放、WAV CLI、独立测量 |
| 长文件处理 | CLI `--stream` 按块解码、变换、消费和编码，无需缓存整段 PCM |

支持 8,000–192,000 Hz、1–8 声道的交织 `Array[Double]` PCM。三个控制范围为 `tempo=0.5..2`、`pitch_semitones=-12..12`、`rate=0.5..2`，全部组合有效。输出保持采样率和声道数；目标频率倍率为 `2^(pitch_semitones/12) * rate`。固定配置输出帧数为 `floor(N/(tempo*rate)+0.5)`。

连续控制从下一次算法处理生效，可以影响尚未处理的前瞻数据，已返回的 PCM 不改变。动态流用累积时钟排空，不以最后一次参数重算整段时长。它不是逐输入帧的自动化曲线，也不承诺瞬间调参无点击；这些语义见 [API 文档](docs/API.md)。

## 安装

使用 MoonBit **0.10.16 或更高版本**。CI 固定编译器和 core 为 `0.10.16+b1a0e846e`。Node.js 宿主工具需要 Node.js 20+，无 npm 第三方依赖。

```sh
moon add Ridge-Lab/moonstretch@0.3.0
```

调用项目的 `moon.pkg`：

```moonbit
import {
  "Ridge-Lab/moonstretch",
}
```

最小调用：

```moonbit
let output = @moonstretch.process(
  samples, 48000, 2,
  tempo=0.75, pitch_semitones=3.0, quality=@moonstretch.Speech,
)
```

这里 `samples` 是已解码的交织 PCM；函数会抛出可恢复的 `AudioError`。不需要外部 C/C++ DSP 库，核心可编译为 JS、Wasm、Wasm GC 和 Native。

## 接入播放器

```moonbit
let processor = @moonstretch.Processor::new(48000, 2)
processor.put_samples(decoded_block)
let audio = processor.receive_samples(128)
processor.set_controls(tempo=0.8, pitch_semitones=2.0, rate=1.0)
processor.put_samples(next_decoded_block)
processor.finish()
let tail = processor.receive_samples(processor.num_samples())
```

生产者按需提交完整 PCM 帧，消费者反复取出固定大小的块；暂时返回不足一块并不表示音频结束。`read_into(destination, offset_frames, max_frames)` 可以复用设备缓冲，返回实际写入帧数。完整可运行实现见 [examples/player](examples/player/main.mbt)。

FIFO 未消费的输出会增长，应用应根据 `num_samples()` 限制预读；算法历史与播放队列必须分开考虑。实现会分配内存，不应把它直接当成已证明零分配的硬实时音频回调。浏览器把运算放在 Worker，AudioWorklet 只消费排队的 PCM。

## BPM 与伴奏练习

`Ridge-Lab/moonstretch/bpm` 的 `Detector` 接收分块 PCM，默认只保留最近 20 秒、200 Hz 的能量包络。默认搜索 60–200 BPM，可配置 30–300 BPM；需要足够长的稳定节奏。返回的 confidence 表示周期强度，不是正确概率。

静音、稳态纯音或缺乏可靠周期时返回 `None`。真实音乐可能有半拍/倍拍歧义；使用者应试听或提供已知源 BPM。可运行的“检测 → 目标节拍 → PCM”例子见 [examples/practice](examples/practice/main.mbt)，算法与限制见 [bpm/README.md](bpm/README.md)。

## WAV 命令行

```sh
moon build --target js --release
node scripts/moonstretch.mjs input.wav slower.wav --tempo 0.75 --quality speech
node scripts/moonstretch.mjs input.wav transposed.wav --pitch 3 --quality music
node scripts/moonstretch.mjs input.wav --detect-bpm
node scripts/moonstretch.mjs input.wav practice.wav --target-bpm 100
node scripts/moonstretch.mjs input.wav practice-known.wav --source-bpm 120 --target-bpm 90 --pitch -2
node scripts/moonstretch.mjs long.wav practice.wav --stream --tempo 0.75 --pitch -2
```

`--target-bpm` 与显式 `--tempo` 互斥，按 `target/(source*rate)` 计算 tempo；无可靠估计或超过 0.5–2 的处理范围时报告错误。输入/输出文件名 `-` 表示二进制 stdin/stdout；诊断写入 stderr。CLI 不覆盖已有输出文件，管道调用应使用能保持二进制数据的宿主或 shell。

WAV 读写复用 `Ridge-Lab/moonwavkit@0.1.3`。支持普通 RIFF/WAVE PCM 8/16/24/32-bit 和 IEEE Float32 输入，输出 **24-bit PCM WAV**。不保留全部扩展元数据，不承诺压缩 WAV 或完整 WAVE_FORMAT_EXTENSIBLE；超出 ±1 的浮点值在整数编码时削波。

默认模式读取完整文件。`--stream` 针对可定位的普通输入文件，先校验 RIFF/chunk 边界，再以 4,096 帧为块复用 MoonBit 编解码器，处理后立即排出并写入。它不缓存整段 PCM，也不把未知元数据块载入内存；输出必须符合 RIFF 的 32 位长度上限。固定参数的帧数与默认模式一致。自动 BPM 检测及 stdin/stdout 仍用默认模式；分块模式可用 `--source-bpm` 与 `--target-bpm` 匹配已知节拍。处理失败会清理本次新建的输出，已有文件始终不覆盖。

## 从源码复现

```sh
git clone https://github.com/Ridge-Lab/moonstretch
cd moonstretch
moon update
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target all --release --deny-warn
moon run --target wasm-gc examples/basic
moon run --target wasm-gc examples/player
moon run --target wasm-gc examples/practice
```

三个示例也支持 `--target js`、`wasm` 和 `native`。Windows Native 需要 MSVC 开发环境；JS/Wasm 示例不需要 C 编译器。

```sh
npm run web:build
npm run web:serve
```

打开终端显示的本地地址。浏览器解码格式由 Web Audio 支持情况决定；示例仍限制文件长度和输入规模。库处理历史有界不等于浏览器示例从磁盘增量解码：示例保留已解码音源，播放时按需求分块变换。

## 验证与性能

```sh
python scripts/verify.py --profile quick --targets js
python scripts/verify.py --profile full --targets js wasm wasm-gc
# 若已安装 SoundTouch：完整运行并要求外部对照成功
python scripts/verify.py --profile full --targets js --soundstretch soundstretch
# 发布后从注册表安装；不使用工作区替代公开包
python scripts/verify.py --profile release --version 0.3.0 --targets js wasm wasm-gc
```

CI 和本地共用此入口，Linux 覆盖四后端，Windows 覆盖 JS/native。每次运行在 `work/verification/` 下创建独立目录，保留源码指纹、工具链、每项命令、日志、数值报告及其哈希；失败返回非零，依赖失败明确跳过，运行中源码变化会使结果失效。未执行的 SoundTouch 对照不会标为通过。

验证覆盖物理性质、随机生产/消费调度、非法输入后的状态、文件分块与整体处理一致性，以及实际引擎上的故障注入。故障注入先确认基线正确，再检查丢帧、错误参数、声道交换等是否触发预定判据，并以可接受微扰检查误报；它不等于源码变异覆盖率。真实缺陷及回归入口见 [验证证据](docs/VALIDATION.md)，开发流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

性能报告记录硬件、后端、初始化、处理块耗时及控制更新耗时。单机吞吐不能推导全设备硬实时保证，合成信号回归不能代替实际语音和音乐听评。当前运行结果以 [GitHub Actions](https://github.com/Ridge-Lab/moonstretch/actions) 的任务与数值报告为准。

## 来源与使用边界

本项目独立实现 WSOLA、Blackman 窗 sinc 重采样及能量包络节拍估计，使用 MIT 许可证。SoundTouch 用于功能参考和独立进程验证，不被链接进库；未移植 MoonMel 源码。算法、第三方依赖及授权见 [算法文档](docs/ALGORITHMS.md)和 [THIRD_PARTY.md](THIRD_PARTY.md)。

输入采样必须有限且绝对值不超过 `1e100`，单条组合流最多接受 `1e12` 帧；日常使用推荐归一化 PCM。浮点核心不自动削波。强瞬态、密集复音和极端变换可能出现伪影；不提供共振峰保持、自动修音或音源分离，不宣称完整 SoundTouch API/二进制兼容或母带级音质。

欢迎提交可复现用例与实际接入反馈，参见 [CONTRIBUTING.md](CONTRIBUTING.md)。
