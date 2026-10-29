# PhoneBridge HarmonyOS 手机伴侣

当前安装版本定义在 `AppScope/app.json5`：**0.4.10 / versionCode 22**。手机端为 Mac 提供配对身份核验、辅助蓝牙服务和会话生命周期；电话控制与声音仍由 Mac 和手机的数字蓝牙链路协作完成，不采集手机外放。

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
3. 用「连接设备」选择已配对的 Mac。手机伴侣进程运行、蓝牙和权限可用时，会保留只接受所选 Mac 的蓝牙待命入口；在 Mac 控制台点击「连接手机」可启动通话会话。首次也可点击手机上的「启动会话」。
4. 首次保持首页前台和屏幕亮起，在 Mac/Codex 完成连接与音频检查。
5. 点击同一按钮「停止会话」会停止当前通话准备，但手机伴侣进程运行期间仍保留所选 Mac 的蓝牙待命入口，以便下一次从 Mac 唤起。要完全停止后台蓝牙待命，需结束手机伴侣进程或关闭其蓝牙权限。

只保存选定电脑的蓝牙身份及自动准备偏好，不保存 API 密钥、联系人或用户通话录音。有效的已配对 Mac 消息会续期通话会话的八小时空闲保护；超时后暂停通话准备。Mac 控制通道在手机无通话、无拨号请求时若连续六秒没有收到数据，会回收旧客户端并重新接受连接。**八小时是应用层租约，不保证系统让后台蓝牙任务存活八小时。** 本机实测持续蓝牙连接、锁屏五分钟可用；Mac 主动断开后仅保留配对、锁屏约五分钟再连接曾超时，进程仍在但后台任务已停止。详情见 [连接恢复测试计划](../docs/CONNECTION-RECOVERY-TEST-PLAN.md)。普通蓝牙配对也无法唤起已被系统结束的 App：如果手机伴侣进程不存在，需先在手机打开一次。

`Index.ets` 的「运行信息」是诊断区，个别显示文字仍保留旧的小版本标记；安装版本以 `AppScope/app.json5` 为准。旧 HF/HSP 实验代码保留为底层实现和研究资料，不是新用户的手动操作步骤。

## 离线协议检查

使用 DevEco 自带 Node.js 在本目录执行：

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tests/slc-control.offline.cjs
```

协议检查不会连接真实设备，不能代替实际通话验收。完整安装和故障排查见 [项目 README](../README.md)。
