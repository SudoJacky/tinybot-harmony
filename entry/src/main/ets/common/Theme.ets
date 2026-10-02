import { t, getLocale } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { curves, window } from '@kit.ArkUI';
// Shared design tokens and control styles for the phone UI. Colors live in resources (light/dark).

// Motion tokens mirrored from the desktop workbench so both clients move alike. The system
// "animation scale" setting (including turning animations off) applies to every curve below.
export class Motion {
  static readonly fast: number = 160;
  static readonly medium: number = 220;
  static readonly drawer: number = 280;
  // Settles quickly without overshoot; the default for state changes.
  static readonly standard: ICurve = curves.cubicBezierCurve(0.2, 0, 0, 1);
  // Sheet-like panels that follow a finger.
  static readonly drawerCurve: ICurve = curves.cubicBezierCurve(0.32, 0.72, 0, 1);
  // Content entering the screen: fast start, long soft landing.
  static readonly enter: ICurve = curves.cubicBezierCurve(0.16, 1, 0.3, 1);
  // Sliding selection thumbs (desktop uses a framer spring with the same parameters).
  static readonly thumb: ICurve = curves.interpolatingSpring(0, 0.9, 170, 21.5);
  // Press feedback: the desktop scales pressed controls to 0.97.
  static readonly press: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.97 };
  static readonly pressSmall: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.92 };

  // Fade up into place; index staggers siblings 40 ms apart (desktop list-enter).
  static rise(index: number = 0, distance: number = 8): TransitionEffect {
    return TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: distance }))
      .animation({ duration: Motion.medium, curve: Motion.enter, delay: index * 40 });
  }

  // Pops in from a slightly smaller size, for floating controls.
  static pop(): TransitionEffect {
    return TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
      .animation({ duration: Motion.fast, curve: Motion.standard });
  }
}

export class Space {
  static readonly xs: number = 4;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 24;
  static readonly page: number = 16;
}

export class Radius {
  static readonly sm: number = 10;
  static readonly md: number = 14;
  static readonly lg: number = 18;
  static readonly xl: number = 24;
}

export class Font {
  static readonly caption: number = 12;
  static readonly small: number = 14;
  static readonly body: number = 16;
  static readonly title: number = 17;
  static readonly headline: number = 24;
}

export type ButtonKind = 'primary' | 'tonal' | 'text' | 'danger' | 'plain';

export class AppButton implements AttributeModifier<ButtonAttribute> {
  private kind: ButtonKind;
  private size: number;

  constructor(kind: ButtonKind, size: number) {
    this.kind = kind;
    this.size = size;
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    const large = this.size >= 44;
    instance.type(ButtonType.Capsule).height(this.size).fontSize(large ? 15 : 13).fontWeight(FontWeight.Medium)
      .padding({ left: large ? 20 : 14, right: large ? 20 : 14 });
    if (this.kind === 'primary') {
      instance.backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'));
    } else if (this.kind === 'tonal') {
      instance.backgroundColor($r('app.color.accent_container')).fontColor($r('app.color.on_accent_container'));
    } else if (this.kind === 'danger') {
      instance.backgroundColor($r('app.color.danger_container')).fontColor($r('app.color.danger'));
    } else if (this.kind === 'plain') {
      instance.backgroundColor($r('app.color.surface_variant')).fontColor($r('app.color.text_primary'));
    } else {
      instance.backgroundColor(Color.Transparent).fontColor($r('app.color.accent'));
    }
  }
}

export class Btn {
  static readonly primary: AppButton = new AppButton('primary', 48);
  static readonly primarySmall: AppButton = new AppButton('primary', 32);
  static readonly tonal: AppButton = new AppButton('tonal', 44);
  static readonly tonalSmall: AppButton = new AppButton('tonal', 32);
  static readonly text: AppButton = new AppButton('text', 40);
  static readonly textSmall: AppButton = new AppButton('text', 32);
  static readonly danger: AppButton = new AppButton('danger', 44);
  static readonly plainSmall: AppButton = new AppButton('plain', 32);
}

export class InputStyle implements AttributeModifier<TextInputAttribute> {
  applyNormalAttribute(instance: TextInputAttribute): void {
    instance.height(48).fontSize(15).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
      .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary'));
  }
}

export class AreaStyle implements AttributeModifier<TextAreaAttribute> {
  applyNormalAttribute(instance: TextAreaAttribute): void {
    instance.fontSize(14).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
      .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary'));
  }
}

export class Styles {
  static readonly input: InputStyle = new InputStyle();
  static readonly area: AreaStyle = new AreaStyle();
}

const PROTOCOL_NAMES: Record<string, string> = {
  'chat-completions': 'Chat Completions',
  'responses': 'OpenAI Responses',
  'anthropic-messages': 'Anthropic Messages'
};

export function protocolName(protocol: string): string {
  return PROTOCOL_NAMES[protocol] || protocol;
}

function startOfDay(time: number): number {
  const date = new Date(time);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

const DAY: number = 24 * 60 * 60 * 1000;

function pad(value: number): string {
  return value < 10 ? '0' + value : value.toString();
}

// Compact timestamp for list rows: 14:05 / 昨天 / 9月3日 / 2025/9/3.
export function shortTime(time: number, now: number = Date.now()): string {
  const date = new Date(time);
  const today = startOfDay(now);
  if (time >= today) { return pad(date.getHours()) + ':' + pad(date.getMinutes()); }
  if (time >= today - DAY) { return t("昨天"); }
  if (date.getFullYear() === new Date(now).getFullYear()) {
    return getLocale() === 'zh-CN' ? t('{0}月{1}日', [date.getMonth() + 1, date.getDate()]) :
      date.toLocaleDateString('en', { month: 'short', day: 'numeric' });
  }
  return date.getFullYear() + '/' + (date.getMonth() + 1) + '/' + date.getDate();
}

export function dayGroup(time: number, now: number = Date.now()): string {
  const today = startOfDay(now);
  if (time >= today) { return t("今天"); }
  if (time >= today - DAY) { return t("昨天"); }
  if (time >= today - 7 * DAY) { return t("7 天内"); }
  if (time >= today - 30 * DAY) { return t("30 天内"); }
  return t("更早");
}

export function fileSize(bytes: number): string {
  if (bytes < 1024) { return bytes + ' B'; }
  if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0) + ' KB'; }
  return (bytes / 1024 / 1024).toFixed(1) + ' MB';
}

// Token counts and other large integers: 980 / 12.4K / 3.1M.
export function compactNumber(value: number): string {
  if (value < 1000) { return Math.round(value).toString(); }
  if (value < 1000000) { return (value / 1000).toFixed(value < 10000 ? 1 : 0) + 'K'; }
  return (value / 1000000).toFixed(1) + 'M';
}

// Full-screen modals (bindContentCover) are laid out edge to edge; read the system bar insets in vp.
export async function systemInsets(ui: UIContext): Promise<number[]> {
  try {
    const host = await window.getLastWindow(ui.getHostContext() as common.UIAbilityContext);
    const area = host.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const indicator = host.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    return [ui.px2vp(area.topRect.height), ui.px2vp(indicator.bottomRect.height)];
  } catch (_) {
    return [36, 24];
  }
}
