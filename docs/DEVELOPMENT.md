# 开发与验收

## 构建

在 macOS 上按 README 构建。SwiftPM 使用 `swift build -c release --show-bin-path` 定位产物；不要硬编码 `.build/arm64-.../release`。`scripts/build-app.sh` 会重建原生助手及签名 App，更新本地签名可能需要重新授予权限。

`integration/continuous-audio/build-drivers.py` 生成旧桌面语音路径所需的两个虚拟驱动；`package-preview.py` 按已构建 App 的实际版本打包 App 和驱动安装包，不执行安装或拨号。推荐的独立 Codex 自动语音不依赖虚拟驱动。首次安装驱动时会重载系统音频，请由用户在空闲时完成。

手机工程的公开配置无签名，开发者在 DevEco Studio 中配置自己的证书及设备。保留公开 `build-profile.json5` 的无签名状态；提交前先移除 IDE 写入的个人配置。

## 可在无电话环境运行的检查

以下检查使用离线桩或本机临时 HTTP 测试，不拨号、不使用 API。需要本机 Swift 编译器；不要把测试通过等同于真实音频成功。

```sh
swift run BridgeChecks
python3 integration/test-managed-voice-runtime.py
python3 plugins/phonebridge/mcp/test_server.py
python3 integration/test-coordinator-bluetooth-dial.py
python3 integration/test-coordinator-incoming.py
python3 integration/test-plugin-call-session.py
python3 integration/test-caption-web.py
python3 integration/test-builtin-captions.py
```

`test-builtin-captions.py` 检查配置、权限和生命周期，不是实时麦克风录音验证。部分旧测试会在 `integration/` 写出带日期的 JSON 报告，这些生成物已忽略，不应提交个人实测数据。

`integration/test-modern-caption-duplex.py` 属于需单独评估的本机识别验证：会使用本机语音模型处理合成测试声音，不应和完全离线桩混称。手机协议测试需要 DevEco 的 TypeScript 工具链，详见 `HarmonyCompanion/README.md`。

## 新用户的真实验收清单

- [ ] 正确选择、持久化两端配对身份；错误设备不会被自动替代。
- [ ] 后台可启动、控制台可由插件获取并在 Codex 侧边打开。
- [ ] 新 Codex 对话能发现 14 个插件工具，独立自动语音运行时已安装并可用。
- [ ] 只对用户明确授权的号码拨号，手机默认 SIM 符合预期。
- [ ] 远端接听后手机显示蓝牙路由，双方能清楚听见，不靠声学免提。
- [ ] 同一通电话能多轮对话，字幕同时包含 AI 和对方。
- [ ] 结束工具确实挂断，手机空闲得到确认。
- [ ] 控制台手动接听当前来电，验证声音、双方字幕和结束后的空闲状态；自动代接默认关闭。
- [ ] 保持同一 Codex 语音，能再打第二个获授权号码并恢复机主通路。
- [ ] 整个语音结束后，默认音频回到原有设备。
- [ ] 蓝牙断开、锁屏/后台和重连时状态明确，不把失败显示成成功。

已在开发者设备完成的短时呼出、手动接听和自动代接验收，不能代替另一套硬件、长时间锁屏或异常恢复检查。当前 README 区分已验证的独立 Codex 自动语音、旧桌面内置语音、尚待独立实机验收的 Realtime API，以及未完成的普遍兼容和正式签名发行。

## 重现控制台文档截图

```sh
python3 scripts/preview-console.py
```

打开脚本输出的本地地址即可查看。它直接使用产品的 `console.html`，只提供内置示例状态，不读取 PhoneBridge 运行时、API 密钥或历史字幕，不连接手机，不采集音频，不支持 POST 命令。截取完成后按 Ctrl+C 停止。它是文档预览，不是实际通话控制台。

手机截图则来自已安装伴侣 App 的实际首页，未启动会话或拨号。截图来源及示例数据说明见 [截图说明](assets/README.md)。

## 提交与发布

不要提交 `dist/`、`.build/`、诊断日志、通话文字、联系人/设备信息、生成的 MCP 配置和签名密钥。仓库保留的 `bluetooth-test.pcm` 是随应用分发的固定测试语音资源，不是用户通话录音。

发布前核对 Mac `Info.plist` 的版本生成逻辑、插件清单、手机 `AppScope/app.json5` 和 README。GitHub 源码发布、正式签名二进制发行、Codex 插件目录公开上架是三个不同步骤。
