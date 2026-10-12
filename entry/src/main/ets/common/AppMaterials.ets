import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

// Read the device once, when the first native component requests its material.
export class AppMaterials {
  private static selectedStyle?: uiMaterial.ImmersiveStyle;
  private static controlMaterial?: uiMaterial.Material;
  private static accentControlMaterial?: uiMaterial.Material;
  private static surfaceMaterial?: uiMaterial.Material;

  static get style(): uiMaterial.ImmersiveStyle {
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
      hilog.info(0x0000, 'TinybotMaterial', 'Device material level=%{public}d style=%{public}d',
        level, AppMaterials.selectedStyle);
    }
    return AppMaterials.selectedStyle;
  }

  // Navigation buttons and native Select/Slider/Toggle controls. Other content-area buttons are out of scope.
  static get control(): uiMaterial.Material {
    if (!AppMaterials.controlMaterial) {
      AppMaterials.controlMaterial = new uiMaterial.ImmersiveMaterial({
        // Shadows overlap and clip at title-bar edges, creating an unwanted gray strip.
        style: AppMaterials.style, applyShadow: false, colorInvert: true, interactive: true, lightEffect: {}
      });
    }
    return AppMaterials.controlMaterial;
  }

  static get accentControl(): uiMaterial.Material {
    if (!AppMaterials.accentControlMaterial) {
      AppMaterials.accentControlMaterial = new uiMaterial.ImmersiveMaterial({
        style: AppMaterials.style, materialColor: $r('app.color.accent_material'), applyShadow: false,
        interactive: true, lightEffect: {}
      });
    }
    return AppMaterials.accentControlMaterial;
  }

  // Menus, popups, small dialogs/sheets and toasts; large reading/editing surfaces retain solid backgrounds.
  static get surface(): uiMaterial.Material {
    if (!AppMaterials.surfaceMaterial) {
      AppMaterials.surfaceMaterial = new uiMaterial.ImmersiveMaterial({ style: AppMaterials.style, colorInvert: true });
    }
    return AppMaterials.surfaceMaterial;
  }
}
