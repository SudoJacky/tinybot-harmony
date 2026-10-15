import { Diagnostics } from '../model/Diagnostics';
import { uiMaterial } from '@kit.ArkUI';
import { LightEffect } from '../model/Appearance';

// Read the device once, when the first native component requests its material.
export class AppMaterials {
  private static selectedStyle?: uiMaterial.ImmersiveStyle;
  private static controlMaterial?: uiMaterial.Material;
  private static accentControlMaterial?: uiMaterial.Material;
  private static surfaceMaterial?: uiMaterial.Material;
  private static effect: LightEffect = 'auto';
  private static accent: ResourceColor = $r('app.color.accent_material');

  static configure(effect: LightEffect, accent: ResourceColor): void {
    if (AppMaterials.effect === effect && AppMaterials.accent === accent) { return; }
    AppMaterials.effect = effect;
    AppMaterials.accent = accent;
    AppMaterials.controlMaterial = undefined;
    AppMaterials.accentControlMaterial = undefined;
    AppMaterials.surfaceMaterial = undefined;
  }

  static get style(): uiMaterial.ImmersiveStyle {
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

  // Navigation buttons and native Select/Slider/Toggle controls. Other content-area buttons are out of scope.
  static get control(): uiMaterial.Material {
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.controlMaterial) {
      AppMaterials.controlMaterial = new uiMaterial.ImmersiveMaterial({
        // Shadows overlap and clip at title-bar edges, creating an unwanted gray strip.
        style: AppMaterials.style, applyShadow: false, colorInvert: true,
        interactive: AppMaterials.effect !== 'gentle', lightEffect: AppMaterials.lightEffect()
      });
    }
    return AppMaterials.controlMaterial;
  }

  static get accentControl(): uiMaterial.Material {
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.accentControlMaterial) {
      AppMaterials.accentControlMaterial = new uiMaterial.ImmersiveMaterial({
        style: AppMaterials.style, materialColor: AppMaterials.accent, applyShadow: false,
        interactive: AppMaterials.effect !== 'gentle', lightEffect: AppMaterials.lightEffect()
      });
    }
    return AppMaterials.accentControlMaterial;
  }

  // Menus, popups, small dialogs/sheets and toasts; large reading/editing surfaces retain solid backgrounds.
  static get surface(): uiMaterial.Material {
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.surfaceMaterial) {
      AppMaterials.surfaceMaterial = new uiMaterial.ImmersiveMaterial({ style: AppMaterials.style, colorInvert: true });
    }
    return AppMaterials.surfaceMaterial;
  }

  private static lightEffect(): uiMaterial.LightEffectOptions {
    return { color: AppMaterials.effect === 'gentle' ? '#40FFFFFF' :
      AppMaterials.effect === 'standard' ? '#99FFFFFF' : '#FFFFFFFF' };
  }
}
