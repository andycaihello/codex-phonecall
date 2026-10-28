import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// The only persisted user setting is the explicitly selected paired peer.
// Permission, session timers, telephone numbers and credentials are never saved.
export class CompanionSettings {
  private static readonly storeName: string = 'phonebridge_user';
  private static readonly peerKey: string = 'selectedPeer';

  static validPeer(value: string): boolean {
    return /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(value);
  }

  static selectedPeer(context: common.UIAbilityContext): string {
    try {
    const store = preferences.getPreferencesSync(context, { name: CompanionSettings.storeName });
    const value = store.getSync(CompanionSettings.peerKey, '');
    if (typeof value !== 'string' || !CompanionSettings.validPeer(value)) { return ''; }
    return value.toUpperCase();
    } catch (error) { throw new Error('无法读取所选设备。'); }
  }

  static async selectPeer(context: common.UIAbilityContext, value: string): Promise<void> {
    if (!CompanionSettings.validPeer(value)) { throw new Error('所选设备地址不可用。'); }
    try {
    const store = preferences.getPreferencesSync(context, { name: CompanionSettings.storeName });
    store.putSync(CompanionSettings.peerKey, value.toUpperCase());
    await store.flush();
    } catch (error) { throw new Error('无法保存所选设备。'); }
  }
}
