import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ChatPanel } from '../views/ChatPanel';
import { SettingsPanel, SystemPromptPanel } from '../views/SettingsPanel';
import { ThreadList } from '../views/ThreadList';
import { ProviderEditorPanel } from '../views/ProviderEditorPanel';
import { ModelPickerPanel } from '../views/ModelPickerPanel';
import { SkillsPanel } from '../views/SkillsPanel';
import { SkillEditorPanel } from '../views/SkillEditorPanel';
import { SessionService } from '../services/SessionService';
import { createNativeSessionService } from '../services/NativeSessionService';
import { Btn, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';

const DRAWER_MAX_WIDTH: number = 340;

@Entry
@Component
struct Index {
  @State private app: ChatViewModel = new ChatViewModel();
  @State private drawerOpen: boolean = false;
  @State private drawerDrag: number = 0;
  @State private drawerWidth: number = DRAWER_MAX_WIDTH;
  private paths: NavPathStack = new NavPathStack();
  private session?: SessionService;

  onPageShow(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!this.session) { this.session = createNativeSessionService(context.filesDir, context.getApplicationContext().filesDir); }
    this.app.initialize(this.session);
  }

  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.setDrawer(false);
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.app.stop();
    this.app.flushDraft();
    this.app.providerEditor.apiKey = '';
  }

  private setDrawer(open: boolean): void {
    if (open) { this.getUIContext().getFocusController().clearFocus(); }
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.drawerOpen = open;
      this.drawerDrag = 0;
    });
  }

  private openSettings(): void {
    this.app.openSettings();
    this.paths.pushPath({ name: 'settings' });
  }

  @Builder
  destination(name: string) {
    if (name === 'settings') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings,
          onSkills: () => { this.paths.pushPath({ name: 'skills' }); },
          onPrompt: () => { this.paths.pushPath({ name: 'prompt' }); },
          onEditProvider: (id: string, preset: string) => {
            this.app.beginProvider(preset, id);
            this.paths.pushPath({ name: 'provider' });
          } })
      }.title('设置').backgroundColor($r('app.color.page_background'))
    } else if (name === 'prompt') {
      NavDestination() {
        SystemPromptPanel({ app: this.app, settings: this.app.settings, onSaved: () => { this.paths.pop(); } })
      }.title('系统提示').backgroundColor($r('app.color.page_background'))
        .onHidden(() => { this.app.settings.systemPrompt = this.app.config.systemPrompt; })
    } else if (name === 'skills') {
      NavDestination() {
        SkillsPanel({ app: this.app, onEdit: (skill: string) => {
          this.app.beginSkill(skill);
          this.paths.pushPath({ name: 'skill-editor' });
        }, onUse: () => { this.paths.clear(); } })
      }.title('Skills').backgroundColor($r('app.color.page_background'))
    } else if (name === 'skill-editor') {
      NavDestination() {
        SkillEditorPanel({ app: this.app, editor: this.app.skillEditor, onSaved: () => { this.paths.pop(); } })
      }.title(this.app.skillEditor.originalName.length > 0 ? '编辑 Skill' : '添加 Skill').backgroundColor($r('app.color.page_background'))
    } else if (name === 'provider') {
      NavDestination() {
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, onSaved: () => { this.paths.pop(); } })
      }.title(this.app.providerEditor.id.length > 0 ? '编辑服务' : '添加服务').backgroundColor($r('app.color.page_background'))
        .onHidden(() => { this.app.providerEditor.apiKey = ''; })
    } else if (name === 'models') {
      NavDestination() {
        ModelPickerPanel({ app: this.app, onSelected: () => { this.paths.pop(); }, onSettings: () => this.openSettings() })
      }.title('选择模型').backgroundColor($r('app.color.page_background'))
    }
  }

  @Builder
  header() {
    Row({ space: 4 }) {
      IconButton({ icon: $r('sys.symbol.line_3_horizontal'), label: '对话列表', compId: 'open-history',
        disabled: !this.app.ready, onTap: () => this.setDrawer(true) })
      Column({ space: 1 }) {
        Text(this.app.ready ? this.app.active.title : 'Tinybot').fontSize(16).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Row({ space: 2 }) {
          Text(this.app.ready ? this.app.currentModelLabel : '你的随身 AI 助手').fontSize(12).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
            .fontColor(this.app.ready && !this.app.configured ? $r('app.color.danger') : $r('app.color.text_secondary'))
          if (this.app.ready) {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }
        }.justifyContent(FlexAlign.Center).constraintSize({ maxWidth: '100%' })
      }
      .id('open-model-picker').layoutWeight(1).padding({ top: 4, bottom: 4 }).borderRadius(12)
      .accessibilityText('切换模型：' + this.app.currentModelLabel)
      .enabled(this.app.ready && !this.app.busy && !this.app.active.archived)
      .onClick(() => { this.paths.pushPath({ name: 'models' }); })
      IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: '新建对话', compId: 'new-chat',
        disabled: !this.app.ready || this.app.busy || this.app.saveError.length > 0,
        onTap: () => { this.app.newThread(); } })
    }.width('100%').height(56).padding({ left: 6, right: 6 })
  }

  @Builder
  drawer() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width('100%').height('100%').backgroundColor($r('app.color.scrim'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .opacity(Math.max(0, 1 + this.drawerDrag / this.drawerWidth))
        .transition(TransitionEffect.OPACITY)
        .onClick(() => this.setDrawer(false))
      Stack() {
        Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
          .borderRadius({ topRight: 20, bottomRight: 20 })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        ThreadList({ app: this.app, onSelected: () => this.setDrawer(false), onSettings: () => {
          this.setDrawer(false);
          this.openSettings();
        } })
      }
      .width('84%').constraintSize({ maxWidth: DRAWER_MAX_WIDTH }).height('100%')
      .translate({ x: this.drawerDrag })
      .transition(TransitionEffect.translate({ x: -DRAWER_MAX_WIDTH }))
      .onAreaChange((_old: Area, next: Area) => { this.drawerWidth = Math.max(1, next.width as number); })
      .gesture(PanGesture({ direction: PanDirection.Horizontal })
        .onActionUpdate((event: GestureEvent) => { this.drawerDrag = Math.min(0, event.offsetX); })
        .onActionEnd(() => {
          if (this.drawerDrag < -this.drawerWidth / 4) {
            this.setDrawer(false);
          } else {
            this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => { this.drawerDrag = 0; });
          }
        }))
    }.width('100%').height('100%')
  }

  build() {
    Navigation(this.paths) {
      Stack() {
        Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        Column() {
          this.header()
          if (this.app.ready) {
            ChatPanel({ app: this.app, thread: this.app.active, onSettings: () => this.openSettings() })
              .layoutWeight(1)
          } else {
            Column({ space: Space.lg }) {
              if (this.app.loading) {
                LoadingProgress().width(32).height(32).color($r('app.color.accent'))
                Text('正在打开本地会话…').fontColor($r('app.color.text_secondary'))
              } else {
                Text(this.app.error).fontColor($r('app.color.danger')).textAlign(TextAlign.Center)
                Button('重试读取').attributeModifier(Btn.tonal).onClick(() => this.onPageShow())
              }
            }.padding(Space.xl).layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
          }
        }.width('100%').height('100%')
        if (this.drawerOpen) {
          this.drawer()
        }
      }.width('100%').height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    .hideTitleBar(true).hideToolBar(true).mode(NavigationMode.Stack)
    .navDestination(this.destination).width('100%').height('100%')
  }
}
