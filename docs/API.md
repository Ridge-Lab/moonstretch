# API 与数据约定

本文描述 0.3.0 的固定处理、连续控制、FIFO、BPM 与文件管线接口。公共入口为 `Ridge-Lab/moonstretch`，WAV 适配包为 `Ridge-Lab/moonstretch/wav`，节拍分析包为 `Ridge-Lab/moonstretch/bpm`，错误类型位于 `Ridge-Lab/moonstretch/types`。完整签名以各包的 `pkg.generated.mbti` 为准。

## PCM 与控制参数

- PCM 为交织 `Array[Double]`：立体声顺序是 `L0, R0, L1, R1, ...`。一帧包含所有声道的一次采样，数组长度必须整除声道数。
- 采样率为 8,000–192,000 Hz，声道数为 1–8。调用方负责声道语义和布局；输出采样率、声道数不变。
- 采样必须有限且绝对值不超过 `1e100`，通常使用归一化 PCM。NaN、Infinity 和超限值会被拒绝；浮点核心不自动归一化或削波。
- `tempo` 为 `0.5..2.0`，`pitch_semitones` 为 `-12..12`，`rate` 为 `0.5..2.0`；默认分别为 1、0、1。
- 固定控制的目标频率倍率为 `2^(pitch_semitones / 12) * rate`；完成后帧数为 `floor(input_frames / (tempo * rate) + 0.5)`。动态控制的时间语义见下文，不能把最后一次参数代入这个公式回算整条录音。
- 单个组合流累计最多接受 `1,000,000,000,000` 帧。参数和完整输入块在接受前验证；无效输入不消耗该块。

## 质量与延迟档位

`process`、`Stream::new`、`Stream::new_live`、`Processor::new` 及 `@wav.transform` 都接受 `quality~`，默认为 `@moonstretch.Balanced`。

| 档位 | 合成 hop / 重叠尾部 | 搜索半径 | 搜索方式 |
| --- | --- | --- | --- |
| `Speech` | 各 10 ms | 5 ms | 较稀疏粗搜索，随后局部完整相关 |
| `Balanced` | 各 20 ms | 10 ms | 与 0.1.x 默认一致 |
| `Music` | 各 40 ms | 15 ms | 粗搜索密度加倍，随后局部完整相关 |

这些名称表示窗口、搜索成本和前瞻的取舍，不是对任意语音或音乐音质的排序保证。三个档位使用相同的抗混叠 sinc 滤波器。档位在创建时选择；改变档位应创建新处理器。

`latency_frames()` 返回当前设置下的保守算法前瞻预算，含 WSOLA 搜索、窗口、速率转换和组合保留量。换算毫秒为 `1000 * latency_frames / sample_rate`。它不包括未读取的 FIFO、解码、Worker 消息、声卡缓冲和宿主调度，也不是硬实时执行时限。动态控制变化后应重新读取该值。

## 固定控制：一次处理或增量输入

```moonbit
let output = @moonstretch.process(
  samples, sample_rate, channels,
  tempo=0.75, pitch_semitones=0.0, rate=1.0,
  quality=@moonstretch.Speech,
)
```

`process` 返回新数组，内部使用固定参数流并完成尾部排空。它需要容纳完整输入和输出。处理长录音可使用 `Stream::new`：

```moonbit
test "fixed stream lifecycle" {
  let stream = @moonstretch.Stream::new(16000, 1, tempo=0.75)
  let output : Array[Double] = []
  output.append(stream.push([0.0, 0.1, 0.2, 0.1]))
  output.append(stream.push([0.0, -0.1, -0.2, -0.1]))
  output.append(stream.finish())
  assert_eq(output.length(), 11)
  assert_eq(stream.input_frames(), 8L)
  assert_eq(stream.output_frames(), 11L)
  assert_eq(stream.finish().length(), 0)
  stream.reset()
  assert_eq(stream.input_frames(), 0L)
}
```

| 方法 | 行为 |
| --- | --- |
| `Stream::new(sample_rate, channels, tempo?, pitch_semitones?, rate?, quality?)` | 固定控制；完成后保证统一取整的精确帧数 |
| `push(samples)` | 接受任意数量的完整帧，返回当前可用 PCM；前瞻不足时可返回空数组 |
| `finish()` | 排空尾部；重复调用返回空数组 |
| `reset()` | 丢弃状态，清零计数，保留格式、档位和当前控制参数 |
| `input_frames()` / `output_frames()` | 累计接受 / 已返回的帧数，类型为 `Int64` |
| `buffered_frames()` | 两级 DSP 和组合待输出区保留的 PCM 帧，不含调用方数组及滤波器表 |
| `sample_rate()` / `channels()` / `quality()` | 当前格式与档位 |
| `controls()` | `(tempo, pitch_semitones, rate)` |

固定控制下，相同输入的最终结果不依赖分块方式；所有声道使用同一时间对齐偏移。输入不要求按算法窗口大小分块。调用方必须消费每次 `push` 和最终 `finish` 的输出。结束后再 `push` 会报错，先 `reset` 才能开始新流。空输入合法。

## 连续控制：保持状态改变速度和音高

`Stream::new_live` 的参数与 `Stream::new` 相同，但允许调用：

```moonbit
stream.set_controls(tempo=0.75, pitch_semitones=3.0, rate=1.0)
```

三个命名参数均须提供，验证通过后一起更新。普通固定流调用此方法会报错，已结束的动态流也会报错；`reset()` 后可以再次更新。重复设置相同值不重建对应滤波器。

连续控制不对音频切段、flush 或重建处理器。WSOLA 保留重叠尾部和累计分析时钟，速率转换保留小数相位与输入历史。变更从后续算法处理开始生效，可能影响已接受但尚未处理的前瞻 PCM；已经返回的 PCM 不会重算。动态总长度由实际经过的分析与重采样时钟决定，`finish()` 用当前比率排空剩余源距离，不按最后一个参数重新计算历史长度。

这是处理窗口边界上的立即控制更新，不提供按指定输入帧精确调度的自动化，也不提供无点击的参数 ramp。突然改变参数或滤波器可能产生过渡瞬态。若应用自行平滑控制，应明确其调度方式并实际测量。动态模式即使最初为全恒等，也保留前瞻与状态，以便随后跨越比率 1；其输出时机与固定恒等直通不同。

## FIFO：解码器与播放器采用不同块长

`Processor::new(..., quality?, adjustable?)` 封装同一 DSP 流和输出队列。`adjustable` 默认 `true`，采用上述动态语义；要获得固定控制精确帧数与离线结果一致性，传 `adjustable=false`。

| 方法 | 行为 |
| --- | --- |
| `put_samples(samples)` | 送入完整帧并把生成输出放入 FIFO，返回 `Unit` |
| `num_samples()` | 当前可读取的**帧数**，不是交织数组元素数 |
| `receive_samples(max_frames)` | 返回最多指定帧数的新数组，并从 FIFO 消费这些帧 |
| `read_into(destination, offset_frames, max_frames)` | 向现有数组写入，返回实际写入的帧数；偏移和长度均按帧计 |
| `finish()` | 排空 DSP 并把尾部放入 FIFO；重复调用不重复追加 |
| `set_controls(tempo~, pitch_semitones~, rate~)` | 仅允许 adjustable 模式，语义与动态 Stream 一致 |
| `clear()` | 丢弃 FIFO 与 DSP 历史，保留当前格式、档位、控制参数 |
| `input_frames()` / `output_frames()` | 累计接受 / 生成帧数；输出计数**包含尚未读取的帧** |
| `buffered_frames()` | DSP 中保留的 PCM 加上未读取的 FIFO 帧 |
| `controls()` / `latency_frames()` | 当前控制值 / 算法前瞻预算 |

`read_into` 要求目标数组包含完整帧，偏移与最大帧数非负且落在数组范围内。它只改写实际读出的范围，不清空其余元素；无效请求不会消费 FIFO。音频设备要求整块填充时，调用方应按返回帧数处理剩余区间，不能播放数组中上一次留下的样本。

```moonbit
test "fixed FIFO frames" {
  let processor = @moonstretch.Processor::new(8000, 2, adjustable=false)
  processor.put_samples([0.1, 0.2, 0.3, 0.4])
  processor.finish()
  let destination = Array::make(4, 99.0)
  assert_eq(processor.read_into(destination, 1, 1), 1)
  assert_eq(destination, [99.0, 99.0, 0.1, 0.2])
  assert_eq(processor.receive_samples(128), [0.3, 0.4])
  assert_eq(processor.num_samples(), 0)
}
```

完整的 256 帧输入、128 帧消费和连续参数变化示例见 [examples/player](../examples/player/main.mbt)。示例模拟设备块消费，实际音频设备接入由宿主完成。

DSP 历史有界不等于输出队列有界：不断 `put_samples` 而不读取时，FIFO 会增长。宿主需按 `num_samples()` 进行限量预取、及时消费和背压管理。当前实现会分配数组，`read_into` 也可能触发队列整理；不能声称整个处理器零分配或适合直接放进硬实时设备回调。

## BPM 估计与目标速度

`@bpm.Detector::new(sample_rate, channels, min_bpm?, max_bpm?, window_seconds?)` 接受完整帧分块；`estimate()` 查询当前结果，`finish()` 纳入部分尾窗口，`reset()` 开始新分析。离线入口为 `@bpm.analyze(samples, sample_rate, channels, min_bpm?, max_bpm?)`。

结果是 `Estimate?`：有结果时包含 `bpm`、`confidence`、`analyzed_seconds`；证据不足时为 `None`。`confidence` 是周期相关强度，不是正确概率。默认范围 60–200 BPM，可设 30–300 内递增上下限；默认保留最近 20 秒能量包络，检测器的窗口可设为 8–60 秒。静音、稳态音、无明显周期或分析长度不足可能无结果；半拍/倍拍歧义仍需听辨。详见 [BPM 说明](../bpm/README.md)。

目标 BPM 使用 `tempo = target_bpm / (source_bpm * rate)`，并检查结果仍处于 0.5–2 范围；Pitch 不改变节拍速度。应用应显示检测结果并允许使用已知的原始 BPM，不能把自动估计当作可靠标签。

## WAV 与命令行

`@wav.decode(bytes)` 返回含 `samples`、`sample_rate`、`channels` 的 `Audio`。`@wav.transform(bytes, tempo?, pitch_semitones?, rate?, quality?)` 解码、处理并编码，`@wav.encode(samples, sample_rate, channels)` 直接编码为 24-bit PCM WAV。

编解码复用 MoonWavKit 0.1.3：普通 RIFF/WAVE PCM 8/16/24/32-bit、IEEE Float32 输入；不承诺压缩 WAV 或 WAVE_FORMAT_EXTENSIBLE 的完整支持。输出不保留扩展元数据，超出 [-1,1] 的样本在整数编码时削波；核心 PCM 接口本身不削波。

```sh
node scripts/moonstretch.mjs input.wav slowed.wav --tempo 0.75 --quality speech
node scripts/moonstretch.mjs beat.wav --detect-bpm
node scripts/moonstretch.mjs beat.wav matched.wav --target-bpm 120 --source-bpm 100
```

CLI 支持 `--quality speech|balanced|music`、`--detect-bpm`、`--target-bpm`、`--source-bpm`、`--bpm-min` 和 `--bpm-max`。目标 BPM 与显式 `--tempo` 互斥；检测失败且未提供 source BPM 时拒绝自动变速。用 `-` 表示 WAV 字节的标准输入或输出。纯检测将 JSON 写到 stdout；变换时诊断写到 stderr，避免混入 WAV 数据。CLI 不覆盖已有输出文件。标准流接口仍整体缓存文件，不是增量 WAV 解码器。

`--stream` 为普通文件提供分块路径：最多读取 4,096 帧 PCM，复用 MoonBit WAV 适配器解码，使用固定配置 FIFO 并及时取数，逐块编码为 24-bit PCM。未知 RIFF 元数据按偏移跳过；单个 fmt 块限制为 64 KiB，输入必须能 seek，输出受 RIFF 32 位长度限制。它不支持 stdin/stdout 或自动 BPM 检测，但可用已知 `--source-bpm` 匹配目标。非法尾部样本或读取错误会删除本次新建的未完成输出。报告包含首批输出位置、最大输入读取字节数与观测到的保留 PCM 帧数，这些不是整个进程 RSS 指标。

## 宿主桥接

原有 `run`、`transform_pcm`、`transform_wav`、`encode_wav` 保留。`transform_pcm_quality` 接受质量名称；`live_create / live_put / live_read / live_set_controls / live_finish / live_clear / live_stats` 提供同一 FIFO 的宿主入口。`live_read` 返回新数组，不是 `read_into` 的零拷贝别名。`analyze_bpm` 返回 JSON 对象字符串或 `"null"`；`wav_decode` 与相关访问函数用于已解码 PCM 的复用。

`fixed_create` 的参数与 `live_create` 相同，但采用 `adjustable=false`，通过同一套 `live_put/read/finish/stats` 取数并保持固定参数的准确帧数；对该实例调用 `live_set_controls` 会报错。它用于文件管线，不会改变原有连续控制入口。

`run(request_json)` 保留固定 Balanced 配置的数值测试协议，字段为 sample_rate、channels、samples、tempo、pitch_semitones、rate，以及 1–1048576 范围的 chunk_frames；结果包含样本、格式和缓冲/前瞻信息，失败为 error 对象。带类型的其他 JS 导出验证失败时抛出宿主异常。MoonBit 调用方应优先使用类型化 API，宿主只承担 I/O、UI 和设备调度，DSP 位于 MoonBit。
