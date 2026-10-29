# 手动代接来电：桌面语音历史流程

本页记录 0.7.9 引入的**当前桌面 Codex 语音**手动代接流程，供维护和回归使用。0.8.3 推荐的「连接后监听 → 控制台手动接听 → 独立 Codex 自动语音」见 [自动语音与来电代接](CODEX-AUTOMATIC-VOICE.md)。2026-10-29 在开发者设备上，控制台手动接听真实来电后，机主确认双方声音和字幕正常，通话结束、手机空闲。呼叫等待、长时间稳定性和不同设备仍未验收。

## 使用流程

1. 手机端通话桥已启动，Mac 已配对并安装连续语音接口。使用已授权的测试手机呼入。
2. 在启用候选插件的 Codex 对话说明“代接当前来电”和交流目的。
3. 插件以 `phonebridge_prepare_incoming` 建立只接听任务；随后 `phonebridge_prepare_builtin_voice` 连接并准备连续音频。准备时已有来电就绑定该振铃；原振铃被替换时停止。空闲时只准备待机，不自动接听，机主之后明确要求接听时才绑定当前振铃。已有活动电话时不介入。
4. 保持已经运行的当前 Codex 语音。尚未启动时，等待文字回复结束再启动语音；首次音频准备可能仍需选择系统默认／PhoneBridge 虚拟输入，不能把用户说“语音已启动”当作实际采集端点已验证。
5. 机主确认后调用 `phonebridge_confirm_builtin_voice`，再调用 `phonebridge_answer_call`。接听前重新查询通话状态，原生程序在 ATA 首次写出前再次核对振铃实例。
6. 活动通话状态出现后启动 PCM 并切换连续音频至电话；AI 以「你好，请问有什么事情呢？」开场，被问身份时如实说明，双方字幕同步控制台。实际手机蓝牙路由、远端听见、输入识别仍分别验收。
7. 通话结束时调用 `phonebridge_end_call` 并确认手机空闲。返回机主音频但保留 Codex 语音；整个语音会话停止后再恢复原系统设备。

不自动接听下一通，不将另一通来电替换进当前任务。不支持来电等待、保持／合并、多路通话、自动代接规则、联系人识别或人工转接；不把来电显示或对方自报身份作为验证。当前只接入内置语音，不启用 Realtime API。

## 离线检查

```sh
c++ -std=c++17 integration/test-hfp-control-machine.cpp -o /tmp/hfp-outgoing-checks
/tmp/hfp-outgoing-checks
c++ -std=c++17 integration/test-hfp-incoming.cpp -o /tmp/hfp-incoming-checks
/tmp/hfp-incoming-checks
bash integration/build-bluetooth-call-control.sh
python3 integration/test-native-incoming.py
python3 plugins/phonebridge/mcp/test_server.py
python3 integration/test-plugin-call-session.py
python3 integration/test-coordinator-incoming.py
python3 integration/test-coordinator-bluetooth-dial.py
python3 integration/test-caption-web.py
bash scripts/build-app.sh
```

这些检查使用纯状态机、临时假依赖或参数校验，不连接手机、不采集音频、不读取钥匙串、不调用 API，也不安装生成的 App。

## 实机验收与回退

回归时不得在真实电话仍占用蓝牙时并行运行第二套控制器。先确认电话空闲，再切换测试构建；失败后保留本轮诊断，按已验证的版本恢复。

必须分别验证：

- 正常来电：接听、手机显示蓝牙、双方听见、双角色字幕、真正挂断和返回机主。
- 呼入方在准备期间挂断，另一通随后呼入：原任务不接听、不拒接后来的电话。
- 机主在手机上手动接听：候选不发送 ATA 或挂断这通非其接听的电话。
- 重复接听请求：同一任务最多一次 ATA；对方忙或要求结束时实际执行挂断。
- 控制／音频失败：报告未确认状态，清理已拥有的操作，不宣称电话已挂断。
- 候选版外拨回归：按原已授权测试号码验证拨号、双方连续语音、字幕、换号与挂断。

本页列出的是完整回归矩阵，不代表每个场景已通过。实际进度见 [验证记录](VALIDATION.md) 与 [连接恢复测试计划](CONNECTION-RECOVERY-TEST-PLAN.md)。
