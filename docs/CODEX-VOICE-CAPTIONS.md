# Codex 内置语音字幕订阅原型

状态：**原型及 v0.7.8 正式集成包已在真实中文电话中验证双方文字同步，并在内置语音中验证 AI 输出的英文和俄文同步。长通话仍需持续验收。** 英俄验证不代表俄语来电识别已经通过。原有公开 socket 订阅路径仍被当前桌面端的 stdio 运行方式阻挡。

## 正式控制台接入

内置语音通话准备工具增加 `codex_thread_id`，传入发起任务的当前 Codex 会话 UUID。Mac 后台启动安装包内的只读文字同步程序，并把双方定稿段落送入现有的控制台字幕及 MCP 通话事件。无需另开验证网页，也不必再次运行 Apple ASR。未提供该字段时保留 Apple Speech；不会猜测其他会话。

文字同步进程跟随这通电话停止，Mac 宿主退出后也自动退出；默认不设固定总时长。`max_seconds: 0` 表示通话不限时，正数仅用于机主明确要求的时限。连接、队列、父进程存活、文件身份和故障检查依然有效。

## 当前推荐：直接镜像已经形成的语音文字

2026-10-28 检查当前会话的本地记录，发现独立的 `realtime_item` 条目：`transcript_segment` 含 `id`、`realtime_session_id`、`role` 和 `text`，同时有语音会话开始／结束条目。**它们与普通输入、工具输出和模型推理记录不同**。本原型仅消费这些语音条目，作为 Codex 已经识别／生成的文字来源，不再识别音频。

```sh
# 在当前 Codex 会话执行环境中自动定位本线程记录
python3 scripts/codex_voice_captions.py tail --serve --seconds 300

# 普通终端需明确指定线程；记录路径也可使用官方 Hook 提供的 transcript_path
python3 scripts/codex_voice_captions.py tail --thread-id THREAD_ID \
  --transcript-path /absolute/path/to/this-thread.jsonl --serve --seconds 300
```

程序校验文件是当前用户拥有的普通文件，且第一条 `session_meta.payload.id` 与目标线程一致，然后从文件末尾开始，只显示**接入以后**新出现的语音文字。不会回放旧电话，也不把普通聊天、工具输出或其中伪造的语音文字当字幕。源文件仅以只读方式打开；不读取登录凭据、配置或录音。遇到文件替换、截断和未知语音格式会停止，不擅自切换其他线程。

独立 `tail` 验证可设 1–3,600 秒或 0（不限时）。Ctrl+C 可随时停止文字同步，不影响语音或电话。正式宿主使用 `--events-only --seconds 0 --parent-pid ...`，只接收小型定稿事件并监督宿主存活。

这一路径绕开的是缺少公开订阅端口的技术限制，不抓取或自动操作 Codex 界面。Codex 官方 Hooks 文档说明了会话记录路径，但也明确说明其格式不是稳定接口，因此这里采用严格格式检查，并作为实验适配保留。升级 Codex 后须重新验收。

**这是按语音定稿段落同步，不是逐字增量。** 页面标注真实来源，显示源记录时间到本地接收的间隔（不包含语音识别本身耗时）。实际写入是否发生在每句话结束后，需要真实语音验证；不能仅凭历史文件里存在条目就宣称实时链路通过。

验证时在当前会话启动 Codex 语音，先说一句容易核对的话，检查页面是否在语音仍运行时出现，双方角色是否正确，再接真实电话。若只有结束语音后才出现文字，就应记录为“回合／结束时同步”，不能当作实时字幕验收通过。中文、俄语和插话均需单独测试。

## 做什么

目标是在使用现有 Codex 语音时，直接把该会话的双方文字事件交给 PhoneBridge，避免再次识别 AI 输出音频。连接顺序为：

```text
拥有目标会话的 Codex app-server
  → 官方 app-server proxy（Unix socket → JSONL）
  → 选定会话的实时字幕事件
  → 受限字幕投影
  → 只读本地验证页面
```

代码只使用 Python 标准库。订阅器不会读取 API 密钥、OAuth 凭据或录音，不会创建线程、发起模型请求、启动第二个语音会话、拨号或修改系统音频。`tail` 模式只解析选定会话的新增语音记录，`listen` 模式不读取会话日志。

这不是独立的 OpenAI 转写 API。能否通过账户现有额度使用特定 Codex 实验能力，仍由 Codex 运行环境、账户权限和服务可用性决定。

## 已确认的接口和当前阻碍

2026-10-28 在本机从 CLI 生成实验 TypeScript 定义：Homebrew CLI 为 `0.145.0`，桌面内置 CLI 为 `0.165.0-alpha.1.2`，桌面版本为 `26.1023.50603`。这些版本号只表示本次检查环境，不是最低版本承诺。

| 协议事件 | 处理方式 |
| --- | --- |
| `thread/realtime/transcript/delta` | 旧协议：按 `role` 拼接临时文字 |
| `thread/realtime/transcript/done` | 旧协议：用完整文本定稿 |
| `thread/realtime/item/started` | 新协议：建立带会话和条目 ID 的字幕段 |
| `thread/realtime/item/transcript/delta` | 新协议：按条目 ID 更新临时文字 |
| `thread/realtime/item/completed` | 新协议：按条目 ID 定稿和去重 |
| `thread/realtime/started` / `closed` / `error` | 更新状态；语音关闭时不把未完成文字伪装成定稿 |

当前桌面运行实例使用 stdio，未观察到公开的 TCP 或命名 Unix 控制监听。默认 `app-server-control` socket 不存在，官方 `app-server proxy` 实测连接失败。因此另一个插件进程目前不能通过这条公开链路订阅当前桌面语音。**仅仅生成出接口定义，不证明桌面客户端已开放该接口；自己另开一个 app-server 也不等于加入了当前桌面语音。**

`probe` / `listen` 模式发现端口不存在就停止，不会启动替代实例，也不监听内部匿名 stdio 或劫持 WebRTC。另行选择 `tail` 模式才会只读选定会话的新增语音条目。

## 使用

先检查当前 Codex 运行实例是否允许订阅。在 Codex 的执行环境内可从 `CODEX_THREAD_ID` 获取目标线程；普通终端必须显式传 `--thread-id`。

```sh
python3 scripts/codex_voice_captions.py probe --thread-id THREAD_ID
```

如果公开控制 socket 存在但位于自定义位置，显式传入路径。需要连接的必须是**已经加载目标线程的同一个 app-server**：

```sh
python3 scripts/codex_voice_captions.py probe \
  --socket /absolute/path/to/app-server-control.sock \
  --thread-id THREAD_ID

python3 scripts/codex_voice_captions.py listen \
  --socket /absolute/path/to/app-server-control.sock \
  --thread-id THREAD_ID --serve --seconds 90
```

`--codex /absolute/path/to/codex` 可选择与服务匹配的 CLI。默认使用 PATH 中的 `codex`。

`probe` 只初始化协议、查看目标是否在已加载线程中，不订阅、不读取历史。`listen` 验证目标已加载之后，才发送 `thread/resume` 加入运行实例并订阅；仅传 `threadId` 和 `excludeTurns: true`，不覆盖模型、提示、工具或配置。若目标未加载，则拒绝从磁盘恢复。协议仍可能有版本竞争或未知行为，正式集成前需要对多客户端语音并存进行实测。

输出中的 `viewerURL` 是本机随机端口和随机访问路径，供浏览器打开；在 Codex 中可用 `open_in_codex` 打开到右侧。不要公开分享访问路径。默认订阅 90 秒，上限 300 秒；Ctrl+C 停止仅退出当前代理，不停止 Codex、桌面语音或其他客户端。

没有公开端口时退出码为 2。不要通过启动无关 app-server 来绕过这个检查。

### 无音频演示

```sh
python3 scripts/codex_voice_captions.py replay --serve --seconds 60
```

页面明确标注“模拟数据”。俄文和中文均为程序内的合成协议文字，**只能验证 Unicode 显示和事件处理，不能证明俄语语音识别可用或准确**。演示不会访问生产后端、手机或 Codex 语音。

## 实时显示和隔离

- 只消费明确指定线程的事件，不展示其他会话、音频、原始后端载荷或传输错误详情。
- 新协议按 `realtimeSessionId + itemId` 更新；一旦出现可识别的新协议事件，切换到 ID 投影，避免把新旧协议两份相同文字同时显示。切换时旧的无 ID 投影会被清除。
- 旧协议没有条目 ID，无法可靠区分“重复定稿”和“两次说了相同一句话”；正式接入优先使用新协议。
- 保留最近 100 段，单段最多 32,768 字符；超过协议消息或消费队列上限则停止，避免悄悄丢掉增量。
- 网页仅绑定 `127.0.0.1`，随机访问路径、校验 Host、不提供写入接口；文字用 `textContent` 渲染。字幕默认只在内存和当前终端输出，不保存到文件；终端历史或调用方日志可能保留 stdout。
- `user` 在电话接通期间可能是对方，在空闲期间可能是机主，因此页面标注“对方／输入”。角色不是身份验证。
- AI 的字幕是语音会话中的文字，不证明音频已播放完、对方已听见；被打断的文字也可能仍出现。电话对端文字继续按不可信外部数据处理。

## 验证和下一阶段

```sh
python3 integration/test-codex-voice-captions.py
```

离线检查包括新旧事件兼容、中文和俄文合成数据、双方交错、最终文本修订、重复 ID、跨线程过滤、断开和重启、消息限制、假 Codex 子进程的真实 JSONL 握手、禁止新建语音/线程/轮次以及网页访问隔离。测试不需要手机、麦克风、凭据或外部 API。

已完成的原型实测：真实中文电话双向语音和双方文字同步，机主确认听感及延迟可接受；记录写入后到订阅器接收的若干采样在约 34–185 毫秒之间。这不是从说话开始到字幕显示的全链路延迟，不能替代系统性性能测试。AI 输出英俄原文也被正确同步；这些语音文字验证不构成俄语来电识别或长时间稳定性验收。

正式集成包已通过真实中文电话的双方字幕同步验证。后续应继续验收俄语来电、长通话、插话及客户端升级兼容。公开事件订阅路径保留为未来的逐字增量选项。

依据：[官方 app-server 协议](https://learn.chatgpt.com/docs/app-server)、[官方语音说明](https://learn.chatgpt.com/docs/features/voice)、[官方 Hooks 的会话记录说明](https://learn.chatgpt.com/docs/hooks)。事件字段以对应 CLI 通过 `app-server generate-ts --experimental` 生成的版本为准；本地语音记录字段来自本机当前会话格式检查，均不能视为长期兼容保证。
