# 第三方依赖与算法来源

MoonStretch 的源码采用根目录 [MIT License](LICENSE)。时间伸缩、重采样、连续控制、FIFO、能量包络 BPM 估计及独立数值验证为本项目实现；本项目不是 SoundTouch 或其他音频库的代码移植。

MoonMel 的接口及源码仅用于核查生态已有能力，未移植其 phase-vocoder、time_stretch、pitch_shift 或节拍分析实现。原有生态对照遗漏已在 `docs/ECOSYSTEM.md` 更正。浏览器的 Worker 与 AudioWorklet 负责本地调度及 PCM 播放，不替代 MoonBit DSP。

## 运行依赖

| 项目 | 来源与版本 | 许可证 | 使用方式 |
| --- | --- | --- | --- |
| MoonBit core | [moonbitlang/core](https://github.com/moonbitlang/core)，CI 与 `0.10.16+b1a0e846e` 工具链匹配 | Apache-2.0 | 数组、数值运算、JSON 等标准库 |
| MoonWavKit | [Ridge-Lab/MoonWavKit](https://github.com/Ridge-Lab/MoonWavKit)，Mooncakes `Ridge-Lab/moonwavkit@0.1.3` | MIT | `wav` 适配包的解析、PCM 解码和 24-bit WAV 编码 |

MoonWavKit 通过包管理器导入，没有将其历史源码换名放入本项目。其既有解析及分析功能不计作 MoonStretch 的新 DSP 实现。核心 `types`、`stretch`、`rate` 以及组合流不调用 WAV 容器处理。

分发依赖源码或包含依赖的构建产物时，应同时保留对应依赖的许可证和版权声明。`licenses/moonbit-core-LICENSE` 与 `licenses/moonbit-core-NOTICE` 保留所用 core 的许可证、IDEA 署名及其第三方来源声明；`licenses/MoonWavKit-LICENSE` 保留 WAV 依赖的许可证。网页构建会一并复制这些文件。依赖的实际声明由所用工具链或包管理器下载的原包提供；修改依赖或更新版本时需要重新核对。

## 理论参考

- Verhelst、Roelands，*An Overlap-Add Technique Based on Waveform Similarity (WSOLA) for High Quality Time-Scale Modification of Speech*，ICASSP 1993：[DOI](https://doi.org/10.1109/ICASSP.1993.319366)。
- Roelands、Verhelst，*Waveform similarity based overlap-add (WSOLA) for time-scale modification of speech: structures and evaluation*，Eurospeech 1993：[论文记录](https://www.isca-archive.org/eurospeech_1993/roelands93_eurospeech.html)。
- Julius O. Smith，*Physical Audio Signal Processing* 的 [Windowed Sinc Interpolation](https://www.dsprelated.com/freebooks/pasp/Windowed_Sinc_Interpolation.html) 章节。

这些资料是数学和算法依据。仓库没有复制论文图表、正文、书中程序或第三方 DSP 实现；窗口、搜索、流式状态和组合 API 由 MoonBit 源码直接表达。

## 独立验证工具

[SoundTouch / SoundStretch](https://www.surina.net/soundtouch/) 的开源实现采用 LGPL-2.1。CI 从系统包管理器安装 `soundstretch`，作为独立进程处理脚本生成的 WAV，用于比较时长和频率性质。它不参与 MoonStretch 库的运行，不被链接进库或打包为本项目源码，也不要求逐样本结果相同。

首轮 Linux CI 的实际参考版本为 Ubuntu 包 `soundstretch 2.3.2+ds1`。后续运行以任务输出的 `dpkg-query` 版本记录为准，不据此声称实现了某个 SoundTouch 版本的完整 API 或二进制兼容性。

Python、Node.js 和 GitHub Actions 仅用于开发、宿主文件操作、网页服务或检查。Node.js 宿主脚本没有 npm 第三方依赖；浏览器解码和播放使用宿主提供的 Web Audio 能力。

## 测试素材与演示

测试音、噪声和带时间标记的声音事件由程序生成；不包含第三方录音、音乐片段或商业数据集。用户在本地打开的文件不会自动纳入项目素材。若后续引入真实录音回归用例，需要记录来源、许可证和可再分发依据，并保持素材授权信息随文件分发。

## 开发方式

本项目使用 AI 辅助进行设计、代码实现、测试和文档编写，不声称全部由参赛者本人手写。AI 辅助及自动测试不能代替来源核查，也不能作为不存在代码相似性或侵权风险的证明。参赛与贡献说明应反映实际参与；生成的公开接口文件不计作手写实现。
