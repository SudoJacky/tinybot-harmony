import { Diagnostics } from '../model/Diagnostics';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { AppearanceOptions, AppearanceMode, AccentName, LightEffect, APPEARANCE_MODES, ACCENT_NAMES,
  FONT_SCALES, LIGHT_EFFECTS, accentPalette, defaultAppearance, copyAppearance, colorHsv, hsvColor } from '../model/Appearance';
import { AppearancePreferences } from '../services/AppearancePreferences';
import { t } from '../model/I18n';
import { Btn, Font, Radius, Space, Styles } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader, Segmented } from '../common/Widgets';
import { text } from '@kit.ArkGraphics2D';

let readingFonts: string[] | undefined;

export function appearanceChoiceTitle(choice: string): string {
  return choice === 'mode' ? t('明暗模式') : choice === 'font' ? t('界面字体') :
    choice === 'custom' ? t('自定义颜色') : t('光感效果');
}

@Component
export struct AppearancePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.options') private options: AppearanceOptions = defaultAppearance();
  @StorageProp('tinybot.appearance.dark') private dark: boolean = false;
  @Prop choice: string = '';
  onChoice: (choice: string) => void = () => {};
  onDone: () => void = () => {};
  @State private error: string = '';
  @State private fonts: string[] = [''];
  @State private customColor: string = '#216451';
  @State private hue: number = 0;
  @State private saturation: number = 0;
  @State private colorValue: number = 0;
  @State private paletteWidth: number = 0;
  @State private fontLoading: boolean = false;
  private mounted: boolean = false;
  private readonly hueGradient: LinearGradient = new LinearGradient([
    { color: '#FF0000', offset: 0 }, { color: '#FFFF00', offset: 1 / 6 },
    { color: '#00FF00', offset: 2 / 6 }, { color: '#00FFFF', offset: 3 / 6 },
    { color: '#0000FF', offset: 4 / 6 }, { color: '#FF00FF', offset: 5 / 6 }, { color: '#FF0000', offset: 1 }
  ]);

  aboutToAppear(): void {
    this.mounted = true;
    if (this.choice === 'custom') { this.updateColor(this.options.customColor); }
    if (this.choice === 'font') { this.loadFonts(); }
  }
  aboutToDisappear(): void { this.mounted = false; }

  private loadFonts(): void {
    if (readingFonts) { this.fonts = readingFonts; return; }
    if (this.fontLoading) { return; }
    this.fontLoading = true;
    text.matchFontDescriptors({}).then((descriptors: text.FontDescriptor[]) => {
      // Keep the list useful for general reading, rather than exposing symbol/script-only fonts.
      const reading: string[] = ['harmonyossans', 'harmonyossanssc', 'notosans', 'notoserif',
        'notosanscjksc', 'notoserifcjksc', 'notosansmono', 'roboto'];
      const families: string[] = [''];
      descriptors.forEach((descriptor: text.FontDescriptor) => {
        const family = descriptor.fontFamily || '';
        if (reading.includes(family.replace(/[ _-]/g, '').toLowerCase()) && !families.includes(family)) { families.push(family); }
      });
      if (this.options.fontFamily && !families.includes(this.options.fontFamily)) { families.push(this.options.fontFamily); }
      readingFonts = families;
      if (this.mounted) { this.fonts = families; this.fontLoading = false; }
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'appearance', 'fonts_loaded', { count: families.length }); };
    }).catch((error: Error) => {
      if (this.mounted) { this.error = t('无法读取设备字体：{0}', [error.message]); this.fontLoading = false; }
      Diagnostics.log('error', 'appearance', 'fonts_failed', undefined, error);
    });
  }

  private modeName(mode: AppearanceMode): string {
    return mode === 'system' ? t('跟随系统') : mode === 'light' ? t('浅色') : t('深色');
  }
  private accentName(name: AccentName): string {
    return name === 'green' ? t('森林绿') : name === 'blue' ? t('湖蓝') : name === 'purple' ? t('鸢尾紫') :
      name === 'amber' ? t('琥珀橙') : name === 'rose' ? t('玫瑰红') : t('自定义颜色');
  }
  private effectName(effect: LightEffect): string {
    return effect === 'auto' ? t('跟随设备') : effect === 'off' ? t('关闭') : effect === 'gentle' ? t('柔和') :
      effect === 'standard' ? t('标准') : t('通透');
  }
  private effectDescription(effect: LightEffect): string {
    return effect === 'auto' ? t('根据设备能力选择材质效果。') : effect === 'off' ? t('使用纯色控件，关闭光感材质。') :
      effect === 'gentle' ? t('更厚的材质，较弱的高光，不启用交互形变。') :
      effect === 'standard' ? t('薄材质，适中的高光与交互反馈。') : t('更通透的材质，完整的高光与交互反馈。');
  }
  private fontName(family: string): string { return family || t('跟随系统'); }
  private scaleNames(): string[] { return [t('小'), t('标准'), t('大'), t('更大')]; }

  private save(next: AppearanceOptions): void {
    try {
      AppearancePreferences.select(next);
      this.error = '';
      if (this.choice) { this.onDone(); }
    } catch (error) { this.error = t('无法保存外观设置：{0}', [(error as Error).message]); }
  }
  private selectMode(mode: AppearanceMode): void { const next = copyAppearance(this.options); next.mode = mode; this.save(next); }
  private selectAccent(accent: AccentName): void { const next = copyAppearance(this.options); next.accent = accent; this.save(next); }
  private selectEffect(lightEffect: LightEffect): void { const next = copyAppearance(this.options); next.lightEffect = lightEffect; this.save(next); }
  private selectFont(fontFamily: string): void { const next = copyAppearance(this.options); next.fontFamily = fontFamily; this.save(next); }
  private selectScale(index: number): void { const next = copyAppearance(this.options); next.fontScale = FONT_SCALES[index]; this.save(next); }
  private applyColor(): void {
    const next = copyAppearance(this.options); next.accent = 'custom'; next.customColor = this.customColor; this.save(next);
  }
  private open(choice: string): void {
    this.onChoice(choice);
  }
  private validColor(): boolean { return /^#[0-9A-Fa-f]{6}$/.test(this.customColor); }
  private updateColor(value: string): void {
    this.customColor = value.toUpperCase();
    if (this.validColor()) {
      const hsv = colorHsv(value, this.hue);
      this.hue = hsv.hue; this.saturation = hsv.saturation; this.colorValue = hsv.value;
    }
  }
  private selectHue(hue: number): void {
    this.hue = hue;
    this.customColor = hsvColor(this.hue, this.saturation, this.colorValue);
  }
  private selectPalette(event: GestureEvent): void {
    const finger = event.fingerList.find((point: FingerInfo) => !!point);
    if (!finger) { return; } // Keyboard gestures have no pointer position; HEX input remains available.
    this.saturation = Math.max(0, Math.min(1, finger.localX / this.paletteWidth));
    this.colorValue = 1 - Math.max(0, Math.min(1, finger.localY / 160));
    this.customColor = hsvColor(this.hue, this.saturation, this.colorValue);
  }

  @Builder
  colorPalette() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
        Column().width('100%').height('100%').backgroundColor(hsvColor(this.hue, 1, 1))
          .linearGradient({ direction: GradientDirection.Right, colors: [['#FFFFFFFF', 0], ['#00FFFFFF', 1]] })
        Column().width('100%').height('100%')
          .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0], ['#FF000000', 1]] })
      }.width('100%').height('100%').borderRadius(Radius.md).clip(true).hitTestBehavior(HitTestMode.None)
      Circle().width(24).height(24).fill(hsvColor(this.hue, this.saturation, this.colorValue))
        .stroke(Color.White).strokeWidth(3).shadow({ radius: 3, color: '#66000000' })
        .position({ x: this.paletteWidth * this.saturation - 12, y: 160 * (1 - this.colorValue) - 12 })
        .hitTestBehavior(HitTestMode.None)
    }.id('appearance-color-palette').width('100%').height(160).accessibilityLevel('no-hide-descendants')
    .onAreaChange((_old: Area, area: Area) => { this.paletteWidth = Number(area.width); })
    .priorityGesture(GestureGroup(GestureMode.Exclusive,
      PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.All, distance: 0 })
        .onActionStart((event: GestureEvent) => this.selectPalette(event))
        .onActionUpdate((event: GestureEvent) => this.selectPalette(event))
        .onActionEnd((event: GestureEvent) => this.selectPalette(event)),
      TapGesture().onAction((event: GestureEvent) => this.selectPalette(event))))
    Slider({ value: this.hue, min: 0, max: 360, step: 1 }).id('appearance-color-hue').width('100%').height(44)
      .trackColor(this.hueGradient).selectedColor(Color.Transparent).trackThickness(18).blockSize({ width: 26, height: 26 })
      .blockColor(hsvColor(this.hue, 1, 1)).blockBorderColor(Color.White).blockBorderWidth(3)
      .accessibilityText(t('色相')).onChange((value: number) => this.selectHue(value))
  }

  @Builder
  colorEditor() {
    Column({ space: Space.md }) {
      this.colorPalette()
      Row({ space: Space.md }) {
        Circle().width(36).height(36).fill(hsvColor(this.hue, this.saturation, this.colorValue))
          .stroke($r('app.color.divider')).strokeWidth(0.5).accessibilityLevel('no')
        TextInput({ text: this.customColor, placeholder: '#216451' }).fontFamily(this.appearance.fontFamily)
          .id('appearance-color-hex').attributeModifier(Styles.input).layoutWeight(1).maxLength(7)
          .accessibilityText(t('颜色代码')).onChange((value: string) => this.updateColor(value))
      }.width('100%')
      if (!this.validColor()) { Banner({ text: t('请输入 #RRGGBB 格式的颜色代码。') }) }
      Button(t('应用颜色')).fontFamily(this.appearance.fontFamily).id('appearance-color-apply').attributeModifier(Btn.primary).width('100%')
        .enabled(this.validColor()).onClick(() => this.applyColor())
    }.width('100%')
  }

  @Builder
  choices() {
    Column({ space: Space.md }) {
      if (this.choice === 'custom') { this.colorEditor() }
      else { GroupCard() {
        Column() {
          if (this.choice === 'mode') {
            ForEach(APPEARANCE_MODES, (mode: AppearanceMode, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: this.modeName(mode), active: this.options.mode === mode, trailing: 'select',
                compId: 'appearance-mode-' + mode, onTap: () => this.selectMode(mode) })
            }, (mode: AppearanceMode) => mode)
          } else if (this.choice === 'font') {
            if (this.fontLoading) {
              Row({ space: Space.sm }) {
                LoadingProgress().width(18).height(18).color(this.appearance.accent)
                Text(t('正在读取字体…')).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary'))
              }.width('100%').padding(Space.lg)
            }
            ForEach(this.fonts, (family: string, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: this.fontName(family), active: this.options.fontFamily === family, trailing: 'select',
                compId: 'appearance-font-' + index, onTap: () => this.selectFont(family) })
            }, (family: string) => family)
          } else {
            ForEach(LIGHT_EFFECTS, (effect: LightEffect, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: this.effectName(effect), subtitle: this.effectDescription(effect), active: this.options.lightEffect === effect,
                trailing: 'select', compId: 'appearance-effect-' + effect, onTap: () => this.selectEffect(effect) })
            }, (effect: LightEffect) => effect)
          }
        }
      } }
      if (this.error) { Banner({ text: this.error, compId: 'appearance-sheet-error' }) }
    }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
  }

  @Builder
  preview() {
    Column({ space: Space.lg }) {
      Row({ space: Space.sm }) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(18).fontColor([$r('app.color.text_secondary')])
          .width(28).height(32).accessibilityLevel('no')
        Text(t('今天的计划')).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
          .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
          .textAlign(TextAlign.Center).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(18).fontColor([$r('app.color.text_secondary')])
          .width(28).height(32).accessibilityLevel('no')
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([this.appearance.accent])
          .width(28).height(32).accessibilityLevel('no')
      }.width('100%')
      Row() {
        Text(t('帮我安排今天的工作')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).lineHeight(24)
          .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).constraintSize({ maxWidth: '90%' })
          .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
          .backgroundColor(this.appearance.userBubble)
      }.width('100%').justifyContent(FlexAlign.End)
      Column({ space: Space.sm }) {
        Row({ space: Space.sm }) {
          Image($r('app.media.tinybot')).width(22).height(22).accessibilityLevel('no')
          Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
        }.width('100%')
        Text(t('先完成最重要的任务，再留出时间休息。')).fontFamily(this.appearance.fontFamily)
          .fontSize(Font.body).lineHeight(24).fontColor($r('app.color.text_primary')).width('100%')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.padding(Space.lg).width('100%').backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  appearancePage() {
    Scroll() {
      Column({ space: Space.sm }) {
        this.preview()
        SectionHeader({ title: t('主题') })
        GroupCard() {
          Column() {
            NavRow({ title: t('明暗模式'), icon: $r('sys.symbol.circle'), value: this.modeName(this.options.mode), compId: 'appearance-mode', onTap: () => this.open('mode') })
            RowDivider()
            Column({ space: Space.md }) {
              Text(t('主题色')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary')).width('100%')
              Row({ space: Space.xs }) {
                ForEach(ACCENT_NAMES.filter((name: AccentName) => name !== 'custom'), (name: AccentName) => {
                  Button({ type: ButtonType.Normal }) {
                    Column({ space: 6 }) {
                      Stack() {
                        Circle().width(32).height(32).fill(accentPalette(name, this.dark).accent)
                        if (this.options.accent === name) {
                          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([accentPalette(name, this.dark).onAccent])
                        }
                      }.width(40).height(40)
                      Text(this.accentName(name)).fontFamily(this.appearance.fontFamily).fontSize(11)
                        .fontColor($r('app.color.text_secondary')).maxLines(1)
                    }
                  }.fontFamily(this.appearance.fontFamily).id('appearance-accent-' + name).layoutWeight(1).padding({ top: 4, bottom: 8 })
                  .backgroundColor(Color.Transparent).borderRadius(Radius.sm).accessibilityText(this.accentName(name))
                  .accessibilitySelected(this.options.accent === name).onClick(() => this.selectAccent(name))
                }, (name: AccentName) => name)
              }.width('100%')
            }.padding(Space.lg).width('100%')
            RowDivider()
            NavRow({ title: t('自定义颜色'), icon: $r('sys.symbol.picture'), value: this.options.accent === 'custom' ? this.options.customColor : '',
              compId: 'appearance-custom-color', onTap: () => this.open('custom') })
          }
        }
        SectionHeader({ title: t('字体') })
        GroupCard() {
          Column() {
            NavRow({ title: t('界面字体'), icon: $r('sys.symbol.textformat'), value: this.fontName(this.options.fontFamily),
              compId: 'appearance-font', onTap: () => this.open('font') })
            RowDivider()
            Column({ space: Space.md }) {
              Text(t('字号')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary')).width('100%')
              Segmented({ options: this.scaleNames(), selected: FONT_SCALES.indexOf(this.options.fontScale),
                optionIds: ['appearance-size-small', 'appearance-size-standard', 'appearance-size-large', 'appearance-size-larger'],
                onSelect: (index: number) => this.selectScale(index) })
            }.width('100%').padding(Space.lg)
          }
        }
        SectionHeader({ title: t('光感与材质') })
        GroupCard() {
          NavRow({ title: t('光感效果'), icon: $r('sys.symbol.wand_and_stars'), value: this.effectName(this.options.lightEffect),
            compId: 'appearance-effect', onTap: () => this.open('effect') })
        }
        if (this.error) { Banner({ text: this.error, compId: 'appearance-error' }) }
        Button(t('恢复默认外观')).fontFamily(this.appearance.fontFamily).id('appearance-reset').attributeModifier(Btn.text)
          .onClick(() => this.save(defaultAppearance())).margin({ top: Space.sm })
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
    }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
  }
  build() {
    if (this.choice) {
      Scroll() { this.choices() }.width('100%').height('100%').align(Alignment.Top)
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    } else { this.appearancePage() }
  }
}
