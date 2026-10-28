import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeState } from '../services/ProbeState';
import { HspAssistService } from '../services/HspAssistService';
import { WirelessControlService } from '../services/WirelessControlService';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;
  private screenTimer: number = -1;
  private foreground: boolean = false;
  private screenDesired: boolean | undefined = undefined;
  private screenApplied: boolean = false;
  private screenError: string = '';
  private screenWork: Promise<void> = Promise.resolve();

  private updateScreen(): void {
    const target = this.mainWindow;
    if (!target) { return; }
    const enabled = this.foreground && WirelessControlService.isActive();
    if (this.screenDesired === enabled) { return; }
    this.screenDesired = enabled;
    // Serialize writes so a late enable cannot override Stop/background.
    this.screenWork = this.screenWork.catch(() => {}).then(async () => {
      if (this.mainWindow !== target) { return; }
      try {
        await target.setWindowKeepScreenOn(enabled);
        if (this.mainWindow !== target) { return; }
        this.screenApplied = enabled; this.screenError = '';
      } catch (error) {
        this.screenError = `${(error as BusinessError).code}`;
      }
    });
  }

  onDump(params: Array<string>): Array<string> {
    return [ProbeState.report, HspAssistService.dump(), WirelessControlService.dump(),
      `PhoneBridgeScreen: requested=${this.screenDesired}; applied=${this.screenApplied}; foreground=${this.foreground}; error=${this.screenError}`];
  }

  onForeground(): void {
    this.foreground = true;
    WirelessControlService.setForeground(true);
    WirelessControlService.checkDeadline();
    HspAssistService.checkDeadline();
    if (this.screenTimer >= 0) { clearInterval(this.screenTimer); }
    this.updateScreen();
    this.screenTimer = setInterval(() => this.updateScreen(), 1000);
  }

  onBackground(): void {
    this.foreground = false;
    if (this.screenTimer >= 0) { clearInterval(this.screenTimer); this.screenTimer = -1; }
    this.updateScreen();
    WirelessControlService.setForeground(false);
  }

  onDestroy(): void {
    this.foreground = false;
    if (this.screenTimer >= 0) { clearInterval(this.screenTimer); this.screenTimer = -1; }
    this.updateScreen();
    WirelessControlService.setForeground(false);
    WirelessControlService.stop('通话桥已关闭，会话已停止。');
    HspAssistService.stop('通话桥已关闭，会话已停止。');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.screenDesired = undefined;
      this.updateScreen();
    } catch (error) { this.screenError = `${(error as BusinessError).code}`; }
    try {
      windowStage.loadContent('pages/Index', (error: BusinessError) => {
        if (error.code) { console.error(`PhoneBridge page load failed: ${error.code}`); }
      });
    } catch (error) {
      const failure = error as BusinessError;
      console.error(`PhoneBridge page load failed: ${failure.code}`);
    }
  }

  onWindowStageDestroy(): void {
    this.onBackground();
    this.mainWindow = undefined;
    this.screenDesired = undefined;
    this.screenApplied = false;
  }
}
