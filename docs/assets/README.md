# README 截图说明

截图日期：2026-10-28。

- `mobile-companion.jpg`：HarmonyOS 手机伴侣 0.4.9 的实机首页截图。通过开发调试连接打开已安装 App、截取画面，未启动会话或拨号。未展开诊断区或设备列表，不含号码、蓝牙地址或通话内容。
- `call-console.jpg`：直接由产品 `Sources/PhoneBridge/Resources/Web/console.html` 渲染并截图。数据来自 `scripts/preview-console.py` 的固定示例；页面明确标记为文档演示。设备地址、号码、任务与字幕均为合成示例，不是用户的真实设备或历史通话。
- `phonebridge-icon.png`：已选定的手机 App 白底图标。
- `phonebridge-auto-answer-settings.jpg`：0.8.x 开发控制台的自动语音与来电自动代接设置区域截图。用于说明开关位置和默认关闭状态；不代表当前实时状态，界面细节可能随版本调整。

上述界面图均未使用 AI 重绘。控制台演示只用于说明界面布局，不能作为新的真实通话验收证据。发布前已检查截图可见内容，未公开实际 API 配置、私密控制台 URL、真实号码或历史字幕。
