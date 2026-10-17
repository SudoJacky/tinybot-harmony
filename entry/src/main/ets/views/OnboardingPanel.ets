import { uiMaterial } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { monochromeProviderLogo, providerLogo } from '../common/ProviderBrand';
import { OnboardingProvider, OnboardingTask, onboardingProviders, onboardingTasks } from '../model/Onboarding';
import { OnboardingMascot } from './OnboardingMascot';
import { OnboardingCapability } from './OnboardingCapability';
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
  onFinish: (action: string, prompt: string) => Promise<void> = async () => {};
  onConnect: (preset: string) => void = () => {};
  @State private step: number = 0;
  @State private greeted: boolean = false;
  @State private selectedPreset: string = '';
  @State private selectedTask: number = -1;
  @State private message: string = '';
  @State private capIndex: number = 0;
  @State private saving: boolean = false;
  @State private error: string = '';
  @State private waking: boolean = false;
  @State private wakeReady: boolean = false;
  @State private wakeScale: number = 1;
  @State private bodyHeight: number = 560;
  @State private pageDirection: number = 1;
  @State private transitioning: boolean = false;
  @State private actorReady: boolean = false;
  @State private actorX: number = 0;
  @State private actorY: number = 0;
  @State private actorSize: number = 180;
  @State private demoTick: number = 0;
  @State private demoRevealed: boolean = false;
  private stageLeft: number = 0;
  private stageTop: number = 0;
  private stageWidth: number = 0;
  private actorScene: number = -1;
  private actorArea?: Area;
  private transitionRevision: number = 0;
  private wakeTimer: number = -1;
  private mounted: boolean = false;
  private capController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    this.mounted = true;
    if (this.configured && this.connectedPreset.length > 0) { this.selectedPreset = this.connectedPreset; }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.cancelWake(false);
    this.settleTransition();
  }

  private activeChanged(): void {
    if (!this.active) { this.cancelWake(true); this.settleTransition(); }
  }

  private foregroundChanged(): void {
    if (!this.foreground) { this.cancelWake(true); this.settleTransition(); }
  }

  private connectionChanged(): void {
    if (this.configured && this.connectedPreset.length > 0) { this.selectedPreset = this.connectedPreset; }
    this.error = '';
  }

  private animate(action: () => void, duration: number = Motion.medium): void {
    if (this.appearance.effectStrength > 0) {
      this.getUIContext().animateTo({ duration: duration, curve: Motion.standard }, action);
    } else {
      action();
    }
  }

  // Scene zero has one pending timer. Hidden/covered/backgrounded routes keep the
  // wake result as an explicit Continue instead of navigating behind the user's back.
  private cancelWake(showContinue: boolean): void {
    if (this.wakeTimer >= 0) {
      clearTimeout(this.wakeTimer);
      this.wakeTimer = -1;
    }
    if (showContinue && this.waking && this.step === 0) { this.wakeReady = true; }
  }

  private wake(): void {
    if (this.step !== 0 || !this.active || !this.foreground || this.saving || this.waking) { return; }
    this.error = '';
    this.wakeReady = false;
    this.waking = true;
    this.animate((): void => { this.wakeScale = 1.04; }, Motion.fast);
    this.wakeTimer = setTimeout(() => {
      this.wakeTimer = -1;
      if (!this.mounted) { return; }
      if (this.step !== 0 || !this.active || !this.foreground) { this.wakeReady = true; return; }
      this.wakeScale = 1;
      this.move(1);
    }, 350);
  }

  private continueWake(): void {
    if (this.step !== 0 || !this.active || !this.foreground || this.saving) { return; }
    this.cancelWake(false);
    this.wakeReady = false;
    this.waking = false;
    this.wakeScale = 1;
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
      this.greeted = false;
      this.demoRevealed = false;
      this.waking = false;
      this.wakeReady = false;
      this.wakeScale = 1;
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
    if (this.step === 0) { return t('第一次见面'); }
    if (this.step === 1) { return t('认识 Tiny'); }
    if (this.step === 2) { return t('连接模型'); }
    if (this.step === 3) { return t('Tiny 能做什么'); }
    return t('第一个任务');
  }

  private primaryLabel(): string {
    if (this.step === 0) { return t('继续'); }
    if (this.step === 1) { return t('继续'); }
    if (this.step === 2) {
      if (this.configured) { return t('继续'); }
      if (this.selectedPreset === 'ollama') { return t('连接模型'); }
      return this.selectedPreset.length > 0 ? t('填写 API Key') : t('选择服务商');
    }
    if (this.step === 3) { return t('试着聊一句'); }
    return t('带进聊天');
  }

  private primaryEnabled(): boolean {
    return !this.transitioning && this.primaryAvailable();
  }

  private primaryAvailable(): boolean {
    if (this.saving || !this.active || !this.foreground) { return false; }
    if (this.step === 0) { return this.wakeReady && this.active && this.foreground; }
    if (this.step === 2) {
      return this.configured ? true : (!this.busy && this.selectedPreset.length > 0);
    }
    if (this.step === 4) { return !this.busy && this.message.trim().length > 0; }
    return true;
  }

  private primaryAction(): void {
    if (!this.primaryEnabled()) { return; }
    if (this.step === 0) { this.continueWake(); return; }
    if (this.step === 2) {
      if (this.configured) { this.move(1); } else { this.connectSelected(); }
      return;
    }
    if (this.step === 4) { this.finish('start', this.currentPrompt()); return; }
    this.move(1);
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
    if (this.saving || this.transitioning) { return; }
    this.error = '';
    this.animate((): void => { this.selectedPreset = preset; }, Motion.fast);
  }

  private providerSelectionChanged(preset: string, selected: boolean): void {
    // Synchronizing the previous Toggle to off can emit after the new choice's on event.
    if (selected || this.selectedPreset === preset) { this.selectProvider(selected ? preset : ''); }
  }

  private connectSelected(): void {
    if (this.saving || this.busy || this.transitioning || !this.active) { return; }
    if (this.selectedPreset.length === 0) {
      this.error = t('先选择一个模型服务。');
      return;
    }
    // This is a real provider editor hand-off. Onboarding is completed later,
    // only after the user explicitly finishes the first-task scene.
    this.connectProvider(this.selectedPreset);
  }

  private connectProvider(preset: string): void {
    if (this.saving || this.busy || this.transitioning || !this.active) { return; }
    this.error = '';
    try { this.onConnect(preset); }
    catch (error) { this.error = (error as Error).message; }
  }

  private statusTitle(): string {
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

  private showCapability(index: number): void {
    if (this.transitioning || index < 0 || index > 2) { return; }
    this.capabilityChanged(index);
    this.capController.changeIndex(index);
  }

  private capabilityChanged(index: number): void {
    if (index === this.capIndex) { return; }
    this.animate(() => { this.demoRevealed = false; this.capIndex = index; }, Motion.fast);
  }

  private actorMood(): string {
    if (this.step === 0) { return this.waking ? 'surprised' : 'sleepy'; }
    if (this.step === 1) { return this.greeted ? 'proud' : 'happy'; }
    if (this.step === 2) { return this.configured ? 'proud' : 'curious'; }
    if (this.step === 3) {
      if (this.demoRevealed || this.capIndex === 2) { return 'proud'; }
      return this.capIndex === 1 ? 'focused' : 'curious';
    }
    return this.message.trim().length > 0 ? 'happy' : 'curious';
  }

  private greetActor(): void {
    if (!this.active || !this.foreground || this.transitioning || this.saving) { return; }
    if (this.step === 0) { this.wake(); }
    else {
      this.animate(() => {
        if (this.step === 3) { this.demoRevealed = !this.demoRevealed; this.demoTick++; }
        else { this.greeted = !this.greeted; }
      });
    }
  }

  private stageChanged(area: Area): void {
    this.stageLeft = Number(area.globalPosition.x);
    this.stageTop = Number(area.globalPosition.y);
    this.stageWidth = Number(area.width);
    this.bodyHeight = Number(area.height);
    if (this.actorArea && this.actorScene === this.step) { this.locateActor(this.step, this.actorArea); }
  }

  private locateActor(scene: number, area: Area): void {
    if (scene !== this.step) { return; }
    this.actorArea = area;
    this.actorScene = scene;
    if (this.stageWidth <= 0) { return; }
    const size = Number(area.width);
    // Swiper cards share a stationary centre; the scenery moves around Tiny.
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
      OnboardingMascot({ diameter: 220, scene: this.step === 3 ? 0 : this.step,
        mood: this.actorMood(), greeted: this.step === 0 ? this.waking : this.greeted || this.demoRevealed,
        sleepy: this.step === 0 && !this.waking, energized: this.step !== 0 || this.waking,
        allowDrag: this.step === 1 && !this.transitioning,
        active: this.active && this.foreground && this.actorReady,
        onHello: () => this.greetActor() })
    }.id('onboarding-persistent-actor').width(220).height(220)
      // The theatre's underlying button and Swiper own the entire gesture chain.
      .hitTestBehavior(this.step === 3 ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.Default)
      .accessibilityLevel(this.step === 3 ? 'no-hide-descendants' : 'auto')
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
      } else {
        Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.ink()).letterSpacing(0.4)
      }
      Text(this.sceneLabel()).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor(this.muted())
        .margin({ left: 4 }).layoutWeight(1).maxLines(1)
      Button(t('跳过'), { type: ButtonType.Capsule, stateEffect: true })
        .id('onboarding-skip').height(44).padding({ left: 14, right: 14 })
        .backgroundColor(Color.Transparent).fontFamily(this.appearance.fontFamily).fontSize(13)
        .fontColor(this.muted()).enabled(!this.saving)
        .accessibilityText(t('跳过第一次使用引导')).onClick(() => this.finish('skip'))
    }
    .width('100%').height(52)
  }

  @Builder
  wakeScene() {
    Column() {
      Blank()
      Column() {
        this.actorSlot(0, this.wakeDiameter())
      }.id('onboarding-wake-tile').width(this.wakeTileSize()).height(this.wakeTileSize())
        .justifyContent(FlexAlign.Center).backgroundColor(this.bubble()).borderRadius(this.wakeTileSize() * 0.24)
        .shadow({ radius: 30, color: this.appearance.accentGlow, offsetY: 8 })
        .scale({ x: this.wakeScale, y: this.wakeScale })
        .accessibilityGroup(true).accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText(this.waking ? t('Tiny 已经醒了') : t('轻点叫醒 Tiny'))
        .onClick(() => this.wake())
      Blank()
    }.width('100%').layoutWeight(1)
  }

  @Builder
  introductionScene() {
    Column({ space: 28 }) {
      Text(t('嗨，我是 Tiny，你的 AI 小助手。'))
        .fontFamily(this.appearance.fontFamily).fontSize(17).lineHeight(25).fontColor(this.ink())
        .width('100%').padding({ left: 18, right: 18, top: 16, bottom: 16 })
        .backgroundColor(this.bubble()).borderRadius(20)
        .shadow({ radius: 18, color: this.dark ? '#33000000' : '#14000000', offsetY: 8 })
      Stack({ alignContent: Alignment.Center }) {
        this.actorSlot(1, 220)
      }
      .width('100%').height(260)
    }
    .width('100%').constraintSize({ minHeight: this.bodyHeight }).justifyContent(FlexAlign.Center)
    .padding({ top: 24, bottom: 24 })
  }

  @Builder
  connectionScene() {
    Column({ space: 14 }) {
      Text(this.statusTitle()).id('onboarding-provider-status').fontFamily(this.appearance.fontFamily)
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.ink()).textAlign(TextAlign.Center)
        .width('100%').padding(18).backgroundColor(this.bubble()).borderRadius(20)
        .shadow({ radius: 14, color: this.dark ? '#33000000' : '#14000000', offsetY: 6 })
      this.actorSlot(2, 160)
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
            .onChange((selected: boolean) => this.providerSelectionChanged(provider.preset, selected))
        }, (provider: OnboardingProvider) => provider.preset)
      }.width('100%').margin({ top: 6 })
      Text(t('消息和附件会发送给你选择的服务商。')).fontFamily(this.appearance.fontFamily).fontSize(12)
        .lineHeight(18).fontColor(this.muted()).textAlign(TextAlign.Center).width('100%')
    }.width('100%').constraintSize({ minHeight: this.bodyHeight }).justifyContent(FlexAlign.Center)
      .padding({ top: 18, bottom: 18 })
  }

  @Builder
  capabilityScene() {
    Column() {
      Swiper(this.capController) {
        ForEach([0, 1, 2], (index: number) => {
          Column() {
            OnboardingCapability({ index: index, demoTick: this.demoTick,
              active: this.active && this.foreground && this.step === 3 && this.capIndex === index,
              onActorArea: (area: Area) => this.locateActor(3, area),
              onActorTap: () => this.greetActor(),
              onActorScroll: (id: string) => this.followActorScroll(3, id) })
          }
          .width('100%').height('100%')
        }, (index: number) => index.toString())
      }
      .id('onboarding-capabilities').width('100%').layoutWeight(1).index(this.capIndex)
      .loop(false).indicator(false).duration(this.appearance.effectStrength > 0 ? 320 : 0)
      .onChange((index: number) => this.capabilityChanged(index))
    }
    .width('100%').layoutWeight(1)
  }

  @Builder
  capabilityDots() {
    Row({ space: 2 }) {
        ForEach([0, 1, 2], (index: number) => {
          Button({ type: ButtonType.Circle, stateEffect: false }) {
            Row().width(this.capIndex === index ? 24 : 7).height(7).borderRadius(4)
              .backgroundColor(this.capIndex === index ? this.brand() : this.line())
          }
          .id('onboarding-cap-dot-' + index)
          .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(t('第 {0} 张能力卡片', [index + 1]))
          .accessibilityDescription(this.capIndex === index ? t('当前') : '')
          .onClick(() => this.showCapability(index))
        }, (index: number) => index.toString())
    }
    .width('100%').height(44).justifyContent(FlexAlign.Center)
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
        Text(this.waking ? t('它醒了。') : t('轻点，叫醒它'))
          .id('onboarding-wake-hint').fontFamily(this.appearance.fontFamily).fontSize(14)
          .fontColor(this.muted()).height(44).textAlign(TextAlign.Center).width('100%')
      } else if (this.step === 2) {
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
      } else if (this.step === 3) {
        this.capabilityDots()
      } else if (this.step === 4) {
        Text(t('只准备草稿，由你发送。')).fontFamily(this.appearance.fontFamily).fontSize(12)
          .fontColor(this.muted()).height(44).textAlign(TextAlign.Center).width('100%')
      } else {
        Blank().height(44)
      }
      if (!(this.step === 0 && !this.wakeReady)) {
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
            if (scene === 0) {
              this.wakeScene()
            } else if (scene === 3) {
              this.capabilityScene()
            } else {
              Scroll() {
                if (scene === 1) {
                  this.introductionScene()
                } else if (scene === 2) {
                  this.connectionScene()
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
