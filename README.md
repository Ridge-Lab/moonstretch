# MoonStretch

[![Checks](https://github.com/Ridge-Lab/moonstretch/actions/workflows/ci.yml/badge.svg)](https://github.com/Ridge-Lab/moonstretch/actions/workflows/ci.yml)

MoonStretch 是用 MoonBit 实现的流式音频变速与变调库。它处理已解码的 PCM，让录音放慢时保留原来的音高，或改变伴奏的调性而保持时长。核心算法可编译到 Wasm、Wasm GC、JavaScript 和 Native，不需要系统音频设备或外部 DSP 库。

它适合语言学习中的慢速回放、乐器练习中的伴奏移调，以及视频和游戏资源中的音频时长调整。现有 MoonBit 音频库已经提供解码、播放、合成和重采样；本项目补充独立的 tempo/pitch 控制。相近项目及职责对照见 [生态说明](docs/ECOSYSTEM.md)。

## 三个独立控制

| 参数 | 范围 | 效果 |
| --- | --- | --- |
| `tempo` | `0.5..2.0`，默认 `1` | 改变速度和时长，保持目标音高 |
| `pitch_semitones` | `-12..12`，默认 `0` | 按半音移调，保持时长 |
| `rate` | `0.5..2.0`，默认 `1` | 同时改变速度和音高，类似改变唱片转速 |

输入为交织 `Array[Double]` PCM，支持 8,000–192,000 Hz、1–8 声道；采样必须有限且绝对值不超过 `1e100`，日常使用推荐归一化 PCM。输出保持原采样率和声道数。若输入有 `N` 帧，完成后输出恰为 `floor(N / (tempo * rate) + 0.5)` 帧；理想频率倍率为 `2^(pitch_semitones / 12) * rate`。

## 安装与运行

使用 MoonBit **0.10.16 或更高版本**；CI 固定编译器及 core 为 `0.10.16+b1a0e846e`。Node.js 宿主工具需要 Node.js 20+，没有 npm 第三方依赖。Windows Native 构建需要 MSVC 开发环境；JS 示例不需要 C 编译器。

作为库安装：

```sh
moon add Ridge-Lab/moonstretch@0.1.0
```

在调用方的 `moon.pkg` 中加入：

```moonbit
import {
  "Ridge-Lab/moonstretch",
  "moonbitlang/core/math",
}
```

最小示例：

```moonbit
fn main {
  let input = Array::makei(16000, i =>
    0.3 * @math.sin(2.0 * @math.PI * 440.0 * i.to_double() / 16000.0))
  let output = @moonstretch.process(
    input, 16000, 1, tempo=0.75, pitch_semitones=3.0,
  ) catch {
    error => abort((error : Error).to_string())
  }
  println("\{output.length()} output frames")
}
```

从源码复现：

```sh
git clone https://github.com/Ridge-Lab/moonstretch
cd moonstretch
moon update
moon check --target all --deny-warn
moon test --target all --deny-warn
moon run --target wasm-gc examples/basic
```

`examples/basic` 同样支持 `--target wasm`、`--target js` 和 `--target native`。公开接口、流式生命周期及错误处理见 [API 文档](docs/API.md)。

## 处理自己的 WAV

```sh
moon build --target js --release
node scripts/moonstretch.mjs input.wav slower.wav --tempo 0.75
node scripts/moonstretch.mjs input.wav transposed.wav --pitch 3
node scripts/moonstretch.mjs input.wav combined.wav --tempo 1.25 --pitch -2 --rate 1
```

WAV 适配层复用 `Ridge-Lab/moonwavkit@0.1.3` 的编解码器，并补充容器边界检查和奇数长度填充修正。支持该依赖的普通 RIFF/WAVE PCM 8/16/24/32-bit 和 IEEE Float32 输入；压缩音频及完整 WAVE_FORMAT_EXTENSIBLE 支持不在此适配层范围。输出重新编码为 **24-bit PCM WAV**，不保留输入的扩展元数据；超出 `[-1, 1]` 的浮点采样在整数编码时削波。CLI 不覆盖已有输出文件。

## 浏览器试听

[打开在线试听](https://ridge-lab.github.io/moonstretch/)，或在本地运行：

```sh
npm run web:build
npm run web:serve
```

打开终端显示的 `http://127.0.0.1:8765`，可调整参数、试听处理前后音频。计算由编译后的 MoonBit 核心完成，浏览器负责文件解码和播放；可接受的输入文件格式取决于浏览器。内置合成素材用于复现，不代表真实语音或音乐的主观听感评测。

## 检查与独立验证

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target all --release --deny-warn
moon info
moon build --target js --release
python scripts/audio_quality.py --output work/quality.json -- node scripts/quality_driver.mjs
node scripts/verify_wav.mjs
node scripts/benchmark.mjs work/benchmark.json
```

MoonBit 测试覆盖核心 DSP、组合控制、错误输入和流式生命周期。Python 标准库脚本独立生成测试信号，测量实际时长、频率、声道关系、事件时间、抗混叠、分块一致性、首次输出和内部 PCM 缓冲。CI 在 Linux 四后端和 Windows JS/native 执行检查、构建、测试及示例，并用独立 SoundTouch 可执行程序核对相同控制参数的时长和频率性质。运行状态以 [GitHub Actions](https://github.com/Ridge-Lab/moonstretch/actions) 为准，数值报告由对应任务上传。

## 实现与使用边界

核心采用原创 MoonBit WSOLA 和 Blackman 窗 sinc 重采样实现，见 [算法文档](docs/ALGORITHMS.md)。流式输入以完整帧分块；有前瞻延迟，结束时必须调用 `finish()`。一条流的参数固定，`reset()` 清空状态并保留配置。

音频变换会改变波形，强瞬态、密集复音及极端参数可能出现失真；本项目没有共振峰修正，不保证无损或录音棚母带级音质。流式接口不等于硬实时保证，当前没有跨设备吞吐量或主观听评结论。浮点核心不自动归一化或削波；送到播放器或整数编码器之前应检查峰值。

项目采用 [MIT 许可证](LICENSE)。第三方依赖、算法资料和外部验证工具的关系见 [THIRD_PARTY.md](THIRD_PARTY.md)。欢迎通过可复现音频用例、数值回归和实际应用反馈参与改进，流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。
