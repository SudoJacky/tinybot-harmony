import { Diagnostics } from '../model/Diagnostics';
import { uiMaterial } from '@kit.ArkUI';
import { LightEffect } from '../model/Appearance';
import { ApiLevel } from './ApiLevel';

// Immersive material is the only API-26 surface feature this app uses, so every eval of the
// uiMaterial namespace is confined to this file. On systems without the native module
// (@ohos.arkui.uiMaterial is missing below API 26) each getter resolves to undefined and the
// caller keeps its plain color, border and shadow settings. API 26 still uses Material.empty
// when the user switches effects off; undefined would restore the component's default material.
export class AppMaterials {
  private static selectedStyle?: uiMaterial.ImmersiveStyle;
  private static controlMaterial?: uiMaterial.Material;
  private static accentControlMaterial?: uiMaterial.Material;
  private static surfaceMaterial?: uiMaterial.Material;
  private static menuMaterial?: uiMaterial.Material;
  private static readingSurfaceMaterial?: uiMaterial.Material;
  private static effect: LightEffect = 'auto';
  private static accent: ResourceColor = $r('app.color.accent_material');
  // Set when the material module is reported present but its constructor still fails, so a
  // half-updated system degrades to the plain interface instead of crashing every surface.
  private static unavailable: boolean = !ApiLevel.material;

  // True when immersive material can actually be applied on this system.
  static get available(): boolean { return !AppMaterials.unavailable; }

  // Explicitly opt out of native immersive effects while keeping older systems supported.
  static get empty(): uiMaterial.Material | undefined {
    return AppMaterials.available ? uiMaterial.Material.empty : undefined;
  }

  static configure(effect: LightEffect, accent: ResourceColor): void {
    if (AppMaterials.effect === effect && AppMaterials.accent === accent) { return; }
    AppMaterials.effect = effect;
    AppMaterials.accent = accent;
    AppMaterials.controlMaterial = undefined;
    AppMaterials.accentControlMaterial = undefined;
    AppMaterials.surfaceMaterial = undefined;
    AppMaterials.menuMaterial = undefined;
    AppMaterials.readingSurfaceMaterial = undefined;
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
      AppMaterials.surfaceMaterial = undefined;
      AppMaterials.menuMaterial = undefined;
      AppMaterials.readingSurfaceMaterial = undefined;
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

  // General overlays use the next gentler app tier; adaptive menus use the separate menu material.
  static get surface(): uiMaterial.Material | undefined {
    if (!AppMaterials.available) { return undefined; }
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.surfaceMaterial) {
      const selected = AppMaterials.style;
      AppMaterials.surfaceMaterial = AppMaterials.build(() => new uiMaterial.ImmersiveMaterial({
        style: selected === uiMaterial.ImmersiveStyle.ULTRA_THIN ? uiMaterial.ImmersiveStyle.THIN : uiMaterial.ImmersiveStyle.THICK,
        colorInvert: true
      }));
    }
    return AppMaterials.surfaceMaterial;
  }

  // Backdrop-driven foreground inversion only works with THIN or ULTRA_THIN material.
  static get menu(): uiMaterial.Material | undefined {
    if (!AppMaterials.available) { return undefined; }
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.menuMaterial) {
      AppMaterials.menuMaterial = AppMaterials.build(() => new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN, colorInvert: true
      }));
    }
    return AppMaterials.menuMaterial;
  }

  // Long sheets need a denser, tinted backing so underlying text cannot compete with their content.
  static get readingSurface(): uiMaterial.Material | undefined {
    if (!AppMaterials.available) { return undefined; }
    if (AppMaterials.effect === 'off') { return uiMaterial.Material.empty; }
    if (!AppMaterials.readingSurfaceMaterial) {
      AppMaterials.readingSurfaceMaterial = AppMaterials.build(() => new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THICK, materialColor: $r('app.color.reading_surface_tint'), colorInvert: false
      }));
    }
    return AppMaterials.readingSurfaceMaterial;
  }

  private static lightEffect(): uiMaterial.LightEffectOptions {
    return { color: AppMaterials.effect === 'gentle' ? '#40FFFFFF' :
      AppMaterials.effect === 'standard' ? '#99FFFFFF' : '#FFFFFFFF' };
  }
}
