import { uiMaterial } from '@kit.ArkUI';
import { AppearanceOptions, accentAlpha, accentPalette } from '../model/Appearance';
import { AppMaterials } from './AppMaterials';

// Every component observes the same replacement value. Appearance changes never remount the page.
// Material getters are undefined when the system has no immersive material module (API 20);
// controls use an opaque theme color when their material cannot supply a visible shape.
@Observed
export class AppearanceStyle {
  accent: ResourceColor = $r('app.color.accent');
  onAccent: ResourceColor = $r('app.color.on_accent');
  accentContainer: ResourceColor = $r('app.color.accent_container');
  onAccentContainer: ResourceColor = $r('app.color.on_accent_container');
  userBubble: ResourceColor = $r('app.color.user_bubble');
  accentTint: ResourceColor = $r('app.color.accent_tint');
  accentGlow: ResourceColor = $r('app.color.accent_glow');
  accentOutline: ResourceColor = $r('app.color.accent_outline');
  fontFamily: string = '';
  effectStrength: number = 1;
  get control(): uiMaterial.Material | undefined { return AppMaterials.control; }
  get noMaterial(): uiMaterial.Material | undefined { return AppMaterials.empty; }
  get accentControl(): uiMaterial.Material | undefined { return AppMaterials.accentControl; }
  get surface(): uiMaterial.Material | undefined { return AppMaterials.surface; }
  get menu(): uiMaterial.Material | undefined { return AppMaterials.menu; }
  get readingSurface(): uiMaterial.Material | undefined { return AppMaterials.readingSurface; }
  // Whether the light-sense material is really applied, so settings can show its true state.
  get materialAvailable(): boolean { return AppMaterials.available; }
  get controlBackground(): ResourceColor {
    return this.materialAvailable ? Color.Transparent : $r('app.color.surface_variant');
  }
}

export function makeAppearanceStyle(options: AppearanceOptions, dark: boolean): AppearanceStyle {
  const palette = accentPalette(options.accent, dark, options.customColor);
  const style = new AppearanceStyle();
  style.accent = palette.accent;
  style.onAccent = palette.onAccent;
  style.accentContainer = palette.container;
  style.onAccentContainer = palette.onContainer;
  style.userBubble = palette.bubble;
  style.accentTint = accentAlpha(palette.accent, '24');
  style.accentGlow = accentAlpha(palette.accent, '2E');
  style.accentOutline = accentAlpha(palette.accent, '66');
  style.fontFamily = options.fontFamily;
  style.effectStrength = options.lightEffect === 'off' ? 0 : options.lightEffect === 'gentle' ? 0.35 :
    options.lightEffect === 'standard' ? 0.65 : 1;
  AppMaterials.configure(options.lightEffect, accentAlpha(palette.accent, 'E6'));
  return style;
}

export function currentAppearanceStyle(): AppearanceStyle {
  const style = AppStorage.get<AppearanceStyle>('tinybot.appearance.style');
  if (!style) { throw new Error('Appearance has not been initialized.'); }
  return style;
}
