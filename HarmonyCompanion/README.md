# PhoneBridge HarmonyOS 手机伴侣

当前安装版本定义在 `AppScope/app.json5`：**0.4.9 / versionCode 21**。手机端为 Mac 提供配对身份核验、辅助蓝牙服务和会话生命周期；电话控制与声音仍由 Mac 和手机的数字蓝牙链路协作完成，不采集手机外放。

## 构建与安装

1. 在 DevEco Studio 中打开本目录，安装工程配置的 SDK。
2. 用自己的开发者身份和目标手机配置签名。公开的 `build-profile.json5` 不含开发者个人的 `signingConfigs`、密码、证书及设备授权。
3. 首次开发安装可以通过 USB/HDC，按手机系统要求解锁、允许调试并运行 `entry`。
4. 正常电话控制和音频走蓝牙；USB 安装成功不代表蓝牙通话已经可用。

IDE 已准备好工具链、依赖和签名后：

```sh
bash build.sh
```

默认 DevEco 位置为 `/Applications/DevEco-Studio.app/Contents`，可通过 `PHONEBRIDGE_DEVECO_CONTENTS` 改为自己的安装目录。HAP 位于 `entry/build/default/outputs/default/entry-default-signed.hap`。没有目标手机签名授权的调试 HAP 不能承诺在其他手机安装成功。

## 手机上的正常操作

1. 在系统设置中完成 Mac 与手机蓝牙配对。
2. 打开通话桥，允许蓝牙权限，点击设备区顶部「刷新」。
3. 用「连接设备」选择已配对的 Mac，点击单一状态按钮「启动会话」。
4. 首次保持首页前台和屏幕亮起，在 Mac/Codex 完成连接与音频检查。
5. 不再使用时点击同一按钮「停止会话」。

只保存选定电脑的蓝牙身份，不保存 API 密钥、联系人或用户通话录音。有效的已配对 Mac 消息续期十五分钟空闲保护；不是固定运行六分钟后强制停止。后台蓝牙任务及短时重连保护已有实现，但实际锁屏/后台行为依赖手机系统和节电策略，需逐机验收。

`Index.ets` 的「运行信息」是诊断区，个别显示文字仍保留旧的小版本标记；安装版本以 `AppScope/app.json5` 为准。旧 HF/HSP 实验代码保留为底层实现和研究资料，不是新用户的手动操作步骤。

## 离线协议检查

使用 DevEco 自带 Node.js 在本目录执行：

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tests/slc-control.offline.cjs
```

协议检查不会连接真实设备，不能代替实际通话验收。完整安装和故障排查见 [项目 README](../README.md)。
