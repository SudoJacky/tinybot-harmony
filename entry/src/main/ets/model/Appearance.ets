export type AppearanceMode = 'system' | 'light' | 'dark';
export type AccentName = 'green' | 'blue' | 'purple' | 'amber' | 'rose' | 'custom';
export type LightEffect = 'auto' | 'off' | 'gentle' | 'standard' | 'vivid';

export interface AppearanceOptions {
  mode: AppearanceMode;
  accent: AccentName;
  fontScale: number;
  fontFamily: string;
  lightEffect: LightEffect;
  customColor: string;
}

export const APPEARANCE_MODES: AppearanceMode[] = ['system', 'light', 'dark'];
export const ACCENT_NAMES: AccentName[] = ['green', 'blue', 'purple', 'amber', 'rose', 'custom'];
export const FONT_SCALES: number[] = [0.9, 1, 1.15, 1.3];
export const LIGHT_EFFECTS: LightEffect[] = ['auto', 'off', 'gentle', 'standard', 'vivid'];

export function defaultAppearance(): AppearanceOptions {
  return { mode: 'system', accent: 'green', fontScale: 1, fontFamily: '', lightEffect: 'auto', customColor: '#216451' };
}

export function validateAppearance(value: AppearanceOptions): void {
  if (!value || !APPEARANCE_MODES.includes(value.mode) || !ACCENT_NAMES.includes(value.accent) ||
    !FONT_SCALES.includes(value.fontScale) || typeof value.fontFamily !== 'string' || value.fontFamily.length > 128 ||
    !LIGHT_EFFECTS.includes(value.lightEffect) || !/^#[0-9A-Fa-f]{6}$/.test(value.customColor)) {
    throw new Error('Invalid appearance preferences.');
  }
}

export function copyAppearance(value: AppearanceOptions): AppearanceOptions {
  return { mode: value.mode, accent: value.accent, fontScale: value.fontScale, fontFamily: value.fontFamily,
    lightEffect: value.lightEffect, customColor: value.customColor };
}

export class AccentPalette {
  accent: string;
  onAccent: string;
  container: string;
  onContainer: string;
  bubble: string;

  constructor(accent: string, onAccent: string, container: string, onContainer: string, bubble: string) {
    this.accent = accent; this.onAccent = onAccent; this.container = container; this.onContainer = onContainer; this.bubble = bubble;
  }
}

// Same preset order as ACCENT_NAMES; custom palettes are generated separately.
const LIGHT_PALETTES: AccentPalette[] = [
  new AccentPalette('#216451', '#FFFFFF', '#D9ECE1', '#10392C', '#D9ECE1'),
  new AccentPalette('#245D9C', '#FFFFFF', '#DCEAFF', '#102F54', '#DCEAFF'),
  new AccentPalette('#674396', '#FFFFFF', '#EDDEFF', '#352049', '#EDDEFF'),
  new AccentPalette('#855100', '#FFFFFF', '#FFE7C5', '#432900', '#FFE7C5'),
  new AccentPalette('#97445C', '#FFFFFF', '#FADDE6', '#542333', '#FADDE6')
];
const DARK_PALETTES: AccentPalette[] = [
  new AccentPalette('#A2D8B9', '#143528', '#244A3A', '#CDEBD9', '#2A4638'),
  new AccentPalette('#AACDFF', '#102F54', '#243E5C', '#D5E7FF', '#243E5C'),
  new AccentPalette('#D7B7FF', '#352049', '#423052', '#F0DFFF', '#423052'),
  new AccentPalette('#F4C482', '#432900', '#4B371F', '#FFE8C6', '#4B371F'),
  new AccentPalette('#FFB4C8', '#542333', '#542D3C', '#FFDFE8', '#542D3C')
];

export function accentPalette(name: AccentName, dark: boolean, customColor: string = '#216451'): AccentPalette {
  if (name === 'custom') { return customPalette(customColor, dark); }
  const value = (dark ? DARK_PALETTES : LIGHT_PALETTES)[ACCENT_NAMES.indexOf(name)];
  if (!value) { throw new Error('Unknown accent palette: ' + name); }
  return value;
}

function channels(color: string): number[] {
  if (!/^#[0-9A-Fa-f]{6}$/.test(color)) { throw new Error('Invalid custom color: ' + color); }
  return [1, 3, 5].map((offset: number) => parseInt(color.slice(offset, offset + 2), 16));
}

export function rgbColor(red: number, green: number, blue: number): string {
  return '#' + [red, green, blue].map((value: number) => Math.round(value).toString(16).padStart(2, '0')).join('').toUpperCase();
}

export interface HsvColor {
  hue: number;
  saturation: number;
  value: number;
}

export function colorHsv(color: string, previousHue: number = 0): HsvColor {
  const rgb = channels(color).map((channel: number) => channel / 255);
  const high = Math.max(rgb[0], rgb[1], rgb[2]), low = Math.min(rgb[0], rgb[1], rgb[2]), delta = high - low;
  let hue = previousHue;
  if (delta > 0) {
    hue = high === rgb[0] ? (rgb[1] - rgb[2]) / delta :
      high === rgb[1] ? (rgb[2] - rgb[0]) / delta + 2 : (rgb[0] - rgb[1]) / delta + 4;
    hue = (hue * 60 + 360) % 360;
  }
  return { hue, saturation: high === 0 ? 0 : delta / high, value: high };
}

export function hsvColor(hue: number, saturation: number, value: number): string {
  const sector = (hue % 360) / 60, chroma = value * saturation;
  const secondary = chroma * (1 - Math.abs(sector % 2 - 1)), base = value - chroma;
  const rgb: number[] = sector < 1 ? [chroma, secondary, 0] : sector < 2 ? [secondary, chroma, 0] :
    sector < 3 ? [0, chroma, secondary] : sector < 4 ? [0, secondary, chroma] :
    sector < 5 ? [secondary, 0, chroma] : [chroma, 0, secondary];
  return rgbColor((rgb[0] + base) * 255, (rgb[1] + base) * 255, (rgb[2] + base) * 255);
}

function mix(color: string, target: string, amount: number): string {
  const from = channels(color), to = channels(target);
  return rgbColor(from[0] + (to[0] - from[0]) * amount, from[1] + (to[1] - from[1]) * amount,
    from[2] + (to[2] - from[2]) * amount);
}

function luminance(color: string): number {
  const rgb = channels(color).map((value: number) => {
    const channel = value / 255;
    return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
  });
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

export function colorContrast(first: string, second: string): number {
  const a = luminance(first), b = luminance(second);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

function readableForeground(background: string): string {
  return colorContrast(background, '#FFFFFF') >= colorContrast(background, '#000000') ? '#FFFFFF' : '#000000';
}

function customPalette(color: string, dark: boolean): AccentPalette {
  channels(color);
  let accent = dark ? mix(color, '#FFFFFF', 0.55) : color.toUpperCase();
  // Keep light-mode primary buttons readable with white text, even for a pale custom color.
  if (!dark) {
    for (let step = 0; colorContrast(accent, '#FFFFFF') < 4.5 && step < 30; step++) { accent = mix(accent, '#000000', 0.1); }
  }
  const container = dark ? mix(color, '#121A18', 0.72) : mix(color, '#FFFFFF', 0.85);
  return new AccentPalette(accent, readableForeground(accent), container, readableForeground(container), container);
}

export function accentAlpha(color: string, alpha: string): string {
  return '#' + alpha + color.slice(1);
}
