# 参与开发

优先提交可以独立复现的音频问题和真实使用反馈。报告中请给出 MoonStretch 版本、MoonBit 版本、编译后端、采样率、声道数、控制参数、分块方式、预期和实际行为。录音无法公开时，可提供能复现问题的合成信号；不要提交没有分发权的音乐或录音。

## 本地验证

使用 MoonBit 0.10.16+。Node.js 宿主工具要求 20+，独立检查脚本使用 Python 3.10+ 标准库。

```sh
moon update
moon fmt
moon check --target all --deny-warn
moon test --target all --deny-warn
moon build --target all --release --deny-warn
moon info
moon run --target wasm-gc examples/basic
moon build --target js --release
python scripts/audio_quality.py --output work/quality.json -- node scripts/quality_driver.mjs
```

检查 `moon info` 生成的接口变化，确认兼容性和文档。Windows Native 需要配置 MSVC；没有本地 C 编译器时可以先验证 JS、Wasm 和 Wasm GC，并查看 CI 的 Windows Native 结果，不能将未执行项记为通过。

## 变更要求

- DSP 修改应有能发现旧问题的回归用例，并验证时长、频率、通道关系和分块不变性。不要仅用固定输出快照证明算法正确。
- 变更公开参数或生命周期时，同步更新 README、API 与算法文档。不要静默扩大兼容承诺。
- 新增录音、依赖、算法参考和复制代码必须记录来源及许可证。算法理论借鉴与源码移植应分别说明。
- 性能报告保留命令、版本、输入、硬件和原始测量；主观音质结论需要相应听评证据。
- 提交以完整、可审阅的实际变更为单位，不通过空提交或无意义拆分增加记录。

源码、可复现脚本和必要小型用例进入 Git；构建目录、依赖下载、生成的 WAV 和测量工作目录不提交。公开内容不得包含密码、令牌或参赛者联系方式。项目申报材料保存在仓库之外。
