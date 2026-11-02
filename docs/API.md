# API 与数据约定

公共入口为 `Ridge-Lab/moonstretch`，WAV 适配包为
`Ridge-Lab/moonstretch/wav`，错误类型位于
`Ridge-Lab/moonstretch/types`。完整签名以各包的 `pkg.generated.mbti` 为准。

## PCM 与控制参数

- PCM 为交织 `Array[Double]`：立体声顺序是 `L0, R0, L1, R1, ...`。
- 一帧包含所有声道的一次采样；数组长度必须整除声道数。
- 采样率支持 8,000–192,000 Hz，声道数支持 1–8。调用方负责声道语义及布局。
- 输入必须是有限数字且绝对值不超过 `1e100`；NaN、Infinity 及超限幅度被拒绝。该上限为数值运算保留余量，日常使用推荐归一化 PCM；浮点核心不会自动限制到 `[-1,1]`。
- `tempo` 为 `0.5..2.0`，`pitch_semitones` 为 `-12..12`，`rate` 为 `0.5..2.0`。端点有效，默认值分别为 `1`、`0`、`1`。
- 输出采样率和声道数不变。半帧向上取整，最终长度为 `floor(input_frames / (tempo * rate) + 0.5)`。
- 音高的目标倍率是 `2^(pitch_semitones / 12) * rate`。`tempo` 不参与这个公式。

## 一次处理

```moonbit
@moonstretch.process(
  samples, sample_rate, channels,
  tempo=0.75, pitch_semitones=0.0, rate=1.0,
)
```

返回新的采样数组，内部使用同一套流式实现并完成尾部排空。输入数组不会被修改。
参数和输入错误抛出 `@types.AudioError`。`process` 需要容纳完整输入及输出；处理长录音时使用下面的流式接口并及时消费输出。

## 流式处理

调用包在 `moon.pkg` 导入 `Ridge-Lab/moonstretch`。下面的测试可以直接放入调用方的 `.mbt` 测试文件：

```moonbit
test "stream lifecycle" {
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
| `Stream::new(sample_rate, channels, tempo?, pitch_semitones?, rate?)` | 验证格式和参数，建立固定配置的处理器 |
| `push(samples)` | 接收任意数量的完整帧，返回当前可消费的输出；可能返回空数组 |
| `finish()` | 排空前瞻和尾部并完成帧数校正；重复调用返回空数组 |
| `reset()` | 丢弃未输出数据，清空计数和处理状态；采样率、声道数、控制参数保持不变 |
| `input_frames()` | 已接受的累计输入帧数，`Int64` |
| `output_frames()` | 已返回给调用方的累计输出帧数，`Int64` |
| `buffered_frames()` | 两级算法及待输出队列中保留的 PCM 帧；不含调用方数组和固定滤波器表 |
| `latency_frames()` | 以输入采样率帧数表示的保守算法前瞻预算；不含设备和宿主调度延迟 |
| `sample_rate()` / `channels()` | 当前格式 |

同一输入、相同配置的最终输出不依赖输入分块方式。所有声道使用同一个时间对齐位置，避免各声道独立拉伸导致相位关系漂移。输入可以按播放器或解码器的块大小直接送入，不要求窗口大小对齐。

调用方应完整消费每次 `push()` 和最终 `finish()` 返回的数据。`finish()` 后继续 `push()` 会报错；开始另一条相同配置的音频用 `reset()`，改变参数则创建新实例。空输入合法。参数或采样格式验证失败不会接受该次输入。单个组合流最多接受 `1,000,000,000,000` 帧；超限会报错，不支持无限时间跨度的单一实例。

## WAV 适配层

在调用包导入 `Ridge-Lab/moonstretch/wav`，别名为 `@wav`：

```moonbit
let transformed = @wav.transform(bytes, tempo=0.8, pitch_semitones=2.0)
let encoded = @wav.encode(samples, 48000, 2)
```

`transform` 委托 MoonWavKit 解码，执行 PCM 变换，再编码为 24-bit PCM WAV。
`encode` 直接将交织 PCM 编码为 24-bit WAV。输入容器支持边界来自固定依赖 `Ridge-Lab/moonwavkit@0.1.3`：普通 RIFF/WAVE PCM 8/16/24/32-bit 和 IEEE Float32；不承诺压缩格式或 WAVE_FORMAT_EXTENSIBLE 的完整支持。

输出不是原文件的字节级编辑：扩展元数据不会保留，超过 `[-1,1]` 的采样会由整数编码器削波。浮点核心和 WAV 接口有不同的峰值行为，应用需要更大动态范围时应直接使用 PCM 接口并选用自己的浮点编码器。

## 宿主接口

`bridge` 包为 Node.js 与浏览器导出 `run`、`transform_pcm`、`transform_wav` 和 `encode_wav`。
MoonBit 调用方应优先使用上面的类型化 API。

`run(request_json)` 的请求字段为 `sample_rate`、`channels`、`samples`、`tempo`、`pitch_semitones`、`rate` 和可选 `chunk_frames`；后者范围 `1..1048576`。成功响应含 `samples`、格式字段以及缓冲、首次输出、延迟测量。错误响应为包含 `error` 的 JSON 对象。`scripts/quality_driver.mjs` 将错误写入 stderr 并设置非零退出码。

CLI 和浏览器负责文件读取、用户交互及播放，DSP 计算位于 MoonBit。内部 `stretch` 和 `rate` 包用于分阶段测试；应用应通过根包获得稳定的组合语义。
