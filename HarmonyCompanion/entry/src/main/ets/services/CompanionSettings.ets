import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// Persist the selected peer and whether the owner wants the companion to
// resume its listener when the app is opened. Never persist call authority.
export class CompanionSettings {
  private static readonly storeName: string = 'phonebridge_user';
  private static readonly peerKey: string = 'selectedPeer';
  private static readonly autoReadyKey: string = 'autoReady';

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
    store.putSync(CompanionSettings.autoReadyKey, true);
    await store.flush();
    } catch (error) { throw new Error('无法保存所选设备。'); }
  }

  static autoReady(context: common.UIAbilityContext): boolean {
    const store = preferences.getPreferencesSync(context, { name: CompanionSettings.storeName });
    // Existing installations selected a trusted peer before this preference
    // existed; they are eligible for automatic listener preparation on open.
    return store.getSync(CompanionSettings.autoReadyKey, true) === true;
  }

  static async setAutoReady(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    const store = preferences.getPreferencesSync(context, { name: CompanionSettings.storeName });
    store.putSync(CompanionSettings.autoReadyKey, enabled);
    await store.flush();
  }
}
