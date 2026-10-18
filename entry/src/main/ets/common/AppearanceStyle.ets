import { uiMaterial } from '@kit.ArkUI';
import { AppearanceOptions, accentAlpha, accentPalette } from '../model/Appearance';
import { AppMaterials } from './AppMaterials';

// Every component observes the same replacement value. Appearance changes never remount the page.
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
  get control(): uiMaterial.Material { return AppMaterials.control; }
  get accentControl(): uiMaterial.Material { return AppMaterials.accentControl; }
  get surface(): uiMaterial.Material { return AppMaterials.surface; }
  get readingSurface(): uiMaterial.Material { return AppMaterials.readingSurface; }
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
