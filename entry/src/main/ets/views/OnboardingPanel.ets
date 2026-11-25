import { vibrator } from '@kit.SensorServiceKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Motion, Radius, Space } from '../common/Theme';
import { Banner, Segmented } from '../common/Widgets';
import { APPEARANCE_MODES, AppearanceMode, AppearanceOptions, copyAppearance, defaultAppearance } from '../model/Appearance';
import { Diagnostics } from '../model/Diagnostics';
import { AppLanguage, t } from '../model/I18n';
import { ProviderInfo } from '../model/Provider';
import { isSupportedProtocol } from '../model/ProviderEndpoint';
import { ModelChoice, ProviderProfile } from '../model/ProviderProfiles';
import { AppearancePreferences } from '../services/AppearancePreferences';
import { HuaweiAccount } from '../services/HuaweiAccount';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { languageName } from './LanguagePanel';
import { ConfettiPoint, OnboardingConfetti } from './OnboardingConfetti';
import { OnboardingProviderForm } from './OnboardingProviderForm';

const LANGUAGES: AppLanguage[] = ['system', 'zh-CN', 'en'];
const STEPS: number[] = [1, 2, 3, 4];
const CUSTOM_PROVIDER: string = 'custom';
const MODEL_NAMES: Map<string, string> = new Map([
  ['deepseek-flash', 'DeepSeek Flash'],
  ['deepseek-v4-flash', 'DeepSeek V4 Flash'],
  ['deepseek-v4-pro', 'DeepSeek V4 Pro'],
  ['qwen-plus', 'Qwen Plus'],
  ['qwen-max', 'Qwen Max'],
  ['qwen-turbo', 'Qwen Turbo'],
  ['gpt-4.1', 'GPT-4.1'],
  ['glm-5.3', 'GLM-5.3'],
  ['glm-5.3-flash', 'GLM-5.3 Flash'],
  ['glm-5.2', 'GLM-5.2'],
  ['kimi-k3.1-pro', 'Kimi K3.1 Pro'],
  ['kimi-k3', 'Kimi K3'],
  ['MiniMax-M3.1-Flash', 'MiniMax M3.1 Flash'],
  ['mimo-v2.6-flash', 'MiMo V2.6 Flash'],
  ['mimo-v2.6-pro', 'MiMo V2.6 Pro'],
  ['doubao-seed-2-1-lite-260915', 'Doubao Seed 2.1 Lite'],
  ['doubao-seed-2-1-pro-260915', 'Doubao Seed 2.1 Pro']
]);

@Component
export struct OnboardingPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.options') private options: AppearanceOptions = defaultAppearance();
  @StorageProp('tinybot.language') private language: string = 'system';
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @StorageProp('tinybot.foreground') private foreground: boolean = true;
  @ObjectLink app: ChatViewModel;
  @ObjectLink account: HuaweiAccount;
  @Prop active: boolean = true;
  @Prop @Watch('backRequested') backRequest: number = 0;
  initialStep: number = 1;
  onMove: (step: number, forward: boolean) => void = () => {};
  onClose: (completed: boolean) => void = () => {};
  onLegal: (page: string) => void = () => {};

  @State private step: number = 1;
  @State private agreed: boolean = false;
  @State private saving: boolean = false;
  @State private error: string = '';
  @State private invalidField: string = '';
  @State private choosingProvider: boolean = false;
  @State private providerChoice: string = '';
  @State private modelId: string = '';
  @State private slideDirection: number = 1;
  @State private trackWidth: number = 0;
  @State private viewportHeight: number = 0;
  @State private bodyHeight: number = 0;
  @State private cardHeight: number = 0;
  @State private confettiTap: ConfettiPoint = { x: 0, y: 0 };
  private scroller: Scroller = new Scroller();
  private mounted: boolean = false;

  private t(message: string, values: (string | number)[] = []): string { return t(message, values, this.locale); }

  aboutToAppear(): void {
    this.step = this.initialStep;
    this.mounted = true;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    if (this.providerChoice) { this.clearProviderDraft(); }
  }

  private visibleStep(): number {
    if (!this.account.signedIn) { return 1; }
    return this.step === 4 && !this.app.configured ? 3 : this.step;
  }

  private celebrateTap(event: GestureEvent): void {
    if (this.visibleStep() !== 4 || !this.active || !this.foreground || this.appearance.effectStrength === 0) {
      return;
    }
    const finger = event.fingerList[0];
    if (finger) { this.confettiTap = { x: finger.localX, y: finger.localY }; }
  }

  private stepLabel(step: number): string {
    if (step === 1) { return this.t('账号'); }
    if (step === 2) { return this.t('偏好'); }
    if (step === 3) { return this.t('模型'); }
    return this.t('完成');
  }

  private blocked(): boolean {
    return !this.mounted || !this.foreground || !this.active || this.saving || this.account.busy;
  }

  private move(step: number): void {
    const previous = this.visibleStep();
    this.onMove(step, step > previous);
    this.getUIContext().getFocusController().clearFocus();
    this.scroller.scrollEdge(Edge.Top);
    this.clearValidation();
    this.slideDirection = step > previous ? 1 : -1;
    this.step = step;
    if (step > previous && this.appearance.effectStrength > 0) { this.playStepHaptic(step === 4); }
  }

  private async playStepHaptic(completed: boolean): Promise<void> {
    const effectId = completed ? vibrator.HapticFeedback.EFFECT_NOTICE_SUCCESS : vibrator.HapticFeedback.EFFECT_SOFT;
    try {
      if (vibrator.isSupportEffectSync(effectId)) {
        await vibrator.startVibration({ type: 'preset', effectId }, { usage: 'touch' });
      }
    } catch (error) {
      Diagnostics.log('warn', 'onboarding', 'haptic_failed',
        { operation: completed ? 'haptic_complete' : 'haptic_step' }, error as Error);
    }
  }

  private goBack(step: number): void {
    if (this.blocked() || !this.editableStep(step)) { return; }
    try { this.move(step); } catch (error) { this.error = (error as Error).message; }
  }

  private backRequested(): void {
    const step = this.visibleStep();
    if (step === 4) { this.primaryAction(); }
    else if (step > 1) { this.goBack(step - 1); }
    else { this.pause(); }
  }

  private editableStep(step: number): boolean {
    const current = this.visibleStep();
    return current < 4 && step < current;
  }

  private pause(): void {
    if (!this.blocked()) { this.onClose(false); }
  }

  private primaryLabelKey(): string {
    const step = this.visibleStep();
    if (step === 1 && !this.account.signedIn) {
      return this.account.busy ? '正在登录…' : '华为账号登录';
    }
    if (step === 3 && this.providerChoice) { return this.saving ? '正在保存…' : '保存并继续'; }
    return step === 4 ? '开始使用' : '继续';
  }

  private canContinue(): boolean {
    if (this.blocked()) { return false; }
    const step = this.visibleStep();
    if (step === 1) { return this.account.ready && (this.account.signedIn || this.agreed); }
    if (step === 3) { return !this.app.busy && (!!this.providerChoice || (this.app.configured && !this.choosingProvider)); }
    return true;
  }

  private async primaryAction(): Promise<void> {
    if (!this.canContinue()) { return; }
    this.error = '';
    try {
      const step = this.visibleStep();
      if (step === 1 && !this.account.signedIn) { await this.account.signIn(); return; }
      if (step === 3 && this.providerChoice) { await this.saveProvider(); return; }
      if (step === 4) { this.onClose(true); return; }
      this.move(step + 1);
    } catch (error) { this.error = (error as Error).message; }
  }

  private clearValidation(): void { this.error = ''; this.invalidField = ''; }

  private async setLanguage(value: AppLanguage): Promise<void> {
    if (this.blocked() || value === this.language) { return; }
    this.saving = true;
    this.error = '';
    try { await LanguagePreferences.select(value); }
    catch (error) { if (this.mounted) { this.error = this.t('无法保存语言设置，请重试。') + ' ' + (error as Error).message; } }
    finally { this.saving = false; }
  }

  private async setMode(mode: AppearanceMode): Promise<void> {
    if (this.blocked() || mode === this.options.mode) { return; }
    const next = copyAppearance(this.options);
    next.mode = mode;
    this.saving = true;
    this.error = '';
    try { await AppearancePreferences.select(next); }
    catch (error) { if (this.mounted) { this.error = this.t('无法保存外观设置，请重试。') + ' ' + (error as Error).message; } }
    finally { this.saving = false; }
  }

  private modeLabel(mode: AppearanceMode): string {
    return mode === 'system' ? this.t('跟随系统') : mode === 'light' ? this.t('浅色') : this.t('深色');
  }

  private presets(): ProviderInfo[] {
    return this.app.providerPresets.filter((preset: ProviderInfo) => isSupportedProtocol(preset.protocol));
  }

  private providerOptions(): SelectOption[] {
    return this.presets().map((preset: ProviderInfo): SelectOption => ({ value: preset.name }))
      .concat([{ value: this.t('自定义服务') }]);
  }

  private chooseProvider(index: number): void {
    if (this.blocked() || this.app.busy) { return; }
    const preset = this.presets()[index];
    const choice = preset?.id || CUSTOM_PROVIDER;
    if (choice === this.providerChoice) { return; }
    try {
      const profile = preset ? this.app.providerProfiles.find((item: ProviderProfile) =>
        item.presetId === preset.id && isSupportedProtocol(item.protocol)) : undefined;
      if (!this.app.beginProvider(preset?.id || '', profile?.id || '')) {
        throw new Error(this.app.error || this.t('有任务正在进行，请稍后重试。'));
      }
      const editor = this.app.providerEditor;
      if (!preset) { editor.name = this.t('自定义服务'); }
      const current = this.app.active.modelRef;
      this.modelId = current && profile && current.providerId === profile.id && editor.modelList.includes(current.modelId) ?
        current.modelId : editor.modelList[0] || preset?.defaultModel || '';
      this.providerChoice = choice;
      this.clearValidation();
    } catch (error) { this.error = (error as Error).message; }
  }

  private clearProviderDraft(): void {
    this.app.providerEditor.apiKey = '';
    this.app.providerEditor.balanceApiKey = '';
    this.providerChoice = '';
    this.modelId = '';
    this.choosingProvider = false;
  }

  private async chooseSavedModel(index: number): Promise<void> {
    if (this.blocked() || this.app.busy) { return; }
    const choice = this.app.modelChoices[index];
    if (!choice) { return; }
    this.error = '';
    this.saving = true;
    try {
      if (!await this.app.selectModel(choice.providerId, choice.modelId)) {
        throw new Error(this.app.error || this.t('无法选择模型，请重试。'));
      }
    } catch (error) { this.error = (error as Error).message; }
    finally { this.saving = false; }
  }

  private async saveProvider(): Promise<void> {
    const model = this.modelId.trim();
    if (!model || /[\r\n,，]/.test(model) || model.length > 200) {
      this.invalidField = 'model-id';
      throw new Error(this.t('请输入一个有效的模型 ID。'));
    }
    const editor = this.app.providerEditor;
    const fields = ['name', 'url', 'key', 'context'];
    const invalid = fields.find((field: string) => !!editor.fieldError(field));
    if (invalid) {
      this.invalidField = invalid;
      throw new Error(editor.fieldError(invalid));
    }

    this.getUIContext().getFocusController().clearFocus();
    const profileId = editor.id;
    const existing = new Set<string>(this.app.providerProfiles.map((item: ProviderProfile) => item.id));
    editor.models = [model].concat(editor.modelList.filter((id: string) => id !== model)).join('\n');
    editor.enabled = true;
    this.saving = true;
    try {
      if (!await this.app.saveProvider()) { throw new Error(editor.error || this.app.error || this.t('模型服务未保存，请稍后重试。')); }
      if (!this.mounted) { return; }
      const profile = this.app.providerProfiles.find((item: ProviderProfile) => profileId ?
        item.id === profileId : !existing.has(item.id));
      if (!profile) { throw new Error(this.t('模型服务已保存，但无法找到对应配置，请重新打开设置。')); }
      // Bind retries to the committed service, even if selecting its default model fails.
      editor.reset(profile);
      const current = this.app.active.modelRef;
      if ((current?.providerId !== profile.id || current?.modelId !== model || !this.app.configured) &&
        !await this.app.selectModel(profile.id, model)) {
        throw new Error(this.app.error || this.t('模型服务已保存，但未能切换当前模型，请重试。'));
      }
      if (!this.mounted || !this.active) { return; }
      this.clearProviderDraft();
      if (this.account.signedIn && this.app.configured) { this.move(4); }
    } finally { this.saving = false; }
  }

  private segmentWidth(): number { return this.trackWidth / STEPS.length; }

  private modelLabel(providerName: string, modelId: string): string {
    const name = MODEL_NAMES.get(modelId) || modelId;
    return !providerName || name.toLowerCase().startsWith(providerName.toLowerCase() + ' ') ?
      name : providerName + ' · ' + name;
  }

  private selectedModelLabel(): string {
    const ref = this.app.active.modelRef;
    if (!ref) { return this.app.currentModelLabel; }
    const provider = this.app.providerProfiles.find((profile: ProviderProfile) => profile.id === ref.providerId);
    return this.modelLabel(provider?.name || '', ref.modelId);
  }

  private paneTransition(): TransitionEffect {
    if (this.appearance.effectStrength === 0) { return TransitionEffect.IDENTITY; }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDirection * 24 }))
        .animation({ duration: 240, curve: Motion.enter }),
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -this.slideDirection * 16 }))
        .animation({ duration: 150, curve: Motion.standard }));
  }

  private measureBody(step: number, height: number): void {
    if (step !== this.visibleStep()) { return; }
    const measured = Math.ceil(height);
    if (measured <= 0 || measured === this.bodyHeight) { return; }
    if (this.bodyHeight === 0 || this.appearance.effectStrength === 0) { this.bodyHeight = measured; }
    else {
      this.getUIContext().animateTo({ duration: 250, curve: Motion.enter, delay: step === 4 ? 120 : 0 },
        () => { this.bodyHeight = measured; });
    }
  }

  private maxBodyHeight(): number {
    const reserved = this.error ? 292 : 236;
    return this.viewportHeight > 0 ? Math.min(438, Math.max(96, this.viewportHeight - reserved)) : 420;
  }

  private illustrationHeight(step: number): number {
    const compact = this.viewportHeight > 0 && this.viewportHeight < 520;
    if (step === 3) { return compact ? 64 : Math.max(98, this.trackWidth * 0.24); }
    if (step === 2) { return compact ? 94 : Math.max(142, this.trackWidth * 0.42); }
    return compact ? 112 : Math.max(174, this.trackWidth * 0.46);
  }

  @Builder
  illustration(art: Resource, step: number) {
    Image(art).id('onboarding-illustration-' + step).width('100%').height(this.illustrationHeight(step))
      .objectFit(ImageFit.Cover).borderRadius(Radius.lg).clip(true)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .transition(this.appearance.effectStrength > 0 ? TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
          .animation({ duration: 280, delay: 60, curve: Motion.enter }), TransitionEffect.IDENTITY) : TransitionEffect.IDENTITY)
  }

  @Builder
  stepBadge(step: number) {
    Column({ space: 5 }) {
      Stack() {
        if (step < this.visibleStep() || this.visibleStep() === 4) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13)
            .fontColor([this.appearance.onAccentContainer])
            .transition(this.appearance.effectStrength > 0 ? Motion.pop() : TransitionEffect.IDENTITY)
        } else {
          Text(String(step)).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(step === this.visibleStep() ? this.appearance.onAccent : $r('app.color.text_secondary'))
        }
      }.width(26).height(26).borderRadius(13).backgroundColor(step < this.visibleStep() || this.visibleStep() === 4 ?
        this.appearance.accentContainer : step === this.visibleStep() ? this.appearance.accent : $r('app.color.onboarding_tint'))
        .animation({ duration: this.appearance.effectStrength > 0 ? 220 : 0, curve: Motion.standard })
      Text(this.stepLabel(step)).fontFamily(this.appearance.fontFamily).fontSize(11).fontWeight(FontWeight.Medium)
        .fontColor(step === this.visibleStep() ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.padding({ top: 5, left: 2, right: 2 }).justifyContent(FlexAlign.Start).width('100%').height('100%')
  }

  @Builder
  progress() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.trackWidth > 0) {
        Blank().width(this.segmentWidth() * 3).height(1).backgroundColor($r('app.color.onboarding_outline'))
          .position({ x: this.segmentWidth() / 2, y: 18 })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Blank().width(this.segmentWidth() * (this.visibleStep() - 1)).height(2).borderRadius(1)
          .backgroundColor(this.appearance.accent).position({ x: this.segmentWidth() / 2, y: 17 })
          .animation({ duration: this.appearance.effectStrength > 0 ? 300 : 0, curve: Motion.thumb })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Blank().width(36).height(36).borderRadius(18)
          .backgroundColor($r('app.color.onboarding_surface')).border({ width: 1, color: this.appearance.accentOutline })
          .position({ x: (this.visibleStep() - 0.5) * this.segmentWidth() - 18, y: 0 })
          .animation({ duration: this.appearance.effectStrength > 0 ? 300 : 0, curve: Motion.thumb })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      Row() {
        ForEach(STEPS, (step: number) => {
          Stack() {
            this.stepBadge(step)
            if (this.editableStep(step)) {
              Button('', { type: ButtonType.Normal, stateEffect: false })
                .width('100%').height('100%').padding(0).backgroundColor(Color.Transparent)
                .accessibilityText(this.t('第 {0} 步，共 4 步', [String(step)]) + ' · ' + this.stepLabel(step))
                .enabled(!this.blocked()).onClick(() => this.goBack(step))
            }
          }.id('onboarding-step-' + step).height(54).layoutWeight(1)
            .accessibilityGroup(!this.editableStep(step))
            .accessibilityText(this.editableStep(step) ? '' :
              this.t('第 {0} 步，共 4 步', [String(step)]) + ' · ' + this.stepLabel(step))
            .accessibilitySelected(step === this.visibleStep())
        }, (step: number) => String(step))
      }.width('100%')
    }.width('100%').height(54)
      .onAreaChange((_old: Area, area: Area) => { this.trackWidth = Number(area.width); })
  }

  @Builder
  heading(title: () => string) {
    Text(title()).id('onboarding-title').fontFamily(this.appearance.fontFamily).fontSize(27).fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_primary')).width('100%')
  }

  @Builder
  accountStep() {
    this.heading(() => this.t('登录华为账号'))
    if (!this.account.signedIn) {
      Text(this.account.ready ? this.t('登录后即可使用 AI 生成功能。') : this.t('正在确认登录状态，请稍候。'))
        .fontFamily(this.appearance.fontFamily).fontSize(14).lineHeight(21)
        .fontColor($r('app.color.text_secondary')).width('100%')
    }
    this.illustration($r('app.media.onboarding_account'), 1)
    if (this.account.signedIn) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(22).fontColor([this.appearance.accent])
        Text(this.t('已登录华为账号')).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
      }.width('100%').padding(12).borderRadius(Radius.md).backgroundColor($r('app.color.onboarding_tint'))
    } else {
      Row({ space: 6 }) {
        Checkbox().id('onboarding-consent').select(this.agreed).selectedColor(this.appearance.accent)
          .enabled(!this.account.busy).accessibilityText(this.t('我已阅读并同意用户协议'))
          .onChange((checked: boolean) => { this.agreed = checked; })
        Text() {
          Span(this.t('我已阅读并同意'))
          Span(this.t('用户协议')).fontColor(this.appearance.accent)
            .decoration({ type: TextDecorationType.Underline }).onClick(() => this.onLegal('terms'))
        }.fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button(this.t('隐私政策')).id('onboarding-privacy').attributeModifier(Btn.textSmall)
          .padding({ left: 6, right: 0 }).onClick(() => this.onLegal('privacy'))
      }.width('100%').constraintSize({ minHeight: 44 })
      if (this.account.error) { Banner({ text: this.account.error, compId: 'onboarding-account-error' }) }
    }
  }

  @Builder
  preferencesStep() {
    Column({ space: 4 }) {
      this.heading(() => this.t('外观与语言'))
      Text(this.t('按你的习惯来，之后随时可以在设置里调整。')).fontFamily(this.appearance.fontFamily)
        .fontSize(14).lineHeight(21).fontColor($r('app.color.text_secondary')).width('100%')
    }.width('100%')
    this.illustration($r('app.media.onboarding_preferences'), 2)
    Column({ space: 8 }) {
      Text(this.t('语言')).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary')).width('100%')
      Segmented({ options: LANGUAGES.map((value: AppLanguage) => languageName(value, this.locale)),
        selected: LANGUAGES.indexOf(this.language as AppLanguage),
        controlHeight: 50, labelSize: 13, trackRadius: Radius.md, accentThumb: true, thumbShadow: false,
        trackFill: Color.Transparent, trackOutline: $r('app.color.onboarding_outline'), compIdPrefix: 'onboarding-language',
        optionIds: LANGUAGES.map((value: AppLanguage) => 'onboarding-language-' + value),
        onSelect: (index: number) => this.setLanguage(LANGUAGES[index]) })
    }.width('100%')
    Column({ space: 8 }) {
      Text(this.t('明暗模式')).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary')).width('100%')
      Segmented({ options: APPEARANCE_MODES.map((mode: AppearanceMode) => this.modeLabel(mode)),
        selected: APPEARANCE_MODES.indexOf(this.options.mode),
        controlHeight: 50, labelSize: 13, trackRadius: Radius.md, accentThumb: true, thumbShadow: false,
        trackFill: Color.Transparent, trackOutline: $r('app.color.onboarding_outline'), compIdPrefix: 'onboarding-appearance',
        optionIds: APPEARANCE_MODES.map((mode: AppearanceMode) => 'onboarding-appearance-' + mode),
        onSelect: (index: number) => this.setMode(APPEARANCE_MODES[index]) })
    }.width('100%')
  }

  @Builder
  providerStep() {
    this.heading(() => this.t('配置模型服务'))
    this.illustration($r('app.media.onboarding_provider'), 3)
    if (this.app.configured && !this.choosingProvider) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(22).fontColor([this.appearance.accent])
        Column({ space: 4 }) {
          Text(this.selectedModelLabel()).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).width('100%').id('onboarding-current-model')
          Text(this.t('可以用它开始对话、整理资料或起草内容。')).fontFamily(this.appearance.fontFamily)
            .fontSize(13).lineHeight(19).fontColor($r('app.color.text_secondary')).width('100%')
        }.layoutWeight(1)
        Button(this.t('更换服务')).id('onboarding-provider-replace').attributeModifier(Btn.textSmall)
          .onClick(() => { this.choosingProvider = true; })
      }.width('100%').padding(12).borderRadius(Radius.md).backgroundColor($r('app.color.onboarding_tint'))
    } else {
      if (!this.providerChoice && !this.app.configured && this.app.modelChoices.length > 0) {
        Select(this.app.modelChoices.map((item: ModelChoice): SelectOption =>
          ({ value: this.modelLabel(item.providerName, item.modelId) })))
          .id('onboarding-provider-existing').width('100%').height(44).value(this.t('选择已有模型'))
          .enabled(!this.saving).accessibilityText(this.t('选择已有模型')).onSelect((index: number) => this.chooseSavedModel(index))
      }
      Select(this.providerOptions()).id('onboarding-provider-picker').width('100%').height(44)
        .selected(this.providerChoice === CUSTOM_PROVIDER ? this.presets().length :
          this.presets().findIndex((preset: ProviderInfo) => preset.id === this.providerChoice))
        .value(this.providerChoice === CUSTOM_PROVIDER ? this.t('自定义服务') :
          this.presets().find((preset: ProviderInfo) => preset.id === this.providerChoice)?.name || this.t('选择服务商'))
        .accessibilityText(this.t('选择服务商')).enabled(!this.saving)
        .onSelect((index: number) => this.chooseProvider(index))
      ForEach(this.providerChoice ? [this.providerChoice] : [], (choice: string) => {
        OnboardingProviderForm({ editor: this.app.providerEditor, modelId: this.modelId, invalidField: this.invalidField,
          custom: choice === CUSTOM_PROVIDER, locked: this.blocked(), onEdit: () => this.clearValidation(),
          onError: (message: string) => { this.error = message; } })
      }, (choice: string) => choice)
      if (this.app.configured) {
        Button(this.t('取消更改')).id('onboarding-provider-cancel').attributeModifier(Btn.textSmall)
          .enabled(!this.saving).onClick(() => { this.clearProviderDraft(); this.clearValidation(); })
      }
    }
  }

  @Builder
  completionStep() {
    Column({ space: 12 }) {
      Text(this.t('设置完成！')).id('onboarding-completed-title').fontFamily(this.appearance.fontFamily).fontSize(28)
        .fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
      this.illustration($r('app.media.onboarding_complete'), 4)
      Text(this.t('默认模型：{0}', [this.selectedModelLabel()])).fontFamily(this.appearance.fontFamily)
        .fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
    }.width('100%').padding({ bottom: 4 })
  }

  @Builder
  pane(step: number) {
    Column({ space: Space.md }) {
      if (step === 1) { this.accountStep() }
      else if (step === 2) { this.preferencesStep() }
      else if (step === 3) { this.providerStep() }
      else { this.completionStep() }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12 })
      .onAreaChange((_old: Area, area: Area) => this.measureBody(step, Number(area.height)))
      .transition(this.paneTransition())
  }

  @Builder
  footer() {
    Column({ space: 2 }) {
      Row({ space: 10 }) {
        if (this.visibleStep() > 1 && this.visibleStep() < 4) {
          Button(this.t('上一步')).id('onboarding-back').attributeModifier(Btn.tonal)
            .height(46).backgroundColor($r('app.color.onboarding_tint'))
            .enabled(!this.blocked()).onClick(() => this.goBack(this.visibleStep() - 1))
        }
        Button() {
          Stack() {
            ForEach([this.primaryLabelKey()], (label: string) => {
              Text(this.t(label)).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor(this.canContinue() ? this.appearance.onAccent : $r('app.color.text_secondary'))
                .accessibilityLevel('no')
                .transition(this.appearance.effectStrength > 0 ? TransitionEffect.asymmetric(
                  TransitionEffect.OPACITY.animation({ duration: 115, delay: 55, curve: Motion.enter }),
                  TransitionEffect.OPACITY.animation({ duration: 55, curve: Motion.standard })) : TransitionEffect.IDENTITY)
            }, (label: string) => label)
          }.width('100%')
        }.id('onboarding-next').attributeModifier(Btn.primary)
          .layoutWeight(1).constraintSize({ maxWidth: '100%' }).height(46)
          .accessibilityText(this.t(this.primaryLabelKey())).enabled(this.canContinue()).onClick(() => this.primaryAction())
      }.width('100%')
      if (this.visibleStep() < 4) {
        Button(this.t('稍后设置')).id('onboarding-later').attributeModifier(Btn.text).enabled(!this.blocked())
          .onClick(() => this.pause())
      }
    }.width('100%')
  }

  build() {
    Column() {
      Column() {
        Column() {
          this.progress()
          Scroll(this.scroller) {
            Stack({ alignContent: Alignment.TopStart }) {
              ForEach([this.visibleStep()], (step: number) => { this.pane(step) }, (step: number) => String(step))
            }.width('100%')
          }.width('100%').height(this.bodyHeight > 0 ? Math.min(this.bodyHeight, this.maxBodyHeight()) : undefined)
            .constraintSize({ maxHeight: this.maxBodyHeight() }).align(Alignment.Top).clip(true)
            .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
          if (this.error) { Banner({ text: this.error, compId: 'onboarding-error' }) }
          this.footer()
        }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 6 }).borderRadius(Radius.xl)
          .backgroundColor($r('app.color.onboarding_surface')).border({ width: 1, color: $r('app.color.onboarding_outline') })
          .shadow({ radius: 20, color: '#18212922', offsetY: 7 })
          .onAreaChange((_old: Area, area: Area) => { this.cardHeight = Number(area.height); })
        if (this.visibleStep() === 4) {
          Stack() {
            OnboardingConfetti({ active: this.active, tap: this.confettiTap })
          }.width('100%').height(this.cardHeight).position({ x: 0, y: 0 })
            .borderRadius(Radius.xl).clip(true).hitTestBehavior(HitTestMode.None)
        }
      }.id('onboarding-window').width('100%').constraintSize({ maxWidth: 500 })
        .parallelGesture(TapGesture({ distanceThreshold: 8 }).onAction((event: GestureEvent) => this.celebrateTap(event)))
    }.id('onboarding-stepper').width('100%').height('100%').padding({ top: 12, bottom: 12, left: 16, right: 16 })
      .justifyContent(FlexAlign.Center).backgroundColor($r('app.color.page_background'))
      .onAreaChange((_old: Area, area: Area) => { this.viewportHeight = Number(area.height); })
  }
}
