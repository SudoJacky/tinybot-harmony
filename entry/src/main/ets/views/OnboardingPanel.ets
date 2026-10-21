import { uiMaterial } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { monochromeProviderLogo, providerLogo } from '../common/ProviderBrand';
import { OnboardingProvider, OnboardingTask, onboardingProviders, onboardingTasks } from '../model/Onboarding';
import { HuaweiAccount } from '../services/HuaweiAccount';
import { OnboardingMascot } from './OnboardingMascot';
import { OnboardingIntroduction } from './OnboardingIntroduction';
import { OnboardingProviderForm } from './OnboardingProviderForm';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { t } from '../model/I18n';

@Component
export struct OnboardingPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.dark') private dark: boolean = false;
  @StorageProp('tinybot.foreground') @Watch('foregroundChanged') private foreground: boolean = true;
  // Index clears this while the provider editor or another route covers onboarding.
  @Prop @Watch('activeChanged') active: boolean = true;
  @Prop @Watch('connectionChanged') configured: boolean = false;
  @Prop @Watch('connectionChanged') connectedPreset: string = '';
  @Prop busy: boolean = false;
  @ObjectLink account: HuaweiAccount;
  @ObjectLink app: ChatViewModel;
  onFinish: (action: string, prompt: string) => Promise<void> = async () => {};
  onConnect: (preset: string) => void = () => {};
  onLegal: (page: string) => void = () => {};
  @State private step: number = 0;
  @State private agreed: boolean = false;
  @State private greeted: boolean = false;
  @State private selectedPreset: string = '';
  @State private providerEditing: boolean = false;
  @State private connectionAttempted: boolean = false;
  @State private keyFocused: boolean = false;
  @State private selectedTask: number = -1;
  @State private message: string = '';
  @State private saving: boolean = false;
  @State private error: string = '';
  @State private waking: boolean = false;
  @State private wakeReady: boolean = false;
  @State private bodyHeight: number = 560;
  @State private pageDirection: number = 1;
  @State private transitioning: boolean = false;
  @State private actorReady: boolean = false;
  @State private actorX: number = 0;
  @State private actorY: number = 0;
  @State private actorSize: number = 180;
  private stageLeft: number = 0;
  private stageTop: number = 0;
  private stageWidth: number = 0;
  private actorScene: number = -1;
  private actorArea?: Area;
  private transitionRevision: number = 0;
  private wakeTimer: number = -1;
  private wakeRevision: number = 0;
  private mounted: boolean = false;
  private connectionScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.mounted = true;
    if (this.configured && this.connectedPreset.length > 0) { this.selectedPreset = this.connectedPreset; }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.app.providerEditor.apiKey = '';
    this.cancelWake(false);
    this.settleTransition();
  }

  private activeChanged(): void {
    if (!this.active) { this.keyFocused = false; this.cancelWake(true); this.settleTransition(); }
  }

  private foregroundChanged(): void {
    if (!this.foreground) { this.keyFocused = false; this.cancelWake(true); this.settleTransition(); }
  }

  private connectionChanged(): void {
    if (this.configured) {
      this.selectedPreset = this.connectedPreset;
      if (!this.saving) { this.providerEditing = false; this.keyFocused = false; }
    }
    this.error = '';
  }

  private animate(action: () => void, duration: number = Motion.medium): void {
    if (this.appearance.effectStrength > 0) {
      this.getUIContext().animateTo({ duration: duration, curve: Motion.standard }, action);
    } else {
      action();
    }
  }

  // The wake scene has one pending timer. Hidden/covered/backgrounded routes keep the
  // wake result as an explicit Continue instead of navigating behind the user's back.
  private cancelWake(showContinue: boolean): void {
    this.wakeRevision++;
    if (this.wakeTimer >= 0) {
      clearTimeout(this.wakeTimer);
      this.wakeTimer = -1;
    }
    if (showContinue && this.waking && this.step === 1) { this.wakeReady = true; }
  }

  private wake(): void {
    if (this.step !== 1 || !this.active || !this.foreground || this.saving || this.transitioning || this.waking) { return; }
    this.cancelWake(false);
    const revision = this.wakeRevision;
    this.error = '';
    this.wakeReady = false;
    this.waking = true;
    this.wakeTimer = setTimeout(() => {
      if (!this.mounted || revision !== this.wakeRevision) { return; }
      this.wakeTimer = -1;
      if (this.step !== 1 || !this.active || !this.foreground) { this.wakeReady = true; return; }
      this.move(1);
    }, this.appearance.effectStrength > 0 ? 1800 : 0);
  }

  private continueWake(): void {
    if (this.step !== 1 || !this.active || !this.foreground || this.saving) { return; }
    this.cancelWake(false);
    this.wakeReady = false;
    this.waking = false;
    this.move(1);
  }

  private move(delta: number): void {
    if (this.saving || this.transitioning || !this.active || !this.foreground || !this.mounted) { return; }
    const next = Math.max(0, Math.min(4, this.step + delta));
    if (next === this.step) { return; }
    this.cancelWake(false);
    this.error = '';
    this.pageDirection = next > this.step ? 1 : -1;
    const change = (): void => {
      this.step = next;
      this.keyFocused = false;
      this.greeted = false;
      this.waking = false;
      this.wakeReady = false;
    };
    if (this.appearance.effectStrength === 0) { change(); return; }
    const revision = ++this.transitionRevision;
    this.transitioning = true;
    this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard,
      onFinish: () => {
        if (this.mounted && revision === this.transitionRevision) { this.transitioning = false; }
      } }, change);
  }

  private settleTransition(): void {
    this.transitionRevision++;
    this.transitioning = false;
  }

  private sceneTransition(): TransitionEffect {
    if (this.appearance.effectStrength === 0) { return TransitionEffect.IDENTITY; }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.pageDirection * 24 }))
        .animation({ duration: Motion.medium, curve: Motion.enter }),
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -this.pageDirection * 16 }))
        .animation({ duration: Motion.fast, curve: Motion.standard }));
  }

  async finish(action: string, prompt: string = ''): Promise<void> {
    if (this.saving || this.transitioning) { return; }
    if (action !== 'skip' && this.busy) {
      this.error = t('请先完成当前任务，再准备新的草稿。');
      return;
    }
    this.cancelWake(false);
    if (action !== 'skip') {
      prompt = (prompt.length > 0 ? prompt : this.message).trim();
      if (prompt.length === 0) {
        this.error = t('先写一句想做的事，再准备草稿。');
        return;
      }
    }
    this.saving = true;
    this.error = '';
    try {
      await this.onFinish(action, action === 'skip' ? '' : prompt);
    } catch (error) {
      this.error = (error as Error).message;
    } finally {
      this.saving = false;
    }
  }

  private sceneLabel(): string {
    if (this.step === 0) { return t('验证华为账号'); }
    if (this.step === 1) { return t('第一次见面'); }
    if (this.step === 2) { return t('认识 Tiny'); }
    if (this.step === 3) { return t('连接模型'); }
    return t('第一个任务');
  }

  private primaryLabel(): string {
    if (this.step === 0) {
      if (this.account.signedIn) { return t('继续'); }
      return this.account.busy ? t('正在登录…') : t('华为账号登录');
    }
    if (this.step === 1) { return t('继续'); }
    if (this.step === 2) { return t('继续'); }
    if (this.step === 3) {
      if (this.saving) { return t('正在保存…'); }
      if (this.configured && !this.providerEditing) { return t('继续'); }
      return this.providerEditing ? t('保存服务') : t('选择服务商');
    }
    return t('带进聊天');
  }

  private primaryEnabled(): boolean {
    return !this.transitioning && this.primaryAvailable();
  }

  private primaryAvailable(): boolean {
    if (this.saving || !this.active || !this.foreground) { return false; }
    if (this.step === 0) {
      if (this.account.signedIn) { return true; }
      return this.account.ready && !this.account.busy && this.agreed;
    }
    if (this.step === 1) { return this.wakeReady && this.active && this.foreground; }
    if (this.step === 3) {
      return this.configured && !this.providerEditing ? true :
        (!this.busy && this.providerEditing && this.selectedPreset.length > 0);
    }
    if (this.step === 4) { return !this.busy && this.message.trim().length > 0; }
    return true;
  }

  private primaryAction(): void {
    if (!this.primaryEnabled()) { return; }
    if (this.step === 0) {
      if (this.account.signedIn) { this.move(1); } else { this.signInAccount(); }
      return;
    }
    if (this.step === 1) { this.continueWake(); return; }
    if (this.step === 3) {
      if (this.configured && !this.providerEditing) { this.move(1); } else { this.connectSelected(); }
      return;
    }
    if (this.step === 4) { this.finish('start', this.currentPrompt()); return; }
    this.move(1);
  }

  // Native Account Kit owns consent, the sign-in sheet and account switching.
  // Onboarding only waits for the verified result and never reads profile data.
  private async signInAccount(): Promise<void> {
    if (this.saving || this.transitioning || !this.active || !this.foreground) { return; }
    if (!this.account.ready) { this.error = t('正在确认登录状态，请稍候。'); return; }
    if (!this.agreed) { this.error = t('请先阅读并同意用户协议和隐私政策。'); return; }
    this.error = '';
    await this.account.signIn();
  }

  private brand(): ResourceColor { return this.appearance.accent; }
  private page(): ResourceColor { return $r('app.color.page_background'); }
  private ink(): ResourceColor { return $r('app.color.text_primary'); }
  private muted(): ResourceColor { return $r('app.color.text_secondary'); }
  private faint(): ResourceColor { return $r('app.color.text_tertiary'); }
  private bubble(): ResourceColor { return $r('app.color.surface'); }
  private line(): ResourceColor { return $r('app.color.divider'); }
  private brandSoft(): ResourceColor { return this.appearance.accentContainer; }
  private brandInk(): ResourceColor { return this.appearance.accent; }
  private disabledFill(): ResourceColor { return $r('app.color.surface_variant'); }

  // At the comfortable size this is the agreed 200 tile / 180 mascot. Only very
  // short viewports shrink it, so the wake action and Continue stay reachable.
  private wakeTileSize(): number { return Math.max(140, Math.min(200, this.bodyHeight - 230)); }
  private wakeDiameter(): number { return Math.round(this.wakeTileSize() * 0.9); }

  private selectProvider(preset: string): void {
    if (this.saving || this.busy || this.transitioning) { return; }
    if (preset.length > 0) {
      try {
        const existing = this.app.providerProfiles.find(profile => profile.presetId === preset);
        if (!this.app.beginProvider(preset, existing?.id || '')) {
          throw new Error(this.app.error || t('请先完成当前任务，再开始新的对话。'));
        }
      } catch (error) { this.error = (error as Error).message; return; }
    } else { this.app.providerEditor.apiKey = ''; }
    this.error = '';
    this.animate((): void => {
      this.selectedPreset = preset;
      this.providerEditing = preset.length > 0;
      this.connectionAttempted = false;
      this.keyFocused = false;
    }, 320);
  }

  private providerSelectionChanged(preset: string, selected: boolean): void {
    // Synchronizing the previous Toggle to off can emit after the new choice's on event.
    if (selected || this.selectedPreset === preset) { this.selectProvider(selected ? preset : ''); }
  }

  private async connectSelected(): Promise<void> {
    if (this.saving || this.busy || this.transitioning || !this.active || !this.foreground || !this.mounted) { return; }
    if (this.selectedPreset.length === 0 || !this.providerEditing) {
      this.error = t('先选择一个模型服务。');
      return;
    }
    this.connectionAttempted = true;
    const editor = this.app.providerEditor;
    const invalid = ['name', 'url', 'key', 'models', 'context'].find(field => editor.fieldError(field).length > 0);
    if (invalid) {
      this.error = editor.fieldError(invalid);
      this.getUIContext().getFocusController().requestFocus('onboarding-inline-' + invalid);
      return;
    }
    this.saving = true;
    this.error = '';
    try {
      if (!await this.app.saveProvider()) {
        throw new Error(editor.error || this.app.error || t('模型服务未保存，请稍后重试。'));
      }
      const profile = this.app.providerProfiles.find(item => item.presetId === this.selectedPreset);
      if (!profile) { throw new Error(t('模型服务已保存，但无法找到对应配置，请重新打开设置。')); }
      editor.reset(profile);
      const current = this.app.active.modelRef;
      const modelId = current?.providerId === profile.id && profile.models.includes(current.modelId) ?
        current.modelId : profile.models[0];
      if ((current?.providerId !== profile.id || current.modelId !== modelId) &&
        !await this.app.selectModel(profile.id, modelId)) {
        throw new Error(this.app.error || t('模型服务已保存，但未能切换当前模型，请重试。'));
      }
      this.providerEditing = false;
      this.keyFocused = false;
      this.getUIContext().getFocusController().clearFocus();
    } catch (error) { this.error = (error as Error).message; }
    finally { this.saving = false; }
  }

  private providerLookX(): number {
    const index = onboardingProviders().findIndex(provider => provider.preset === this.selectedPreset);
    return index < 0 ? 0 : (index - 1) * 5;
  }

  private connectionDiameter(): number {
    if (this.keyFocused) { return 96; }
    return this.providerEditing ? Math.max(96, Math.min(128, this.bodyHeight - 380)) : 160;
  }

  private setKeyFocused(focused: boolean): void {
    if (!this.mounted || focused === this.keyFocused) { return; }
    this.animate(() => { this.keyFocused = focused; }, 320);
    if (focused) { this.keepKeyVisible(); }
  }

  private keepKeyVisible(): void {
    if (this.step !== 3 || !this.keyFocused) { return; }
    const ui = this.getUIContext();
    const input = ui.getComponentUtils().getRectangleById('onboarding-inline-key');
    const viewport = ui.getComponentUtils().getRectangleById('onboarding-connection-scroll');
    const inset = ui.vp2px(8);
    const top = viewport.windowOffset.y + inset;
    const bottom = viewport.windowOffset.y + viewport.size.height - inset;
    const delta = input.windowOffset.y < top ? input.windowOffset.y - top :
      Math.max(0, input.windowOffset.y + input.size.height - bottom);
    if (delta !== 0) { this.connectionScroller.scrollBy(0, ui.px2vp(delta)); }
  }

  private connectProvider(preset: string): void {
    if (this.saving || this.busy || this.transitioning || !this.active) { return; }
    this.error = '';
    try { this.onConnect(preset); }
    catch (error) { this.error = (error as Error).message; }
  }

  private statusTitle(): string {
    if (this.providerEditing) {
      return this.keyFocused ? t('你来填密钥，我先回避一下。') : t('填写连接信息，让 Tiny 准备好。');
    }
    return this.configured ? t('模型已配置') : t('连接模型后，就能开始聊天。');
  }

  private selectTask(index: number): void {
    if (this.transitioning) { return; }
    const tasks = onboardingTasks();
    if (index < 0 || index >= tasks.length) { return; }
    this.error = '';
    this.animate((): void => {
      this.selectedTask = index;
      this.message = tasks[index].prompt;
    }, Motion.fast);
  }

  private onMessageChange(value: string): void {
    this.message = value;
    if (this.error.length > 0) { this.error = ''; }
    const tasks = onboardingTasks();
    if (this.selectedTask >= 0 && this.selectedTask < tasks.length && value !== tasks[this.selectedTask].prompt) {
      this.selectedTask = -1;
    }
  }

  private taskSelectionChanged(index: number, selected: boolean): void {
    if (this.transitioning) { return; }
    if (selected) { this.selectTask(index); }
    else if (this.selectedTask === index) { this.selectedTask = -1; }
  }

  private currentPrompt(): string {
    return this.message.trim();
  }

  private actorMood(): string {
    if (this.step === 0) { return this.account.signedIn ? 'proud' : 'curious'; }
    if (this.step === 1) { return this.waking ? 'surprised' : 'sleepy'; }
    if (this.step === 2) { return this.greeted ? 'proud' : 'happy'; }
    if (this.step === 3) { return this.configured ? 'proud' : 'curious'; }
    return this.message.trim().length > 0 ? 'happy' : 'curious';
  }

  private greetActor(): void {
    if (!this.active || !this.foreground || this.transitioning || this.saving) { return; }
    if (this.step === 1) { this.wake(); }
    else {
      this.animate(() => { this.greeted = !this.greeted; });
    }
  }

  private stageChanged(area: Area): void {
    this.stageLeft = Number(area.globalPosition.x);
    this.stageTop = Number(area.globalPosition.y);
    this.stageWidth = Number(area.width);
    this.bodyHeight = Number(area.height);
    if (this.actorArea && this.actorScene === this.step) { this.locateActor(this.step, this.actorArea); }
    this.keepKeyVisible();
  }

  private locateActor(scene: number, area: Area): void {
    if (scene !== this.step) { return; }
    this.actorArea = area;
    this.actorScene = scene;
    if (this.stageWidth <= 0) { return; }
    if (scene === 3 && this.keyFocused) {
      this.placeActor(this.stageWidth / 2, 48, 96, true);
      return;
    }
    const size = Number(area.width);
    // Other scenes centre Tiny; the final task anchors it beside the prompt.
    const x = scene === 4 ? Number(area.globalPosition.x) - this.stageLeft + size / 2 : this.stageWidth / 2;
    const y = Number(area.globalPosition.y) - this.stageTop + Number(area.height) / 2;
    this.placeActor(x, y, size, true);
  }

  private placeActor(x: number, y: number, size: number, smooth: boolean): void {
    if (size <= 0 || (this.actorReady && Math.abs(x - this.actorX) < 0.5 &&
      Math.abs(y - this.actorY) < 0.5 && Math.abs(size - this.actorSize) < 0.5)) { return; }
    const change = (): void => {
      this.actorX = x; this.actorY = y; this.actorSize = size; this.actorReady = true;
    };
    if (this.actorReady && smooth && this.appearance.effectStrength > 0 && this.active && this.foreground) {
      this.getUIContext().animateTo({ duration: 420, curve: Motion.standard }, change);
    } else { change(); }
  }

  private followActorScroll(scene: number, id: string): void {
    if (scene !== this.step || this.actorScene !== scene || !this.actorReady) { return; }
    if (scene === 3 && this.keyFocused) {
      this.placeActor(this.stageWidth / 2, 48, 96, false);
      return;
    }
    const ui = this.getUIContext();
    const rect = ui.getComponentUtils().getRectangleById(id);
    const size = ui.px2vp(rect.size.width);
    const x = scene === 4 ? ui.px2vp(rect.windowOffset.x) - this.stageLeft + size / 2 : this.stageWidth / 2;
    const y = ui.px2vp(rect.windowOffset.y + rect.size.height / 2) - this.stageTop;
    this.placeActor(x, y, size, false);
  }

  @Builder
  actorSlot(scene: number, size: number) {
    Column().width(size).height(size).id('onboarding-actor-slot-' + scene)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .onAreaChange((_old: Area, area: Area) => this.locateActor(scene, area))
  }

  @Builder
  persistentActor() {
    Column() {
      OnboardingMascot({ diameter: 220, scene: this.step,
        mood: this.actorMood(), greeted: this.step !== 1 && this.greeted,
        sleepy: this.step === 1, waking: this.step === 1 && this.waking, energized: this.step !== 1,
        lookX: this.step === 3 ? this.providerLookX() : 0,
        lookY: this.step === 3 && this.selectedPreset.length > 0 ? 4 : 0,
        coverEyes: this.step === 3 && this.keyFocused && this.active && this.foreground,
        connected: this.configured && !this.providerEditing,
        allowDrag: this.step === 2 && !this.transitioning,
        active: this.active && this.foreground && this.actorReady,
        onHello: () => this.greetActor() })
    }.id('onboarding-persistent-actor').width(220).height(220)
      .scale({ x: this.actorSize / 220, y: this.actorSize / 220 })
      .position({ x: this.actorX - 110, y: this.actorY - 110 })
      .opacity(this.actorReady ? 1 : 0)
  }

  @Builder
  header() {
    Row({ space: 6 }) {
      if (this.step > 0) {
        // Toggle supports native material in the content area. This is a momentary navigation action.
        Toggle({ type: ToggleType.Button, isOn: false }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([this.ink()])
        }
        .id('onboarding-back').width(44).height(44).backgroundColor(Color.Transparent)
        .padding(0).borderRadius(22).selectedColor(Color.Transparent)
        .systemMaterial(this.appearance.control)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText(t('上一步')).enabled(!this.saving).onClick(() => this.move(-1))
        Text(this.sceneLabel()).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor(this.muted())
          .margin({ left: 4 }).layoutWeight(1).maxLines(1)
      } else {
        Blank().layoutWeight(1)
      }
      Button(t('跳过引导'), { type: ButtonType.Capsule, stateEffect: true })
        .id('onboarding-skip').height(44).padding({ left: 14, right: 14 })
        .backgroundColor(Color.Transparent).fontFamily(this.appearance.fontFamily).fontSize(13)
        .fontColor(this.muted()).enabled(!this.saving)
        .accessibilityText(t('跳过第一次使用引导')).onClick(() => this.finish('skip'))
    }
    .width('100%').height(52)
  }

  @Builder
  accountScene() {
    Column({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        this.actorSlot(0, 132)
      }.width('100%').height(144)
      Text(this.account.signedIn ? t('已登录华为账号') : t('登录华为账号'))
        .id('onboarding-account-status').fontFamily(this.appearance.fontFamily).fontSize(21)
        .fontWeight(FontWeight.Bold).fontColor(this.ink()).textAlign(TextAlign.Center)
      Text(!this.account.ready ? t('正在确认登录状态，请稍候。') : this.account.signedIn ?
        t('登录状态已确认，可以继续。') : t('根据监管需要，须登录以使用AI生成功能。\n我们承诺不会收集任何隐私信息至Tinybot服务器。'))
        .fontFamily(this.appearance.fontFamily).fontSize(14).lineHeight(21).fontColor(this.muted())
        .textAlign(TextAlign.Center).width('100%').padding({ left: 8, right: 8 })
      if (this.account.error.length > 0) {
        Banner({ text: this.account.error, compId: 'onboarding-account-error' })
      }
      if (this.account.signedIn) {
        Text(t('仅在本机安全保存华为账号标识，不获取姓名、手机号或身份证号。退出登录不会删除本地会话和文件。'))
          .fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(18).fontColor(this.muted())
          .textAlign(TextAlign.Center).width('100%').padding({ left: 8, right: 8 })
      } else {
        Row({ space: 10 }) {
          Checkbox().id('onboarding-account-consent').select(this.agreed)
            .selectedColor(this.brand()).enabled(!this.account.busy)
            .accessibilityText(t('我已阅读并同意用户协议和隐私政策'))
            .onChange((value: boolean) => { this.agreed = value; if (value) { this.error = ''; } })
          Text() {
            Span(t('我已阅读并同意'))
            Span(t('用户协议')).fontColor(this.brandInk())
              .decoration({ type: TextDecorationType.Underline })
              .onClick(() => this.onLegal('terms'))
            Span(t('和'))
            Span(t('隐私政策')).fontColor(this.brandInk())
              .decoration({ type: TextDecorationType.Underline })
              .onClick(() => this.onLegal('privacy'))
          }.id('onboarding-account-agreement').fontFamily(this.appearance.fontFamily)
            .fontSize(13).lineHeight(19).fontColor(this.ink()).layoutWeight(1).enabled(!this.account.busy)
        }.width('100%').padding({ left: 2, right: 2 })
      }
    }.width('100%').constraintSize({ minHeight: this.bodyHeight }).justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
  }

  @Builder
  wakeScene() {
    Column() {
      Blank()
      Column() {
        this.actorSlot(1, this.wakeDiameter())
      }.id('onboarding-wake-tile').width(this.wakeTileSize()).height(this.wakeTileSize())
        .justifyContent(FlexAlign.Center).backgroundColor(this.bubble()).borderRadius(this.wakeTileSize() * 0.24)
        .shadow({ radius: 30, color: this.appearance.accentGlow, offsetY: 8 })
        .accessibilityGroup(true).accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText(this.waking ? t('Tiny 正在醒来') : t('轻点叫醒 Tiny'))
        .onClick(() => this.wake())
      Blank()
    }.width('100%').layoutWeight(1)
  }

  @Builder
  introductionScene() {
    OnboardingIntroduction({ active: this.active && this.foreground && this.step === 2,
      bodyHeight: this.bodyHeight, onActorArea: (area: Area) => this.locateActor(2, area) })
  }

  @Builder
  connectionScene() {
    Column({ space: 14 }) {
      Text(this.statusTitle()).id('onboarding-provider-status').fontFamily(this.appearance.fontFamily)
        .fontSize(this.keyFocused ? 14 : 18).fontWeight(FontWeight.Medium).fontColor(this.ink()).textAlign(TextAlign.Center)
        .width('100%').padding(this.keyFocused ? 10 : 18).backgroundColor(this.bubble()).borderRadius(20)
        .shadow({ radius: 14, color: this.dark ? '#33000000' : '#14000000', offsetY: 6 })
      this.actorSlot(3, this.connectionDiameter())
      Row({ space: 10 }) {
        ForEach(onboardingProviders(), (provider: OnboardingProvider) => {
          Toggle({ type: ToggleType.Button, isOn: this.selectedPreset === provider.preset }) {
            Column({ space: 12 }) {
              if (monochromeProviderLogo(provider.preset)) {
                Image(providerLogo(provider.preset)).width(30).height(30).objectFit(ImageFit.Contain).fillColor(this.ink())
              } else {
                Image(providerLogo(provider.preset)).width(30).height(30).objectFit(ImageFit.Contain)
              }
              Text(provider.name).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor(this.ink()).maxLines(1)
            }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          }.id('onboarding-provider-' + provider.preset).layoutWeight(1).height(104).padding(8)
            .borderRadius(18)
            .backgroundColor(this.selectedPreset === provider.preset ? this.brandSoft() : this.bubble())
            .selectedColor(this.brandSoft())
            .systemMaterial(this.appearance.control)
            .border({ width: this.selectedPreset === provider.preset ? 2 : 1,
              color: this.selectedPreset === provider.preset ? this.brand() : Color.Transparent, radius: 18 })
            .accessibilityText(t('选择 {0}', [provider.name]))
            .accessibilityDescription(this.selectedPreset === provider.preset ? t('已选择') : '')
            .enabled(!this.saving && !this.busy)
            .onChange((selected: boolean) => this.providerSelectionChanged(provider.preset, selected))
        }, (provider: OnboardingProvider) => provider.preset)
      }.width('100%').margin({ top: 6 })
      ForEach(this.providerEditing ? [this.selectedPreset] : [], (preset: string) => {
        OnboardingProviderForm({ editor: this.app.providerEditor, locked: this.saving || this.busy,
          attempted: this.connectionAttempted, onKeyFocus: (focused: boolean) => this.setKeyFocused(focused),
          onError: (message: string) => { this.error = message; } })
          .transition(this.appearance.effectStrength > 0 ? Motion.rise(0, 12) : TransitionEffect.IDENTITY)
      }, (preset: string) => preset)
      Text(t('消息和附件会发送给你选择的服务商。')).fontFamily(this.appearance.fontFamily).fontSize(12)
        .lineHeight(18).fontColor(this.muted()).textAlign(TextAlign.Center).width('100%')
    }.width('100%').constraintSize({ minHeight: this.bodyHeight })
      .justifyContent(this.providerEditing ? FlexAlign.Start : FlexAlign.Center)
      .padding({ top: this.providerEditing ? 8 : 18, bottom: 18 })
  }

  @Builder
  taskScene() {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        this.actorSlot(4, 64)
        Text(t('想先做点什么？')).fontFamily(this.appearance.fontFamily).fontSize(15).lineHeight(23)
          .fontColor(this.ink()).layoutWeight(1).padding(14).backgroundColor(this.bubble())
          .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 5, bottomRight: 18 })
      }.width('100%')
      Column({ space: 10 }) {
        ForEach(onboardingTasks(), (task: OnboardingTask, index: number) => {
          Toggle({ type: ToggleType.Button, isOn: this.selectedTask === index }) {
            Text(task.title).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor(this.brandInk())
          }
            .id('onboarding-task-' + index).height(44).padding({ left: 18, right: 18 })
            .borderRadius(24)
            .backgroundColor(this.selectedTask === index ? this.brandSoft() : this.bubble())
            .selectedColor(this.brandSoft())
            .systemMaterial(this.appearance.control)
            .border({ width: 1, color: this.brandInk(), radius: 24 })
            .accessibilityText(t('选择建议：{0}', [task.title]))
            .accessibilityDescription(this.selectedTask === index ? t('已选择') : task.preview)
            .onChange((selected: boolean) => this.taskSelectionChanged(index, selected))
        }, (task: OnboardingTask) => task.icon)
      }.width('100%').alignItems(HorizontalAlign.End)
      TextArea({ text: this.message, placeholder: t('写下你想先做的事…') })
        .id('onboarding-message-input').fontFamily(this.appearance.fontFamily).fontSize(14)
        .fontColor(this.ink()).placeholderColor(this.faint()).backgroundColor(this.bubble())
        .border({ width: 1, color: this.line(), radius: 18 }).height(96).padding(14).maxLength(500)
        .accessibilityText(t('第一条消息草稿，可编辑')).onChange((value: string) => this.onMessageChange(value))
    }.width('100%').padding({ top: 20, bottom: 18 })
  }

  @Builder
  footer() {
    Column({ space: 8 }) {
      if (this.error.length > 0) {
        Banner({ text: this.error, compId: 'onboarding-error' })
      }
      if (this.step === 0) {
        if (this.account.signedIn) {
          Blank().height(44)
        } else {
          Row({ space: 12 }) {
            Button(t('稍后登录'), { type: ButtonType.Capsule, stateEffect: true })
              .id('onboarding-account-later').height(44).padding({ left: 12, right: 12 })
              .backgroundColor(Color.Transparent).fontFamily(this.appearance.fontFamily).fontSize(12)
              .fontColor(this.muted()).enabled(!this.saving && !this.account.busy)
              .accessibilityText(t('稍后登录')).onClick(() => this.move(1))
          }.width('100%').justifyContent(FlexAlign.Center)
        }
      } else if (this.step === 1) {
        Text(this.wakeReady ? t('Tiny 醒了，继续认识它吧。') : this.waking ? t('它正在慢慢醒来…') : t('轻点，叫醒它'))
          .id('onboarding-wake-hint').fontFamily(this.appearance.fontFamily).fontSize(14)
          .fontColor(this.muted()).height(44).textAlign(TextAlign.Center).width('100%')
      } else if (this.step === 3) {
        Row({ space: 12 }) {
          Button(t('添加其他服务'), { type: ButtonType.Capsule, stateEffect: true })
            .id('onboarding-more-services').height(44).padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent).fontFamily(this.appearance.fontFamily).fontSize(12)
            .fontColor(this.brandInk()).enabled(!this.saving && !this.busy)
            .accessibilityText(t('添加其他模型服务')).onClick(() => this.connectProvider(''))
          if (!this.configured) {
            Button(t('暂不连接，先逛逛'), { type: ButtonType.Capsule, stateEffect: true })
              .id('onboarding-explore').height(44).padding({ left: 12, right: 12 })
              .backgroundColor(Color.Transparent).fontFamily(this.appearance.fontFamily).fontSize(12)
              .fontColor(this.muted()).enabled(!this.saving)
              .accessibilityText(t('暂不连接，先继续浏览')).onClick(() => this.move(1))
          }
        }
        .width('100%').justifyContent(FlexAlign.Center)
      } else if (this.step === 4) {
        Text(t('只准备草稿，由你发送。')).fontFamily(this.appearance.fontFamily).fontSize(12)
          .fontColor(this.muted()).height(44).textAlign(TextAlign.Center).width('100%')
      } else {
        Blank().height(44)
      }
      if (!(this.step === 1 && !this.wakeReady)) {
        // Like the chat's scroll-to-latest action, use a momentary Toggle with button accessibility semantics.
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text(this.primaryLabel()).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.primaryAvailable() ? this.appearance.onAccent : this.muted())
        }
          .id('onboarding-next').borderRadius(24).padding(0)
          .height(48).width('100%').clickEffect(this.appearance.effectStrength > 0 ? null : Motion.press)
          .backgroundColor(this.primaryAvailable() ? this.appearance.accent : this.disabledFill())
          .selectedColor(this.primaryAvailable() ? this.appearance.accent : this.disabledFill())
          .systemMaterial(this.primaryAvailable() ? this.appearance.accentControl : uiMaterial.Material.empty)
          .enabled(this.primaryAvailable())
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .accessibilityText(this.primaryLabel())
          .onClick(() => this.primaryAction())
      } else {
        Blank().height(48)
      }
    }
    .width('100%').padding({ top: 8, bottom: 8 })
  }

  build() {
    Column({ space: 0 }) {
      this.header()
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach([this.step], (scene: number) => {
          Column() {
            if (scene === 1) {
              this.wakeScene()
            } else if (scene === 3) {
              if (this.keyFocused) { Blank().height(96).width('100%') }
              Scroll(this.connectionScroller) { this.connectionScene() }
                .id('onboarding-connection-scroll').layoutWeight(1).width('100%').align(Alignment.Top)
                .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
                .onAreaChange(() => this.keepKeyVisible())
                .onDidScroll(() => this.followActorScroll(3, 'onboarding-actor-slot-3'))
            } else {
              Scroll() {
                if (scene === 0) {
                  this.accountScene()
                } else if (scene === 2) {
                  this.introductionScene()
                } else {
                  this.taskScene()
                }
              }
              .height('100%').width('100%').align(Alignment.Top)
              .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
              .onDidScroll(() => this.followActorScroll(scene, 'onboarding-actor-slot-' + scene))
            }
          }
          .width('100%').height('100%').enabled(scene === this.step)
          .transition(this.sceneTransition())
        }, (scene: number) => scene.toString())
        // Tiny outlives every keyed scene; only its measured destination changes.
        this.persistentActor()
      }
      .width('100%').layoutWeight(1).clip(true)
      .onAreaChange((_old: Area, area: Area) => this.stageChanged(area))
      this.footer()
    }
    .id('onboarding-panel').width('100%').height('100%')
    .padding({ left: 24, right: 24, top: 8, bottom: 4 })
    .backgroundColor(this.page())
  }
}
