# 参与贡献

欢迎提交可复现的问题、文档改进、离线测试和跨平台适配。先阅读 [README](README.md)、[架构](docs/ARCHITECTURE.md) 和 [路线图](docs/ROADMAP.md)。

## 开始前

- 本项目采用 [Apache-2.0](LICENSE)，第三方代码按各自许可保留。提交贡献即表示你有权提交这些内容，并愿意按项目许可贡献；不要带入未经授权的公司代码或其他项目的代码。
- 大规模重构或新的平台后端，先开 Issue 讨论目标、公开 API 能力、权限边界和验收方法。
- 请遵守 [社区行为准则](CODE_OF_CONDUCT.md)。漏洞、凭据或涉及隐私的问题请按 [安全政策](SECURITY.md) 私下反馈。

## 开发流程

1. Fork 仓库，从最新 `main` 创建分支，一次 PR 尽量解决一个明确问题。
2. 按 README 构建。手机签名使用自己的开发者账号和设备，生成的 MCP 配置使用自己的本机路径。
3. 修改后运行相关离线检查，说明影响和局限。纯文档修正不要求编译全部程序。
4. 提交 PR，说明问题、最终行为、验证方法和未验证部分。界面修改附上不含个人数据的截图。
5. 收到审查意见后在同一分支更新，不直接向维护者的发布分支推送。

## 离线检查

```sh
python3 scripts/check-source.py
python3 plugins/phonebridge/mcp/test_server.py

# 下列检查需要支持当前 SDK 的 macOS / Swift 环境。
swift run BridgeChecks
python3 integration/test-coordinator-bluetooth-dial.py
python3 integration/test-caption-web.py
python3 integration/test-builtin-captions.py
python3 integration/test-realtime-conversation.py
```

这些测试使用桩或本机临时服务，不拨电话、不使用真实 API 密钥、不采集真实声音。GitHub Actions 只运行这类离线检查，不连接贡献者或维护者的手机。手机侧协议检查需要 DevEco 工具链，见 [手机伴侣说明](HarmonyCompanion/README.md)。

真实硬件测试必须另行获得机主和接听方同意。使用本人接听或明确同意的号码，注明系统、硬件、版本、方向、重复次数和真实听感。不要把接口受理、蓝牙已配对或字幕出现当作整条通话链路通过。

## 跨平台贡献

优先保持任务接口一致：准备、拨号、接听状态、双向音频、字幕事件、挂断及清理。先调查平台公开能力与权限，再实现后端；不要假定任意普通手机 App 都能获得电话音频。新增平台不得破坏现有 macOS / HarmonyOS 路径，也不能静默回退到声学转接或无关设备。

## 提交内容

不要提交 API 密钥、签名密码和证书、HAP、个人 `.mcp.json`、通话记录、真实号码、蓝牙地址、设备序列号、运行时 URL/令牌或未脱敏日志。不要在 Issue 或 PR 里粘贴这些信息。修改 Apple 示例等第三方文件时，应保留原许可、版权及修改说明。

合并以可读性、可复现验证和真实证据为依据。跨平台实现先标记为实验性，完成相应硬件验收后再更新支持矩阵。
