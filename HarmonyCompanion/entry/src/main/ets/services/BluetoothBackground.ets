import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';

// Only an explicitly started bridge with a verified, connected Mac may acquire
// this task. The system notification lets the owner return to the bridge.
export class BluetoothBackground {
  private static generation: number = 0;
  private static pending: boolean = false;
  private static running: boolean = false;
  private static stopping: boolean = false;
  private static reconnectTimer: number = -1;
  private static context: common.UIAbilityContext | undefined = undefined;
  static error: string = '';

  static isActive(): boolean { return BluetoothBackground.running && !BluetoothBackground.stopping; }
  static async start(context: common.UIAbilityContext): Promise<boolean> {
    BluetoothBackground.cancelReconnectStop();
    if (BluetoothBackground.pending || BluetoothBackground.stopping) { return false; }
    if (BluetoothBackground.running) { return true; }
    const generation = ++BluetoothBackground.generation;
    BluetoothBackground.pending = true;
    BluetoothBackground.error = '';
    BluetoothBackground.context = context;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'cn.andy.phonebridge.companion', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      if (generation !== BluetoothBackground.generation) { return false; }
      await backgroundTaskManager.startBackgroundRunning(context, ['bluetoothInteraction'], agent);
      BluetoothBackground.running = true;
      if (generation !== BluetoothBackground.generation) {
        BluetoothBackground.stop();
        return false;
      }
      return true;
    } catch (error) {
      BluetoothBackground.error = `background-start-${(error as BusinessError).code || 0}`;
      return false;
    } finally {
      BluetoothBackground.pending = false;
    }
  }
  // Keep a previously acquired task only for a bounded reconnect window.
  // This does not acquire a new task while disconnected or fake Bluetooth work.
  static retainForReconnect(): void {
    BluetoothBackground.cancelReconnectStop();
    if (!BluetoothBackground.running || BluetoothBackground.stopping) { return; }
    const generation = BluetoothBackground.generation;
    BluetoothBackground.reconnectTimer = setTimeout(() => {
      BluetoothBackground.reconnectTimer = -1;
      if (generation === BluetoothBackground.generation) { BluetoothBackground.stop(); }
    }, 45000);
  }
  private static cancelReconnectStop(): void {
    if (BluetoothBackground.reconnectTimer >= 0) { clearTimeout(BluetoothBackground.reconnectTimer); }
    BluetoothBackground.reconnectTimer = -1;
  }
  static stop(): void {
    BluetoothBackground.cancelReconnectStop();
    ++BluetoothBackground.generation;
    if (!BluetoothBackground.running || BluetoothBackground.stopping || !BluetoothBackground.context) { return; }
    BluetoothBackground.stopping = true;
    backgroundTaskManager.stopBackgroundRunning(BluetoothBackground.context).then(() => {
      BluetoothBackground.running = false;
      BluetoothBackground.context = undefined;
      BluetoothBackground.stopping = false;
    }).catch((error: BusinessError) => {
      // Retain ownership on failure so an explicit Stop can retry release.
      BluetoothBackground.error = `background-stop-${error.code || 0}`;
      BluetoothBackground.stopping = false;
    });
  }
  static dump(): string {
    return `background=${BluetoothBackground.isActive()}; backgroundPending=${BluetoothBackground.pending}; reconnectGrace=${BluetoothBackground.reconnectTimer >= 0}; backgroundError=${BluetoothBackground.error}`;
  }
}
