import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { access, connection } from '@kit.ConnectivityKit';
import { call } from '@kit.TelephonyKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeState } from '../services/ProbeState';
import { HspAssistService, WirelessHelperStatus } from '../services/HspAssistService';
import { WirelessControlService } from '../services/WirelessControlService';
import { CompanionSettings } from '../services/CompanionSettings';

class DeviceRow {
  id: string = '';
  name: string = '';
}

class DeviceSelectOption implements SelectOption {
  value: string = '';
}

@Entry
@Component
struct Index {
  @State permissionGranted: boolean = false;
  @State bluetoothOn: boolean = false;
  @State busy: boolean = false;
  @State devices: DeviceRow[] = [];
  @State selectedPeer: string = '';
  @State active: boolean = false;
  @State stage: string = '等待开始';
  @State remaining: number = 0;
  @State callStatus: string = '尚未读取';
  @State notice: string = '';
  @State serviceMessage: string = '通话桥尚未启动。';
  @State helperState: string = 'idle';
  @State peerVerified: boolean = false;
  @State cleanupReady: boolean = true;
  @State diagnosticsExpanded: boolean = false;
  @State updated: string = '';
  private visible: boolean = false;
  private updating: boolean = false;
  private generation: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.visible = true;
    this.busy = false;
    this.generation++;
    WirelessControlService.observe((text: string, active: boolean) => {
      if (!this.visible) { return; }
      this.serviceMessage = text; this.active = active; this.updateStatus();
    });
    try { this.selectedPeer = CompanionSettings.selectedPeer(this.context()); }
    catch (error) { this.notice = '暂时无法读取已选设备，请重新选择。'; }
    this.refreshDevices();
    this.timer = setInterval(() => this.updateStatus(), 1000);
  }

  aboutToDisappear(): void {
    this.visible = false; this.generation++;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    WirelessControlService.observe(undefined);
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private hasPermission(): boolean {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return abilityAccessCtrl.createAtManager().checkAccessTokenSync(info.appInfo.accessTokenId,
        'ohos.permission.ACCESS_BLUETOOTH') === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) { return false; }
  }

  // This is the only permission request, and is only called by its explicit button.
  private async requestPermission(): Promise<void> {
    if (this.busy || this.active) { return; }
    const generation = this.generation;
    this.busy = true; this.notice = '';
    try {
      await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context(),
        ['ohos.permission.ACCESS_BLUETOOTH']);
      if (!this.visible || generation !== this.generation) { return; }
      this.permissionGranted = this.hasPermission();
      if (!this.permissionGranted) { this.notice = '蓝牙权限尚未允许。你可以在系统设置的应用权限中开启。'; }
      this.refreshDevices();
    } catch (error) {
      if (this.visible && generation === this.generation) { this.notice = '未能完成权限请求，请稍后重试。'; }
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  private refreshDevices(): void {
    this.permissionGranted = this.hasPermission();
    this.devices = [];
    this.bluetoothOn = false;
    if (!this.permissionGranted) { this.updateStatus(); return; }
    try {
      this.bluetoothOn = access.getState() === access.BluetoothState.STATE_ON;
      if (!this.bluetoothOn) { this.updateStatus(); return; }
      const rows: DeviceRow[] = [];
      for (const address of connection.getPairedDevices()) {
        const row = new DeviceRow(); row.id = address.toUpperCase(); row.name = '已配对设备';
        try { row.name = connection.getRemoteDeviceName(address) || row.name; } catch (error) {}
        rows.push(row);
      }
      this.devices = rows;
    } catch (error) { this.notice = '暂时无法读取已配对设备，请检查蓝牙后刷新。'; }
    this.updateStatus();
  }

  private async chooseDevice(device: DeviceRow): Promise<void> {
    if (this.busy || this.active) { return; }
    const generation = this.generation;
    this.busy = true; this.notice = '';
    try {
      // Recheck the current pairing before persisting a user selection.
      if (!this.hasPermission() || !connection.getPairedDevices().some((id: string) => id.toUpperCase() === device.id)) {
        this.notice = '此设备已不在配对列表中，请刷新后重新选择。'; return;
      }
      await CompanionSettings.selectPeer(this.context(), device.id);
      if (this.visible && generation === this.generation) { this.selectedPeer = device.id; }
    } catch (error) {
      if (this.visible && generation === this.generation) { this.notice = '设备选择未能保存，请重试。'; }
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  private selectedName(): string {
    const device = this.devices.find((row: DeviceRow) => row.id === this.selectedPeer);
    return device ? device.name : (this.selectedPeer.length > 0 ? '已保存的设备当前不在配对列表中' : '尚未选择设备');
  }

  private selectedAvailable(): boolean {
    return this.devices.some((row: DeviceRow) => row.id === this.selectedPeer);
  }

  private async startSession(): Promise<void> {
    if (this.busy || this.active) { return; }
    const generation = this.generation;
    this.busy = true; this.notice = '';
    try {
      if (!this.hasPermission()) { this.notice = '请先允许蓝牙权限。'; return; }
      if (access.getState() !== access.BluetoothState.STATE_ON) { this.notice = '请先在系统设置中开启蓝牙。'; return; }
      const peer = this.selectedPeer;
      if (!CompanionSettings.validPeer(peer) || !connection.getPairedDevices().some((id: string) => id.toUpperCase() === peer)) {
        this.notice = '请先选择一个当前已配对的设备。'; return;
      }
      const state = await call.getCallState();
      if (!this.visible || generation !== this.generation) { return; }
      if (state !== call.CallState.CALL_STATE_IDLE) { this.notice = '请先结束手机现有通话，再启动会话。'; return; }
      const helper = HspAssistService.wirelessStatus();
      if (helper.active || helper.pendingConnect || !helper.cleanupSucceeded) {
        this.notice = '上一连接仍在结束，请点击停止会话后重试。'; return;
      }
      // No timer or foreground callback ever calls start: reconnect is explicit.
      WirelessControlService.start(this.context(), peer);
      this.updateStatus();
      if (!this.active) { this.notice = '会话未能启动，请查看连接状态后重试。'; }
    } catch (error) {
      const failure = error as BusinessError;
      this.notice = `会话未能启动，请重试（${failure.code || 0}）。`;
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  private stopSession(): void {
    WirelessControlService.stop('会话已停止。');
    this.updateStatus();
    this.notice = this.active || !this.cleanupReady
      ? '连接结束尚未确认，请再次点击停止会话。'
      : '本次连接已结束。需要再次使用时，请点击启动会话。';
  }

  private updateStatus(): void {
    if (!this.visible || this.updating) { return; }
    this.updating = true;
    try {
    WirelessControlService.checkDeadline();
    const helper: WirelessHelperStatus = HspAssistService.wirelessStatus();
    this.helperState = helper.state;
    this.peerVerified = helper.peerVerified;
    this.cleanupReady = helper.cleanupSucceeded && !helper.pendingConnect;
    this.remaining = this.active ? Math.max(0, helper.remainingSeconds) : 0;
    this.permissionGranted = this.hasPermission();
    try { this.bluetoothOn = this.permissionGranted && access.getState() === access.BluetoothState.STATE_ON; }
    catch (error) { this.bluetoothOn = false; }
    if (this.active && (!this.permissionGranted || !this.bluetoothOn)) {
      WirelessControlService.stop('蓝牙已不可用，会话已停止。'); return;
    }
    if (!this.cleanupReady) { this.stage = '正在结束连接'; }
    else if (!this.active) { this.stage = '等待开始'; }
    else if (!helper.active && helper.state === 'stopped') { this.stage = '通话连接已结束，请停止本次会话'; }
    else if (helper.slcControlComplete && helper.peerVerified) { this.stage = '控制连接已就绪，电话声音待验证'; }
    else if (helper.peerVerified) { this.stage = '设备已连接，正在准备通话'; }
    else if (helper.state === 'starting') { this.stage = '正在准备连接'; }
    else { this.stage = '等待所选设备连接'; }
    try {
      const state = call.getCallStateSync();
      if (state === call.CallState.CALL_STATE_IDLE) { this.callStatus = '当前无通话'; }
      else if (state === call.CallState.CALL_STATE_RINGING) { this.callStatus = '有来电'; }
      else if (state === call.CallState.CALL_STATE_OFFHOOK) { this.callStatus = '拨号、通话或保持中'; }
      else { this.callStatus = '通话状态未知'; }
    } catch (error) { this.callStatus = '暂时无法读取通话状态'; }
    this.updated = new Date().toLocaleTimeString();
    ProbeState.report = `PhoneBridge: version=0.4.7; permission=${this.permissionGranted}; bluetooth=${this.bluetoothOn}; active=${this.active}; stage=${helper.state}; remaining=${this.remaining}; call=${this.callStatus}`;
    } finally { this.updating = false; }
  }

  private deviceOptions(): Array<SelectOption> {
    return this.devices.map((device: DeviceRow) => {
      const option = new DeviceSelectOption();
      option.value = device.name;
      return option;
    });
  }

  private selectedIndex(): number {
    return this.devices.findIndex((device: DeviceRow) => device.id === this.selectedPeer);
  }

  private sessionActionLabel(): string {
    if (this.busy) { return '正在处理…'; }
    if (!this.cleanupReady) { return '重试停止'; }
    return this.active ? '停止会话' : '启动会话';
  }

  private sessionActionEnabled(): boolean {
    if (this.busy) { return false; }
    if (this.active || !this.cleanupReady) { return true; }
    return this.permissionGranted && this.bluetoothOn && this.selectedAvailable();
  }

  private sessionAction(): void {
    if (this.active || !this.cleanupReady) { this.stopSession(); }
    else { this.startSession(); }
  }

  private sessionBadge(): string {
    if (!this.cleanupReady) { return '正在释放'; }
    if (!this.active) { return '未启动'; }
    if (this.peerVerified && this.helperState === 'hf-control-complete') { return '控制已就绪'; }
    if (this.peerVerified) { return '电脑已连接'; }
    return '等待电脑';
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Row() {
          Column({ space: 5 }) {
            Text('PhoneBridge').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2F63D8').letterSpacing(1.2)
            Text('通话桥').fontSize(34).fontWeight(FontWeight.Bold).fontColor('#111827')
            Text('让 Mac 安全接入手机通话').fontSize(15).fontColor('#697386')
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Row({ space: 6 }) {
            Text('●').fontSize(10).fontColor(this.active ? '#18A06A' : '#98A2B3')
            Text(this.sessionBadge()).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.active ? '#116B4B' : '#596579')
          }.padding({ left: 11, right: 11, top: 7, bottom: 7 }).borderRadius(18)
            .backgroundColor(this.active ? '#E8F8F1' : '#EEF1F5')
        }.width('100%').alignItems(VerticalAlign.Center)

        Column({ space: 16 }) {
          Row() {
            Text('连接状态').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1A2233')
            Blank()
            Text(this.updated.length > 0 ? '更新于 ' + this.updated : '')
              .fontSize(12).fontColor('#8A94A6')
          }.width('100%')

          Column({ space: 7 }) {
            Text(this.stage).id('wireless-status').fontSize(25).fontWeight(FontWeight.Bold)
              .fontColor('#15213A').width('100%')
            Text(this.active
              ? '已验证的 Mac 会自动续期；失联后会安全结束。'
              : '选择已配对的 Mac，然后启动通话桥。')
              .fontSize(14).fontColor('#697386').lineHeight(21).width('100%')
          }.width('100%')

          Row({ space: 8 }) {
            Row({ space: 6 }) {
              Text('●').fontSize(10).fontColor(this.permissionGranted ? '#18A06A' : '#D97706')
              Text(this.permissionGranted ? '蓝牙权限已允许' : '蓝牙权限未允许')
                .fontSize(13).fontColor(this.permissionGranted ? '#116B4B' : '#9A5410')
            }.padding({ left: 10, right: 10, top: 7, bottom: 7 }).borderRadius(16)
              .backgroundColor(this.permissionGranted ? '#E8F8F1' : '#FFF3DF')

            Row({ space: 6 }) {
              Text('●').fontSize(10).fontColor(this.bluetoothOn ? '#18A06A' : '#D97706')
              Text(this.bluetoothOn ? '蓝牙已开启' : '蓝牙未开启')
                .fontSize(13).fontColor(this.bluetoothOn ? '#116B4B' : '#9A5410')
            }.padding({ left: 10, right: 10, top: 7, bottom: 7 }).borderRadius(16)
              .backgroundColor(this.bluetoothOn ? '#E8F8F1' : '#FFF3DF')
          }.width('100%')

          Button(this.sessionActionLabel()).id('session-toggle').width('100%').height(52).borderRadius(14)
            .fontSize(16).fontWeight(FontWeight.Medium)
            .backgroundColor(this.active || !this.cleanupReady ? '#EEF2F8' : '#2F63D8')
            .fontColor(this.active || !this.cleanupReady ? '#34435E' : Color.White)
            .enabled(this.sessionActionEnabled()).onClick(() => { this.sessionAction(); })
        }.padding(20).borderRadius(22).backgroundColor(Color.White).width('100%')
          .shadow({ radius: 18, color: '#120F1B2A', offsetX: 0, offsetY: 6 })

        Column({ space: 15 }) {
          Row() {
            Column({ space: 3 }) {
              Text('蓝牙与设备').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1A2233')
              Text('只允许你选择的已配对电脑连接').fontSize(13).fontColor('#7A8598')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Button('刷新').id('refresh-devices').type(ButtonType.Normal).height(34).borderRadius(17)
              .fontSize(13).fontColor('#2F63D8').backgroundColor('#EDF3FF')
              .enabled(!this.busy && !this.active).onClick(() => { this.refreshDevices(); })
          }.width('100%').alignItems(VerticalAlign.Center)

          if (!this.permissionGranted) {
            Column({ space: 12 }) {
              Text('允许蓝牙权限后即可读取已配对设备。')
                .fontSize(14).fontColor('#697386').width('100%')
              Button('允许蓝牙权限').id('bluetooth-permission').width('100%').height(48).borderRadius(14)
                .backgroundColor('#2F63D8').enabled(!this.busy && !this.active)
                .onClick(() => { this.requestPermission(); })
            }.width('100%')
          } else if (this.devices.length === 0) {
            Column({ space: 5 }) {
              Text('没有找到已配对设备').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#334155')
              Text('请先在系统蓝牙设置中完成配对，再点击刷新。')
                .fontSize(14).fontColor('#7A8598').width('100%')
            }.padding(16).borderRadius(14).backgroundColor('#F6F8FB').width('100%')
          } else {
            Column({ space: 8 }) {
              Text('连接设备').fontSize(13).fontColor('#697386').width('100%')
              Select(this.deviceOptions()).id('paired-device-select')
                .selected(Math.max(0, this.selectedIndex()))
                .value(this.selectedAvailable() ? this.selectedName() : '请选择已配对的电脑')
                .font({ size: 16, weight: FontWeight.Medium }).fontColor('#1A2233')
                .width('100%').height(50).borderRadius(13).backgroundColor('#F5F7FA')
                .enabled(!this.busy && !this.active)
                .onSelect((index: number) => {
                  if (index >= 0 && index < this.devices.length) { this.chooseDevice(this.devices[index]); }
                })
              Row({ space: 6 }) {
                Text('●').fontSize(9).fontColor(this.selectedAvailable() ? '#18A06A' : '#98A2B3')
                Text(this.selectedAvailable() ? '设备已选择并保存在本机' : '尚未选择设备')
                  .fontSize(13).fontColor(this.selectedAvailable() ? '#116B4B' : '#697386')
              }.width('100%')
            }.width('100%')
          }
        }.padding(20).borderRadius(22).backgroundColor(Color.White).width('100%')
          .shadow({ radius: 18, color: '#120F1B2A', offsetX: 0, offsetY: 6 })

        Column({ space: 13 }) {
          Row() {
            Text('手机状态').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1A2233')
            Blank()
            Row({ space: 6 }) {
              Text('●').fontSize(9).fontColor(this.callStatus === '当前无通话' ? '#18A06A' : '#D97706')
              Text(this.callStatus).fontSize(13).fontColor('#596579')
            }.padding({ left: 10, right: 10, top: 7, bottom: 7 }).borderRadius(16)
              .backgroundColor('#F2F4F7')
          }.width('100%')
          Text(this.active
            ? '前台会话期间保持屏幕亮起，停止后恢复正常息屏。Mac 连接后会显示后台蓝牙通知。'
            : '启动后保持此页面在前台，Mac 会自动完成控制连接。')
            .fontSize(14).fontColor('#697386').lineHeight(21).width('100%')
        }.padding(20).borderRadius(22).backgroundColor(Color.White).width('100%')
          .shadow({ radius: 18, color: '#120F1B2A', offsetX: 0, offsetY: 6 })

        if (this.notice.length > 0) {
          Row({ space: 9 }) {
            Text('!').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#A45118')
            Text(this.notice).id('user-notice').fontSize(14).fontColor('#8B4513').layoutWeight(1)
          }.padding(14).borderRadius(14).backgroundColor('#FFF3E5').width('100%')
        }

        Column({ space: 10 }) {
          Row() {
            Text('运行信息').fontSize(14).fontColor('#697386')
            Blank()
            Text(this.diagnosticsExpanded ? '收起' : '展开').fontSize(14).fontColor('#2F63D8')
          }.width('100%').onClick(() => { this.diagnosticsExpanded = !this.diagnosticsExpanded; })
          if (this.diagnosticsExpanded) {
            Divider().color('#E7EAF0')
            Text('版本 0.4.7 · ' + this.updated).fontSize(12).fontColor('#7A8598').width('100%')
            Text(this.serviceMessage).fontSize(12).fontColor('#7A8598').width('100%')
            Text('连接阶段：' + this.helperState + '\n设备身份已核验：' +
              (this.peerVerified ? '是' : '否') + '\n上一连接已清理：' +
              (this.cleanupReady ? '是' : '尚未确认') + '\n空闲保护：Mac 心跳自动续期')
              .fontSize(12).fontColor('#7A8598').lineHeight(19).width('100%')
          }
        }.padding({ left: 4, right: 4 }).width('100%')
      }.width('100%').padding({ left: 20, right: 20, top: 46, bottom: 40 })
    }.height('100%').width('100%').backgroundColor('#F4F6F9')
  }
}
