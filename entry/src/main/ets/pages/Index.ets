import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ChatPanel } from '../views/ChatPanel';
import { SettingsPanel } from '../views/SettingsPanel';
import { ThreadList } from '../views/ThreadList';
import { ProviderEditorPanel } from '../views/ProviderEditorPanel';
import { ModelPickerPanel } from '../views/ModelPickerPanel';

@Entry
@Component
struct Index {
  @State private app: ChatViewModel = new ChatViewModel();
  private paths: NavPathStack = new NavPathStack();

  onPageShow(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.app.initialize(context.filesDir, context.getApplicationContext().filesDir);
  }

  aboutToDisappear(): void {
    this.app.stop();
    this.app.flushDraft();
    this.app.providerEditor.apiKey = '';
  }

  private openSettings(): void {
    this.app.openSettings();
    this.paths.pushPath({ name: 'settings' });
  }

  @Builder
  destination(name: string) {
    if (name === 'settings') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings, onEditProvider: (id: string, preset: string) => {
          this.app.beginProvider(preset, id);
          this.paths.pushPath({ name: 'provider' });
        } })
      }.title('模型设置').backgroundColor($r('app.color.page_background'))
    } else if (name === 'provider') {
      NavDestination() {
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, onSaved: () => { this.paths.pop(); } })
      }.title(this.app.providerEditor.id.length > 0 ? '编辑服务' : '添加服务').backgroundColor($r('app.color.page_background'))
        .onHidden(() => { this.app.providerEditor.apiKey = ''; })
    } else if (name === 'models') {
      NavDestination() {
        ModelPickerPanel({ app: this.app, onSelected: () => { this.paths.pop(); }, onSettings: () => this.openSettings() })
      }.title('选择模型').backgroundColor($r('app.color.page_background'))
    } else if (name === 'history') {
      NavDestination() {
        ThreadList({ app: this.app, onSelected: () => { this.paths.pop(); } })
      }.title('我的对话').backgroundColor($r('app.color.page_background'))
    }
  }

  build() {
    Navigation(this.paths) {
      Column() {
        Row({ space: 8 }) {
          Button('对话').id('open-history').fontSize(14).height(44)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
            .enabled(this.app.ready).onClick(() => this.paths.pushPath({ name: 'history' }))
          Column({ space: 2 }) {
            Text('Tinybot').fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            Text('你的随身 AI 助手').fontSize(10).fontColor($r('app.color.text_secondary'))
          }.layoutWeight(1)
          Button('＋').id('new-chat').fontSize(24).width(44).height(44)
            .padding(0)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_primary'))
            .accessibilityText('新建对话').enabled(this.app.ready && !this.app.busy && this.app.saveError.length === 0)
            .onClick(() => this.app.newThread())
          Button('设置').id('open-settings').fontSize(14).height(44)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
            .enabled(this.app.ready).onClick(() => this.openSettings())
        }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 8 })
        if (this.app.ready) {
          ChatPanel({ app: this.app, thread: this.app.active, onSettings: () => this.openSettings(),
            onModels: () => { this.paths.pushPath({ name: 'models' }); } })
            .layoutWeight(1)
        } else {
          Column({ space: 16 }) {
            if (this.app.loading) {
              LoadingProgress().width(32).height(32).color($r('app.color.accent'))
              Text('正在打开本地会话…').fontColor($r('app.color.text_secondary'))
            } else {
              Text(this.app.error).fontColor($r('app.color.danger')).textAlign(TextAlign.Center)
              Button('重试读取').onClick(() => this.onPageShow())
            }
          }.padding(24).layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        }
      }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
    }
    .hideTitleBar(true).hideToolBar(true).mode(NavigationMode.Stack)
    .navDestination(this.destination).width('100%').height('100%')
  }
}
