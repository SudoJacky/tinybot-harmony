import { Diagnostics } from '../model/Diagnostics';
import { uiMaterial } from '@kit.ArkUI';
import { LightEffect } from '../model/Appearance';
import { ApiLevel } from './ApiLevel';

// Immersive material is the only API-26 surface feature this app uses, so every eval of the
// uiMaterial namespace is confined to this file. On systems without the native module
// (@ohos.arkui.uiMaterial is missing below API 26), or on devices that report no immersive
// support, getters resolve to undefined and retain plain/native default rendering. Supported
// devices use Material.empty when effects are switched off; undefined restores default material.
export class AppMaterials {
  private static selectedStyle?: uiMaterial.ImmersiveStyle;
  private static controlMaterial?: uiMaterial.Material;
  private static accentControlMaterial?: uiMaterial.Material;
  private static effect: LightEffect = 'auto';
  private static accent: ResourceColor = $r('app.color.accent_material');
  // API availability does not imply device support. Unsupported API-26 devices
  // accept ImmersiveMaterial but do not render it, leaving overlay content exposed.
  // A subsequent construction failure also disables material for the session.
  private static supported?: boolean;
  private static unavailable: boolean = false;

  // True when immersive material can actually be applied on this system.
  static get available(): boolean {
    // Native support is not ready during module evaluation, before the UI context exists.
    // Resolve it at first rendering use instead of caching a transient false for the process.
    if (AppMaterials.supported === undefined) {
      AppMaterials.supported = ApiLevel.material && uiMaterial.isImmersiveMaterialSupported();
    }
    return AppMaterials.supported && !AppMaterials.unavailable;
  }

  // Called from settings after startup, when the native diagnostic sink is installed.
  // Compare with the first rendering result without changing the rendering decision.
  static reportSupport(): void {
    const available = AppMaterials.available;
    const supported = ApiLevel.material && uiMaterial.isImmersiveMaterialSupported();
    const failed = AppMaterials.supported && AppMaterials.unavailable;
    const reason = !ApiLevel.material ? 'api_level' : supported !== AppMaterials.supported ? 'capability_changed' :
      failed ? 'construction_failed' : !supported ? 'device_unsupported' : 'supported';
    Diagnostics.log(available && reason === 'supported' ? 'info' : 'warn', 'appearance', 'material_support', {
      sdk: ApiLevel.sdk, initialSupported: AppMaterials.supported, supported: supported,
      available: available, failed: failed, reason: reason
    });
  }

  // Explicitly opt out of native immersive effects while keeping older systems supported.
  static get enabled(): boolean { return AppMaterials.available && AppMaterials.effect !== 'off'; }

  static get empty(): uiMaterial.Material | undefined {
    return AppMaterials.available ? uiMaterial.Material.empty : undefined;
  }

  static configure(effect: LightEffect, accent: ResourceColor): void {
    if (AppMaterials.effect === effect && AppMaterials.accent === accent) { return; }
    AppMaterials.effect = effect;
    AppMaterials.accent = accent;
    AppMaterials.controlMaterial = undefined;
    AppMaterials.accentControlMaterial = undefined;
  }

  private static get style(): uiMaterial.ImmersiveStyle | undefined {
    if (AppMaterials.effect === 'gentle') { return uiMaterial.ImmersiveStyle.THICK; }
    if (AppMaterials.effect === 'standard') { return uiMaterial.ImmersiveStyle.THIN; }
    if (AppMaterials.effect === 'vivid') { return uiMaterial.ImmersiveStyle.ULTRA_THIN; }
    if (AppMaterials.selectedStyle === undefined) {
      const level = uiMaterial.getGlobalMaterialLevel();
      switch (level) {
        case uiMaterial.MaterialLevel.EXQUISITE:
          AppMaterials.selectedStyle = uiMaterial.ImmersiveStyle.ULTRA_THIN;
          break;
        case uiMaterial.MaterialLevel.GENTLE:
          AppMaterials.selectedStyle = uiMaterial.ImmersiveStyle.THIN;
          break;
        case uiMaterial.MaterialLevel.SMOOTH:
          AppMaterials.selectedStyle = uiMaterial.ImmersiveStyle.THICK;
          break;
        default:
          throw new Error('Unsupported material level: ' + level);
      }
      if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'appearance', 'material', { level: level, style: AppMaterials.selectedStyle }); };
    }
    return AppMaterials.selectedStyle;
  }

  // One construction path: a constructor failure on a partially updated system disables the
  // feature for the rest of the session instead of repeating the same crash on every surface.
  private static build(candidate: () => uiMaterial.Material | undefined): uiMaterial.Material | undefined {
    if (AppMaterials.unavailable) { return undefined; }
    try { return candidate(); } catch (error) {
      AppMaterials.unavailable = true;
      AppMaterials.controlMaterial = undefined;
      AppMaterials.accentControlMaterial = undefined;
      Diagnostics.log('error', 'appearance', 'material_unavailable', { code: ApiLevel.sdk }, error as Error);
      return undefined;
    }
  }

  // Navigation, native Select/Slider/Toggle controls, and onboarding action/choice buttons.
  static get control(): uiMaterial.Material | undefined {
    if (!AppMaterials.available) { return undefined; }
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.controlMaterial) {
      AppMaterials.controlMaterial = AppMaterials.build(() => new uiMaterial.ImmersiveMaterial({
        // Shadows overlap and clip at title-bar edges, creating an unwanted gray strip.
        style: AppMaterials.style, applyShadow: false, colorInvert: true,
        interactive: AppMaterials.effect !== 'gentle', lightEffect: AppMaterials.lightEffect()
      }));
    }
    return AppMaterials.controlMaterial;
  }

  static get accentControl(): uiMaterial.Material | undefined {
    if (!AppMaterials.available) { return undefined; }
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.accentControlMaterial) {
      AppMaterials.accentControlMaterial = AppMaterials.build(() => new uiMaterial.ImmersiveMaterial({
        style: AppMaterials.style, materialColor: AppMaterials.accent, applyShadow: false,
        interactive: AppMaterials.effect !== 'gentle', lightEffect: AppMaterials.lightEffect()
      }));
    }
    return AppMaterials.accentControlMaterial;
  }

  // Overlay text must stay legible: native immersive material exposes sharp backdrop text on MatePad.
  // Use the native empty material with the component's opaque themed background in every effect mode.
  static get surface(): uiMaterial.Material | undefined {
    return AppMaterials.empty;
  }

  // Native menus and Select popups use the same solid surface as custom pickers.
  static get menu(): uiMaterial.Material | undefined {
    return AppMaterials.empty;
  }

  // Reading sheets share the solid overlay policy.
  static get readingSurface(): uiMaterial.Material | undefined {
    return AppMaterials.empty;
  }

  private static lightEffect(): uiMaterial.LightEffectOptions {
    return { color: AppMaterials.effect === 'gentle' ? '#40FFFFFF' :
      AppMaterials.effect === 'standard' ? '#99FFFFFF' : '#FFFFFFFF' };
  }
}
