import { AppearanceStyle } from '../common/AppearanceStyle';
import { TutorialControl, TutorialScreen, TUTORIAL_WIDTH, TUTORIAL_HEIGHT, tutorialRect } from '../model/HelpTutorial';
import { EN_MESSAGES, ZH_MESSAGES } from '../model/LocaleCatalog';
import { SpeechOrb } from '../common/SpeechOrb';
import { Font, Radius } from '../common/Theme';
import { SwitchSize } from '../common/SwitchSize';
import { NavRow } from '../common/Widgets';
import { providerLogo } from '../common/ProviderBrand';

export function tutorialText(key: string, locale: string): string {
  const value = (locale === 'en' ? EN_MESSAGES : ZH_MESSAGES)[key];
  if (value === undefined) { throw new Error('Missing tutorial translation: ' + key); }
  return value;
}

// Reproduce the native pages, using their icons, row widget, colors and control sizes.
// Example content is independent of the user's conversations, services and credentials.
@Component
export struct HelpTutorialScreen {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop screen: TutorialScreen = 'chat';
  @Prop locale: string = 'zh-CN';
  @Prop typing: number = 1;
  @Prop overlayOnly: boolean = false;
  @Prop motion: number = 0;

  private text(key: string): string { return tutorialText(key, this.locale); }

  @Builder
  glyph(icon: Resource, size: number = 20) {
    SymbolGlyph(icon).fontSize(size).fontColor([$r('app.color.text_secondary')])
  }

  @Builder
  card(x: number, y: number, width: number, height: number) {
    Column().width(width).height(height).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
      .position({ x, y })
  }

  @Builder
  heading(title: string, y: number) {
    Text(title).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      .position({ x: 20, y }).width(320).height(32)
  }

  @Builder
  pageTitle(title: string) {
    Row({ space: 8 }) {
      Stack() { this.glyph($r('sys.symbol.chevron_left'), 22) }
        .width(40).height(40).borderRadius(20).border({ width: 0.5, color: $r('app.color.divider') })
      Text(title).fontFamily(this.appearance.fontFamily).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
    }.width(344).height(56).position({ x: 16, y: 24 })
  }

  @Builder
  rowAt(title: string, icon: Resource, y: number, subtitle: string = '', accent: boolean = false) {
    NavRow({ title, subtitle, icon, accent }).width(328).height(subtitle ? 64 : 56).position({ x: 16, y })
  }

  @Builder
  controlRow(control: TutorialControl, title: string, icon: Resource, subtitle: string = '', accent: boolean = false) {
    NavRow({ title, subtitle, icon, accent }).width(tutorialRect(control).width).height(tutorialRect(control).height)
      .position({ x: tutorialRect(control).x, y: tutorialRect(control).y })
  }

  @Builder
  line(y: number) {
    Divider().color($r('app.color.divider')).strokeWidth(0.5).width(312).position({ x: 32, y })
  }

  @Builder
  pill(control: TutorialControl, title: string) {
    Text(title).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.appearance.onAccent)
      .textAlign(TextAlign.Center).backgroundColor(this.appearance.accent).borderRadius(24)
      .width(tutorialRect(control).width).height(tutorialRect(control).height)
      .position({ x: tutorialRect(control).x, y: tutorialRect(control).y })
  }

  @Builder
  chat() {
      Stack() { this.glyph($r('sys.symbol.line_3_horizontal')) }.width(44).height(44).position({ x: 6, y: 28 })
      Column({ space: 1 }) {
        Text(this.text('新对话')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Row({ space: 4 }) {
          Image(providerLogo('deepseek')).width(14).height(14)
          Text(this.screen === 'chat-v4' ? '· deepseek-v4-pro' : '· deepseek-flash').fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
          this.glyph($r('sys.symbol.chevron_down'), 12)
        }
      }.width(202).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).position({ x: 54, y: 28 })
      Stack() { this.glyph($r('sys.symbol.dot_grid_1x2')) }.width(44).height(44).position({ x: 264, y: 28 })
      Stack() { this.glyph($r('sys.symbol.square_and_pencil')) }.width(40).height(44).position({ x: 310, y: 28 })
    if (this.screen === 'answer' || this.screen === 'running' || this.screen === 'error') {
      Text(this.text('帮我把下面的想法整理成可执行的步骤：')).fontFamily(this.appearance.fontFamily).fontSize(16).lineHeight(24)
        .fontColor($r('app.color.text_primary')).padding(14).width(258).borderRadius(18)
        .backgroundColor(this.appearance.userBubble).position({ x: 86, y: 114 })
      Row({ space: 8 }) {
        Image($r('app.media.tinybot')).width(22).height(22)
        Text(this.screen === 'running' ? this.text('生成回答') : this.screen === 'error' ? this.text('连接失败') : 'Tinybot').fontFamily(this.appearance.fontFamily)
          .fontSize(14).fontColor(this.screen === 'error' ? $r('app.color.danger') : $r('app.color.text_secondary'))
      }.position({ x: 20, y: 222 })
      if (this.screen === 'answer') {
        Text(this.text('先给结论，再给必要的例子。')).fontFamily(this.appearance.fontFamily).fontSize(16).lineHeight(25)
          .fontColor($r('app.color.text_primary')).width(312).position({ x: 20, y: 268 })
        Row({ space: 20 }) {
          this.glyph($r('sys.symbol.rectangle_on_rectangle'), 18)
          this.glyph($r('sys.symbol.arrow_clockwise'), 18)
          this.glyph($r('sys.symbol.ellipsis_message'), 18)
        }.position({ x: 20, y: 334 })
      }
    } else {
      Column({ space: 14 }) {
        Image($r('app.media.tinybot')).width(56).height(56)
        Text(this.text('今天想一起做点什么？')).fontFamily(this.appearance.fontFamily).fontSize(Font.headline).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
      }.width(320).position({ x: 20, y: 280 })
    }
    if (this.screen === 'error') {
      Text(this.text('重新编辑并发送')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor(this.appearance.onAccentContainer)
        .width(154).height(32).textAlign(TextAlign.Center).borderRadius(16)
        .backgroundColor(this.appearance.accentContainer).position({ x: 16, y: 598 })
    }
    if (this.screen === 'attachment') {
      Row({ space: 8 }) {
        this.glyph($r('sys.symbol.picture'), 18)
        Text('image.jpg').fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_primary'))
        this.glyph($r('sys.symbol.xmark'), 12)
      }.padding(12).borderRadius(12).backgroundColor($r('app.color.surface')).position({ x: 20, y: 588 })
    }
    if (this.screen === 'team') {
      Row({ space: 8 }) {
        this.glyph($r('sys.symbol.person_2'), 18)
        Text(this.text('团队模式')).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      }.padding(12).borderRadius(22).backgroundColor($r('app.color.surface')).position({ x: 16, y: 580 })
    }
    this.card(16, this.screen === 'draft' ? 584 : 638, 328, this.screen === 'draft' ? 110 : 56)
    Text(this.screen === 'draft' ? this.text('帮我把下面的想法整理成可执行的步骤：')
      .slice(0, Math.ceil(this.typing * this.text('帮我把下面的想法整理成可执行的步骤：').length)) :
      this.screen === 'speech' ? this.text('松开发送') : this.screen === 'voice-ready' ? this.text('按住说话') : this.text('输入消息…')).fontFamily(this.appearance.fontFamily)
      .fontSize(16).fontColor(this.screen === 'draft' ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      .width(this.screen === 'draft' ? 296 : 226).height(48).maxLines(this.screen === 'draft' ? 2 : 1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .position({ x: this.screen === 'draft' ? 32 : 66, y: this.screen === 'draft' ? 590 : 644 })
    if (this.screen === 'draft') {
      Progress({ value: 8, total: 100, type: ProgressType.Ring }).width(16).height(16)
        .color(this.appearance.accent).position({ x: 74, y: 658 })
      Text('8%').fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary')).position({ x: 98, y: 658 })
    }
    Stack() { this.glyph($r('sys.symbol.plus')) }.width(36).height(36).borderRadius(18)
      .backgroundColor($r('app.color.surface_variant')).position({ x: 26, y: 648 })
    Stack() {
      if (this.screen === 'draft' || this.screen === 'running') {
        SymbolGlyph(this.screen === 'running' ? $r('sys.symbol.square_fill') : $r('sys.symbol.arrow_up'))
          .fontSize(18).fontColor([this.appearance.onAccent])
      } else { this.glyph(this.screen === 'speech' || this.screen === 'voice-ready' ? $r('sys.symbol.keyboard') : $r('sys.symbol.mic'), 19) }
    }.width(36).height(36).borderRadius(18)
      .backgroundColor(this.screen === 'draft' || this.screen === 'running' ? this.appearance.accent : $r('app.color.surface_variant'))
      .position({ x: 298, y: 648 })
    if (this.screen === 'speech') {
      Text(this.text('帮我把下面的想法整理成可执行的步骤：')).fontFamily(this.appearance.fontFamily).fontSize(16)
        .fontColor($r('app.color.text_primary')).width(328).padding(14).borderRadius(20)
        .backgroundColor($r('app.color.surface')).position({ x: 16, y: 346 })
      SpeechOrb({ phase: 'listening', speaking: true }).width(160).position({ x: 100, y: 424 })
      Stack() { this.glyph($r('sys.symbol.xmark'), 22) }.width(64).height(48).borderRadius(24)
        .backgroundColor($r('app.color.surface')).position({ x: 32, y: 578 })
      Stack() { this.glyph($r('sys.symbol.square_and_pencil'), 22) }.width(64).height(48).borderRadius(24)
        .backgroundColor($r('app.color.surface')).position({ x: 264, y: 578 })
    }
    Text(this.text('AI生成内容可能有误，请仔细鉴别。')).fontFamily(this.appearance.fontFamily).fontSize(10).fontColor($r('app.color.text_tertiary'))
      .textAlign(TextAlign.Center).width(340).height(20).position({ x: 10, y: 698 })
  }

  @Builder
  menu() {
    this.card(108, 86, 200, 354)
    Text(this.text('本对话')).fontFamily(this.appearance.fontFamily).fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      .position({ x: 124, y: 99 })
    this.menuRow(this.text('工具范围'), $r('sys.symbol.wrench_and_screwdriver'), 132)
    this.menuRow(this.text('工作区文件'), $r('sys.symbol.folder'), 176)
    this.menuRow(this.text('分支关系'), $r('sys.symbol.rectangle_stack'), 220)
    this.menuRow(this.text('创建分支'), $r('sys.symbol.split'), 264)
    this.menuRow(this.text('分享对话'), $r('sys.symbol.share'), 308)
    this.menuRow(this.text('导出为 Markdown'), $r('sys.symbol.square_and_arrow_down'), 352)
    this.menuRow(this.text('设置'), $r('sys.symbol.gearshape'), 396)
  }

  @Builder
  menuRow(title: string, icon: Resource, y: number) {
    Row({ space: 12 }) { this.glyph(icon, 18); Text(title).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_primary')) }
      .width(200).height(44).padding({ left: 16, right: 8 }).position({ x: 108, y })
  }

  @Builder
  switchAt(title: string, y: number, isOn: boolean) {
    Row() {
      Text(title).fontFamily(this.appearance.fontFamily).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn }).width(SwitchSize.width).height(SwitchSize.height)
        .margin({ left: (SwitchSize.touchWidth - SwitchSize.width) / 2,
          right: (SwitchSize.touchWidth - SwitchSize.width) / 2 }).selectedColor(this.appearance.accent)
    }.width(328).height(64).padding({ left: 16, right: 16 }).position({ x: 16, y })
  }

  @Builder
  settings() {
    this.pageTitle(this.text('设置'))
    if (this.screen === 'settings-memory') {
      this.heading(this.text('助手偏好'), 92)
      this.card(16, 132, 328, 192)
      this.controlRow('user-document', this.text('称呼与回答偏好'), $r('sys.symbol.square_and_pencil'), this.text('填写称呼、背景和回答偏好'))
      this.line(196)
      this.rowAt(this.text('提示词模板'), $r('sys.symbol.doc_plaintext'), 196)
      this.line(260)
      this.switchAt(this.text('自动保存任务结果'), 260, false)
      this.heading(this.text('记忆与上下文'), 348)
      this.card(16, 388, 328, 192)
      this.switchAt(this.text('自动提取长期记忆'), 388, true)
      this.line(452)
      this.controlRow('memory', this.text('管理长期记忆'), $r('sys.symbol.lightbulb'), this.text('查看、编辑所有对话或当前对话的记忆'))
      this.line(516)
      this.switchAt(this.text('自动压缩历史'), 516, true)
      this.heading(this.text('工具与权限'), 604)
      this.card(16, 644, 328, 64)
      this.switchAt(this.text('只读模式'), 644, false)
    } else if (this.screen === 'settings-data') {
      this.heading(this.text('界面与语言'), 92)
      this.card(16, 132, 328, 112)
      this.rowAt(this.text('界面与外观'), $r('sys.symbol.gearshape'), 132)
      this.line(188)
      this.rowAt(this.text('语言'), $r('sys.symbol.gearshape'), 188)
      this.heading(this.text('数据与用量'), 272)
      this.card(16, 312, 328, 116)
      this.rowAt(this.text('Token 用量'), $r('sys.symbol.clock'), 312, this.text('查看用量概览、每日趋势和请求明细'))
      this.line(372)
      this.controlRow('backup', this.text('备份与恢复'), $r('sys.symbol.folder_badge_plus'))
      this.heading(this.text('帮助与关于'), 456)
      this.card(16, 496, 328, 168)
      this.rowAt(this.text('使用帮助'), $r('sys.symbol.questionmark_circle'), 496)
      this.rowAt(this.text('评分和评论'), $r('sys.symbol.star'), 552)
      this.rowAt(this.text('关于 Tinybot'), $r('sys.symbol.info_circle'), 608)
    } else {
      this.heading(this.text('模型与服务'), 92)
      this.card(16, 132, 328, 184)
      NavRow({ title: 'DeepSeek', subtitle: 'Chat Completions · 2', image: providerLogo('deepseek') })
        .width(328).height(64).position({ x: 16, y: 132 })
      this.line(196)
      this.controlRow('add-provider', this.text('添加模型服务'), $r('sys.symbol.plus'), '', true)
      this.line(252)
      this.rowAt(this.text('模型分工与能力'), $r('sys.symbol.gearshape'), 252, this.text('自动选择模型、专用模型与能力配置'))
      this.heading(this.text('助手偏好'), 332)
      this.card(16, 372, 328, 184)
      this.rowAt(this.text('称呼与回答偏好'), $r('sys.symbol.square_and_pencil'), 372, this.text('填写称呼、背景和回答偏好'))
      this.line(436)
      this.rowAt(this.text('提示词模板'), $r('sys.symbol.doc_plaintext'), 436)
      this.line(492)
      this.switchAt(this.text('自动保存任务结果'), 492, false)
      this.heading(this.text('记忆与上下文'), 580)
      this.card(16, 620, 328, 80)
      this.switchAt(this.text('自动提取长期记忆'), 620, true)
    }
  }

  @Builder
  presets() {
    Column().width(TUTORIAL_WIDTH).height(TUTORIAL_HEIGHT).backgroundColor('#55000000')
    Column().width(TUTORIAL_WIDTH).height(672).borderRadius({ topLeft: 24, topRight: 24 })
      .backgroundColor($r('app.color.page_background')).position({ x: 0, y: 48 })
    Text(this.text('添加模型服务')).fontFamily(this.appearance.fontFamily).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      .position({ x: 16, y: 66 })
    Text(this.text('选择服务后，地址和常用模型会自动填好。')).fontFamily(this.appearance.fontFamily).fontSize(13)
      .fontColor($r('app.color.text_secondary')).position({ x: 16, y: 110 }).width(328)
    this.card(16, 138, 328, 504)
    NavRow({ title: 'DeepSeek', subtitle: 'Chat Completions', image: providerLogo('deepseek') })
      .width(328).height(56).position({ x: 16, y: 138 })
    NavRow({ title: this.text('DashScope · 阿里云百炼'), subtitle: 'Chat Completions', image: providerLogo('dashscope') })
      .width(328).height(56).position({ x: 16, y: 194 })
    NavRow({ title: 'OpenAI', subtitle: 'Chat Completions', image: providerLogo('openai'), tintImage: true })
      .width(328).height(56).position({ x: 16, y: 250 })
    NavRow({ title: this.text('Z.ai · 智谱'), subtitle: 'Chat Completions', image: providerLogo('zai'), tintImage: true })
      .width(328).height(56).position({ x: 16, y: 306 })
    NavRow({ title: 'Ollama', subtitle: 'Chat Completions', image: providerLogo('ollama'), tintImage: true })
      .width(328).height(56).position({ x: 16, y: 362 })
    this.rowAt(this.text('自定义兼容服务'), $r('sys.symbol.cloud'), 418, 'Chat Completions')
    this.rowAt('OpenAI Responses', $r('sys.symbol.cloud'), 474, 'OpenAI Responses')
    this.rowAt('Anthropic', $r('sys.symbol.cloud'), 530, 'Anthropic Messages')
    this.rowAt(this.text('添加自定义服务'), $r('sys.symbol.plus'), 586, '', true)
  }

  @Builder
  field(title: string, value: string, y: number) {
    Text(title).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).position({ x: 28, y }).height(22)
    Text(value).fontFamily(this.appearance.fontFamily).fontSize(15).fontColor($r('app.color.text_primary')).padding({ left: 12, right: 12 })
      .width(304).height(48).borderRadius(10).backgroundColor($r('app.color.surface_variant')).position({ x: 28, y: y + 22 })
  }

  @Builder
  provider() {
    this.pageTitle(this.text('添加服务'))
    this.card(16, 92, 328, 64)
    this.switchAt(this.text('启用此服务'), 92, true)
    this.heading(this.text('连接'), 166)
    this.card(16, 198, 328, 156)
    this.field(this.text('服务名称'), 'DeepSeek', 206)
    this.field(this.text('服务地址'), 'https://api.deepseek.com', 282)
    this.heading('API Key', 364)
    this.card(16, 396, 328, 112)
    this.switchAt(this.text('无需 API Key'), 390, false)
    Text(this.screen === 'provider-ready' ? '••••••••••••' : this.text('填写 API Key')).fontFamily(this.appearance.fontFamily)
      .fontSize(15).fontColor($r('app.color.text_secondary')).width(304).height(48).padding({ left: 12 })
      .borderRadius(10).backgroundColor($r('app.color.surface_variant')).position({ x: 28, y: 450 })
    Text(this.text('获取 API Key') + ' ↗').fontFamily(this.appearance.fontFamily).fontSize(14).fontColor(this.appearance.accent)
      .width(160).height(40).textAlign(TextAlign.Center).position({ x: 100, y: 508 })
    this.heading(this.text('模型'), 554)
    this.card(16, 586, 328, 56)
    this.rowAt('deepseek-flash', $r('sys.symbol.checkmark'), 586)
    this.pill('save-provider', this.text('保存服务'))
  }

  @Builder
  models() {
    this.pageTitle(this.text('选择模型'))
    Text(this.text('搜索服务或模型')).fontFamily(this.appearance.fontFamily).fontSize(15).fontColor($r('app.color.text_tertiary')).padding(12)
      .width(328).height(40).backgroundColor($r('app.color.surface_variant')).borderRadius(20).position({ x: 16, y: 88 })
    this.heading('DeepSeek', 128)
    this.card(16, 160, 328, 120)
    this.modelRow('deepseek-flash', 160, false)
    this.line(220)
    this.modelRow('deepseek-v4-pro', 220, true)
  }

  @Builder
  modelRow(name: string, y: number, selected: boolean) {
    Row() {
      Text(name).fontFamily(this.appearance.fontFamily).fontSize(16).fontColor(selected ? this.appearance.accent : $r('app.color.text_primary')).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.appearance.accent]).opacity(selected ? 1 : 0)
    }.width(328).height(60).padding({ left: 16, right: 16 }).position({ x: 16, y })
  }

  @Builder
  plus() {
    Column().width(TUTORIAL_WIDTH).height(TUTORIAL_HEIGHT).backgroundColor('#33000000')
    Column().width(TUTORIAL_WIDTH).height(330).borderRadius({ topLeft: 24, topRight: 24 })
      .backgroundColor($r('app.color.page_background')).position({ x: 0, y: 390 })
    Column().width(32).height(4).borderRadius(2).backgroundColor($r('app.color.divider')).position({ x: 164, y: 402 })
    Row({ space: 8 }) {
      this.tile(this.text('图片'), $r('sys.symbol.picture'))
      this.tile(this.text('文本文件'), $r('sys.symbol.doc_text'))
      this.tile(this.text('工作区'), $r('sys.symbol.folder'))
      this.tile(this.text('记忆'), $r('sys.symbol.lightbulb'))
      this.tile(this.text('Agent 团队'), $r('sys.symbol.person_2'))
    }.position({ x: 24, y: 438 })
    Text(this.text('图片需模型支持视觉输入 · 文本文件最多 64 KB')).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
      .width(328).textAlign(TextAlign.Center).position({ x: 16, y: 538 })
    Text(this.text('引用其他会话')).fontFamily(this.appearance.fontFamily).fontSize(15).fontColor(this.appearance.accent).textAlign(TextAlign.Center)
      .width(328).height(44).borderRadius(22).backgroundColor(this.appearance.accentContainer).position({ x: 16, y: 572 })
  }

  @Builder
  tile(title: string, icon: Resource) {
    Column({ space: 8 }) {
      Stack() { this.glyph(icon, 24) }.width(56).height(56).borderRadius(18).backgroundColor($r('app.color.surface'))
      Text(title).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_secondary'))
    }.width(56)
  }

  @Builder
  document() {
    this.pageTitle(this.text('称呼与回答偏好'))
    Text(this.text('保存后从下一轮生效')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
      .position({ x: 16, y: 98 }).width(328)
    Text(this.screen === 'document-ready' ? ('# ' + this.text('回答偏好') + '\n' + this.text('请简洁回答'))
      .slice(0, Math.ceil(this.typing * 40)) : this.text('填写称呼、背景和回答偏好')).fontFamily(this.appearance.fontFamily)
      .fontSize(14).lineHeight(24).fontColor($r('app.color.text_primary')).padding(12)
      .width(328).height(472).borderRadius(10).backgroundColor($r('app.color.surface')).position({ x: 16, y: 148 })
    this.pill('save-document', this.text('保存'))
  }

  @Builder
  backup() {
    this.pageTitle(this.text('备份与恢复'))
    this.heading(this.text('华为云空间'), 92)
    this.card(16, 132, 328, 200)
    this.controlRow('cloud-backup', this.text('备份到华为云空间'), $r('sys.symbol.cloud'), this.text('模型密钥不会导出'))
    this.line(212)
    this.rowAt(this.text('刷新备份列表'), $r('sys.symbol.arrow_clockwise'), 212)
    this.line(268)
    this.rowAt(this.text('打开华为云空间'), $r('sys.symbol.cloud'), 268)
    this.heading(this.text('本地备份'), 368)
    this.card(16, 408, 328, 128)
    this.controlRow('export-backup', this.text('导出备份'), $r('sys.symbol.square_and_arrow_down'), this.text('存到本机，或分享到其他设备'))
    this.line(472)
    this.rowAt(this.text('从备份导入'), $r('sys.symbol.folder_badge_plus'), 472, this.text('只恢复缺少的内容，保留本机已有对话'))
    Text(this.text('模型密钥不会导出')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
      .position({ x: 28, y: 570 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.overlayOnly) {
      Text('9:41').fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .position({ x: 20, y: 5 })
      }
      if (this.overlayOnly) {
        if (this.screen === 'menu') { this.menu() }
        else if (this.screen === 'plus') { this.plus() }
        else if (this.screen === 'presets') { this.presets() }
      } else {
      if (this.screen === 'settings' || this.screen === 'settings-memory' || this.screen === 'settings-data') { this.settings() }
      else if (this.screen === 'presets') { this.settings(); this.presets() }
      else if (this.screen === 'provider' || this.screen === 'provider-ready') { this.provider() }
      else if (this.screen === 'models') { this.models() }
      else if (this.screen === 'document' || this.screen === 'document-ready') { this.document() }
      else if (this.screen === 'backup') { this.backup() }
      else if (this.screen === 'memory' || this.screen === 'files') {
        this.pageTitle(this.screen === 'memory' ? this.text('管理长期记忆') : this.text('工作区文件'))
        this.card(16, 132, 328, 64)
        this.rowAt(this.screen === 'memory' ? this.text('请简洁回答') : 'USER.md',
          this.screen === 'memory' ? $r('sys.symbol.lightbulb') : $r('sys.symbol.doc_plaintext'), 132)
      } else {
        this.chat()
        if (this.screen === 'menu') { this.menu() }
        if (this.screen === 'plus') { this.plus() }
      }
      }
    }.width(TUTORIAL_WIDTH).height(TUTORIAL_HEIGHT).clip(true).backgroundColor(this.overlayOnly ? Color.Transparent : $r('app.color.page_background'))
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
