# 流式 BPM 估计

`Ridge-Lab/moonstretch/bpm` 从已解码的交织 PCM 估计周期性起音的速度，适用于有清楚节拍的伴奏分析和目标 BPM 变速。它由 MoonBit 实现，不调用 SoundTouch；不执行曲风识别、拍号识别或逐拍事件标注。

## 接口

在调用方的 `moon.pkg` 中导入 `Ridge-Lab/moonstretch/bpm`，随后使用：

```moonbit
let detector = @bpm.Detector::new(48000, 2, min_bpm=60.0, max_bpm=200.0)
detector.push(first_pcm_chunk)
detector.push(next_pcm_chunk)
match detector.finish() {
  Some(estimate) => println("BPM: \{estimate.bpm}"),
  None => println("没有足够强的周期性节拍证据"),
}
```

`push` 接受任意完整帧分块，错误输入在接受数据之前被拒绝。`estimate` 可在流未结束时查询；`finish` 提交最后一个不完整能量窗口，重复调用返回相同结果。结束后再次输入会报错，`reset` 清空分析状态并保留配置。`analyze(samples, sample_rate, channels, min_bpm?, max_bpm?)` 提供同一检测器的离线入口。

采样率和声道范围沿用 PCM 核心：8–192 kHz、1–8 声道。默认 BPM 搜索范围为 60–200，可在 30–300 之间设置严格递增的上下限；搜索范围应结合用途指定，不是检测准确率保证。至少需要四秒数据和最慢候选速度的三个周期。

## 算法与内存

每个声道分别累积平方能量，再合成为每秒 200 个 RMS 观察值；反相立体声不会相互抵消。采样时钟按整数余数推进，44.1 kHz 等采样率及输入分块均不会改变能量窗口的位置。检测阶段进行局部平滑、正向能量差分、中心化归一自相关、局部峰分析和抛物线周期插值。

默认仅保留最近 20 秒的能量包络，可通过 `window_seconds` 设置为 8–60 秒。状态最多保存 `200 * window_seconds` 个能量值和一个未完成窗口的累积量，不保留原始 PCM。估计时产生同样有界的临时数组，自相关成本随窗口长度和搜索范围变化；此分析不应在每个音频设备采样回调内重复执行。

`input_frames()` 是累计输入帧数，`buffered_envelope_frames()` 是当前保留的能量观察值数目。`Estimate` 提供 `bpm`、`confidence`、`analyzed_seconds`；后者是当前有效分析窗口长度，而不是整段输入总长度。

## 结果含义与限制

`confidence` 为选中周期的归一自相关强度（0–1），不是“BPM 正确概率”。静音、低动态稳态信号、数据不足或没有明显周期峰时返回 `None`。返回 `None` 不代表录音没有音乐节奏，只表示这一能量起音检测器没有获得足够强的周期性证据。

强弱拍、切分、细分音符、持续变速和复合节拍可导致半拍/倍拍或其他歧义；限制搜索范围和人工试听有助于判断。算法倾向选择强度接近的较短重复周期，不能以此推断曲目的音乐学拍号。没有宣称对任意真实音乐的准确率；自动调整目标 BPM 时，调用方应展示检测结果，允许手动指定原始 BPM。

## 验证

`moon test --target js bpm --deny-warn` 验证合成衰减打击音的多种速度、六种采样率、反相和八声道输入、极低/高幅度、逐帧分块、部分尾窗口、静音/稳态纯音/非周期噪声、滚动窗口上限、重置与错误状态。测试验证可测量的算法性质，不替代真实音乐数据集评估。
