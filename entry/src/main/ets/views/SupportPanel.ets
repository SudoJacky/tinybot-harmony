import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ThirdPartyLicensesPanel } from './ThirdPartyLicensesPanel';
import { LegalDocumentPanel } from './LegalDocumentPanel';
import { readAppInformation } from '../services/AppInformation';
import { Font, Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';
import { HelpDemo } from './HelpDemo';
import { HelpDemoKind } from '../model/HelpTutorial';
import { DeveloperGate, Diagnostics } from '../model/Diagnostics';
import { DeveloperDiagnostics } from '../services/DeveloperDiagnostics';
import { DeveloperPanel } from './DeveloperPanel';
import { Btn } from '../common/Theme';
import { Announcements, announcements } from '../services/Announcements';
import { MarkdownView } from './MarkdownView';
import { FeedbackPanel } from './FeedbackPanel';

const QQ_GROUP_NUMBER: string = '337943922';
const QQ_GROUP_INVITE_URL: string = 'https://qm.qq.com/q/lqgqSxGCK4';

export function supportTitle(page: string): string {
  if (page === 'developer') { return t('开发者模式'); }
  if (page === 'help') { return t('使用帮助'); }
  if (page === 'updates') { return t('更新说明'); }
  if (page === 'announcements') { return t('公告'); }
  if (page === 'feedback') { return t('反馈与建议'); }
  if (page === 'guide') { return t('首次使用指引'); }
  if (page === 'licenses') { return t('第三方开源许可协议'); }
  if (page === 'privacy') { return t('隐私政策'); }
  if (page === 'terms') { return t('用户协议'); }
  return t('关于 Tinybot');
}

@Component
export struct SupportPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop page: string = 'about';
  @State private version: string = '';
  @State private announcementService: Announcements = announcements;
  @State private error: string = '';
  @State private copyingGroup: boolean = false;
  @State private openingGroup: boolean = false;
  @State private groupError: string = '';
  @State private showDeveloperPassword: boolean = false;
  @State private developerPassword: string = '';
  @State private developerError: string = '';
  private developerGate: DeveloperGate = new DeveloperGate();
  onOpen: (page: string) => void = () => {};
  onClose: () => void = () => {};

  aboutToDisappear(): void { this.cancelDeveloperUnlock(); }
  private cancelDeveloperUnlock(): void {
    this.developerPassword = ''; this.developerError = ''; this.developerGate.cancel();
  }
  private versionTapped(): void {
    if (AppStorage.get<boolean>('tinybot.developer.enabled')) { this.onOpen('developer'); return; }
    if (this.developerGate.tap(Diagnostics.now())) { this.developerPassword = ''; this.developerError = ''; this.showDeveloperPassword = true; }
  }
  private unlockDeveloper(): void {
    const password = this.developerPassword; this.developerPassword = '';
    if (!this.developerGate.verify(password, Diagnostics.now())) {
      const remaining = this.developerGate.remaining(Diagnostics.now());
      this.developerError = remaining > 0 ? t('尝试次数过多，请 {0} 秒后重试。', [remaining]) : t('密码不正确。'); return;
    }
    try { DeveloperDiagnostics.enable(); this.showDeveloperPassword = false; this.onOpen('developer'); }
    catch (error) { this.developerError = t('诊断操作失败：{0}', [(error as Error).message]); }
  }
  @Builder
  developerPasswordSheet() {
    Column({ space: Space.md }) {
      TextInput({ text: this.developerPassword, placeholder: t('开发者密码') }).type(InputType.Password).id('developer-password')
        .fontFamily(this.appearance.fontFamily).enterKeyType(EnterKeyType.Done).onSubmit(() => this.unlockDeveloper())
        .onChange((value: string) => { this.developerPassword = value; })
      if (this.developerError) { Banner({ text: this.developerError, compId: 'developer-password-error' }) }
      Button(t('开启开发者模式')).fontFamily(this.appearance.fontFamily).id('developer-unlock').attributeModifier(Btn.primary)
        .width('100%').onClick(() => this.unlockDeveloper())
    }.width('100%').padding(Space.page)
  }

  private async openWebsite(url: string): Promise<void> {
    try {
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .startAbility({ action: 'ohos.want.action.viewData', uri: url });
    } catch (error) {
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('无法打开系统浏览器。'),
        message: url + '\n' + (error as Error).message,
        confirm: { value: t('关闭'), action: () => {} } });
    }
  }

  private async copyGroupNumber(): Promise<void> {
    if (this.copyingGroup) { return; }
    this.copyingGroup = true; this.groupError = '';
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, QQ_GROUP_NUMBER));
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface,
        message: t('群号已复制，请在 QQ 中搜索群号加入。') });
    } catch (error) {
      this.groupError = t('复制群号失败：{0}', [(error as Error).message]);
    } finally { this.copyingGroup = false; }
  }

  private async openGroupInvite(): Promise<void> {
    if (this.openingGroup) { return; }
    this.openingGroup = true; this.groupError = '';
    try {
      // Let the system resolve Tencent's invite URL; a browser can handle it when no app matches.
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .openLink(QQ_GROUP_INVITE_URL, { appLinkingOnly: false });
    } catch (error) {
      this.groupError = t('无法打开加群链接，请复制群号后在 QQ 中搜索。原因：{0}', [(error as Error).message]);
    } finally { this.openingGroup = false; }
  }

  aboutToAppear(): void {
    if (this.page !== 'about') { return; }
    try {
      const info = readAppInformation();
      this.version = info.versionName + ' (' + info.versionCode + ')';
    } catch (error) {
      this.error = t('无法读取应用版本：{0}', [(error as Error).message]);
    }
  }

  @Builder
  article(title: string, body: string, demo: HelpDemoKind | '' = '') {
    GroupCard() {
      Column({ space: Space.sm }) {
        Text(title).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .width('100%')
        if (demo !== '') { HelpDemo({ kind: demo as HelpDemoKind }) }
        Text(body).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary')).lineHeight(22).width('100%')
      }.alignItems(HorizontalAlign.Start).width('100%').padding(Space.lg)
    }
  }

  @Builder
  about() {
    Column({ space: Space.sm }) {
      Image($r('app.media.tinybot_icon')).width(72).height(72).borderRadius(18).accessibilityLevel('no')
      Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(Font.headline).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Text(t('你的随身 AI 助手')).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary'))
      if (this.version) {
        Text(t('版本 {0}', [this.version])).fontFamily(this.appearance.fontFamily).id('about-version').fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          .onClick(() => this.versionTapped())
          .bindSheet($$this.showDeveloperPassword, this.developerPasswordSheet(), { title: { title: t('开启开发者模式') }, height: SheetSize.FIT_CONTENT,
            dragBar: true, keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE, systemMaterial: this.appearance.surface,
            onDisappear: () => this.cancelDeveloperUnlock() })
      }
    }.width('100%').padding({ top: Space.lg, bottom: Space.xl })
    this.article(t('开源共建'), t('Tinybot 是一款开源软件，遵循 Apache 2.0 许可证。欢迎社区参与维护、改进翻译、报告问题，以及通过 Pull Request 提交代码，一起让 Tinybot 变得更好。'))
    GroupCard() {
      Column() {
        NavRow({ title: t('GitHub 仓库'), icon: $r('sys.symbol.link'), subtitle: 'SudoJacky/tinybot-harmony', compId: 'about-github',
          onTap: () => this.openWebsite('https://github.com/SudoJacky/tinybot-harmony') })
        RowDivider()
        NavRow({ title: t('反馈与建议'), icon: $r('sys.symbol.exclamationmark_circle'), compId: 'about-feedback',
          onTap: () => this.onOpen('feedback') })
        RowDivider()
        NavRow({ title: t('QQ 交流群'), icon: $r('sys.symbol.person_2'), subtitle: t('{0} · 点击加群', [QQ_GROUP_NUMBER]),
          compId: 'about-qq-group', disabled: this.openingGroup || this.copyingGroup,
          actionLabel: t('复制群号'), actionId: 'about-copy-qq-group',
          onTap: () => this.openGroupInvite(), onAction: () => this.copyGroupNumber() })
        if (this.groupError) {
          Banner({ text: this.groupError, compId: 'about-qq-group-error' })
            .margin({ left: Space.md, right: Space.md, bottom: Space.sm })
        }
      }
    }
    GroupCard() {
      Column() {
        NavRow({ title: t('更新说明'), icon: $r('sys.symbol.doc_text'), compId: 'open-release-notes', onTap: () => this.onOpen('updates') })
        RowDivider()
        NavRow({ title: t('公告'), icon: $r('sys.symbol.speaker_wave_2'), compId: 'open-announcements', onTap: () => this.onOpen('announcements') })
        RowDivider()
        NavRow({ title: t('评分和评论'), icon: $r('sys.symbol.star'), compId: 'open-about-rating', onTap: () => this.onOpen('rating') })
        RowDivider()
        NavRow({ title: t('首次使用指引'), icon: $r('sys.symbol.wand_and_stars'), compId: 'open-startup-guide', onTap: () => this.onOpen('guide') })
      }
    }
    SectionHeader({ title: t('协议与政策') })
    GroupCard() {
      Column() {
        NavRow({ title: t('用户协议'), icon: $r('sys.symbol.doc_plaintext'), compId: 'user-agreement', onTap: () => this.onOpen('terms') })
        RowDivider()
        NavRow({ title: t('隐私政策'), icon: $r('sys.symbol.lock'), compId: 'privacy-policy',
          onTap: () => this.onOpen('privacy') })
        RowDivider()
        NavRow({ title: 'Apache License 2.0', icon: $r('sys.symbol.doc'), compId: 'about-project-license',
          onTap: () => this.openWebsite('https://github.com/SudoJacky/tinybot-harmony/blob/main/LICENSE') })
        RowDivider()
        NavRow({ title: t('第三方开源许可协议'), icon: $r('sys.symbol.rectangle_stack'), compId: 'open-third-party-licenses',
          onTap: () => this.onOpen('licenses') })
      }
    }
    this.article(t('免责声明'), t('本软件按“现状”提供；除适用法律要求或书面约定外，不提供任何明示或默示担保。相关责任限制以 Apache 2.0 许可证为准。AI 生成内容可能不准确，请自行核实重要信息，审慎执行工具操作，并备份重要数据。你所连接的模型及其他第三方服务，其可用性、费用与数据处理规则由相应服务商决定。'))
    Column() {
      Button('苏ICP备2026078369号-1A', { type: ButtonType.Normal, stateEffect: true })
        .id('about-icp-filing').fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
        .fontColor(this.appearance.accent).backgroundColor(Color.Transparent).width('100%').height(32)
        .responseRegion({ x: 0, y: -12, width: '100%', height: 44 })
        .onClick(() => this.openWebsite('https://beian.miit.gov.cn'))
      Text('Copyright © 2026 Tinybot. All rights reserved.').fontFamily(this.appearance.fontFamily).id('about-copyright')
        .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center).width('100%')
    }.width('100%').padding({ bottom: Space.sm })
  }

  @Builder
  help() {
    GroupCard() {
      NavRow({ title: t('首次使用指引'), subtitle: t('大约一分钟，认识一个新伙伴'), image: $r('app.media.tinybot'),
        compId: 'help-startup-guide', onTap: () => this.onOpen('guide') })
    }
    this.article(t('开始对话'), t('先在“设置 → 添加模型服务”选择服务商，填写自己的 API Key 和模型。保存后，点击聊天顶部的模型名称选择模型，再输入问题并发送。'), 'chat')
    this.article(t('附件与语音'), t('点击输入框的“+”添加图片或文档；图片需要支持视觉的模型。点击麦克风切换到按住说话，按住录音、松开发送；滑到左侧取消后松手可取消，滑到右侧编辑后松手可修改文字。点击键盘按钮可返回文字输入。'), 'attachments')
    this.article(t('让助手记住偏好'), t('在“设置 → 助手偏好 → 称呼与回答偏好”填写个人偏好；在“记忆与上下文 → 管理长期记忆”中查看、编辑或删除记忆。'), 'preferences')
    this.article(t('文件与备份'), t('聊天右上角的更多菜单可打开当前会话文件；在“设置 → 备份与恢复”导出备份或使用华为云空间。模型密钥不会随备份导出。'), 'backup')
    this.article(t('连接失败时'), t('检查服务地址、模型名称、API Key 和网络连接。失败提示会保留在聊天中，可修改后重试；模型服务的额度与计费请在服务商处查看。'), 'failure')
  }

  @Builder
  updates() {
    this.article(t("1.2.1 · 2026-10-29"), t("支持将图片或文件拖入当前聊天作为附件。设置新增实验室，小程序默认关闭，可按需开启，关闭后保留已有数据。修复旧版小程序预览记录导致会话无法加载的问题。"))
    this.article(t("1.2.0 · 2026-10-28"), t("新增并行会话、本地小程序与数据保存、后台完成通知和系统文档分享，单条消息最多 10 个附件。默认开启必应搜索，优化搜索设置并增加 QQ 社区入口。支持全屏预览与实际页面验证；改善工具响应和大内容处理，修复后台预览误超时、分享后聊天遮挡及配置兼容问题。"))
    this.article(t("1.1.1 · 2026-10-28"), t("新增网络传输期间的后台保活与评价邀请。预览支持原生浏览器验证和全屏查看；优化工具执行响应与大内容处理。修复后台预览校验误超时，返回前台后继续发布。"))
    this.article(t('1.1.0 · 2026-10-26'), t('新增平板工作台、反馈与建议、存储空间管理及无需搜索密钥的内置必应搜索，支持 HarmonyOS 6（API 20）。已启用的工具直接提供给模型，交互预览在最终回复中展示。修复必应移动页面无法提取搜索结果的问题，并优化平板公告宽度。'))
    this.article(t('1.0.6 · 2026-10-24'), t('修复 Release 版本画板无法打开的问题。仅发送图片、附件或会话引用时保留空正文，不自动补充提示语；纯图片请求不附带空文本块，并避免空正文触发标题生成。'))
    this.article(t('1.0.5 · 2026-10-23'), t('新增桌面服务卡片和原生 Gemini API。统一分享会话入口，可选择消息、预览图片后保存或分享，仅保留正文与 AI 声明。优化在线公告、新对话操作，移除固定的 Skill 数量限制，并增加仅供 Debug 模拟器使用的隐私调试流程。'))
    this.article(t('1.0.4 · 2026-10-23'), t('优化模型请求的前缀复用，提高缓存命中机会。接入华为托管隐私政策与系统隐私弹窗，同意后进入应用，拒绝后退出；关于页支持查看政策及撤回授权，保留已有会话与设置。'))
    this.article(t('1.0.3 · 2026-10-21'), t('聊天底部提示更新为“AI生成内容可能有误，请仔细鉴别。”，同步帮助演示、对话图片导出、英文翻译和相关文档引用。'))
    this.article(t('1.0.2 · 2026-10-21'), t('新增 Tiny 首次使用引导与三页作品示例，优化模型配置时的键盘避让和吉祥物动效。接入华为账号登录，支持项目共享文件夹、Markdown 图片预览和带 AI 标识的对话图片导出。新增用量贡献热力图与上下文分段统计，修复共享工作区备份恢复、工具结果保留及流式回复稳定性问题。'))
    this.article(t('1.0.1 · 2026-10-18'), t('移除图片生成设置、工具开关与执行接口，保留图片输入、图片理解和历史图片查看。自定义工具调整为 12 项能力，兼容旧版图片模型与工具禁用配置。'))
    this.article(t('1.0.0 · 2026-10-18'), t('首个大版本：原生聊天、项目共享工作区、工具编排与团队协作、Skills、MCP、长期记忆和备份集中在手机中。支持连接自己的模型服务，继续保留已有对话与配置。'))
    this.article(t('工具更精简'), t('初始工具精简为读取、写入、编辑、编排和工具检索；使用 BM25 检索按需加载其他能力。复杂参数使用原生对象和数组，文件编辑支持批量替换，沿用工作区边界、权限与执行确认。'))
    this.article(t('聊天与设置焕新'), t('流式文字渐显，思考和工具调用独立折叠，消息操作集中为图标。发送消息后收起键盘，输入时显示团队模式；设置使用独立子页，统一图标与间距，改善深色启动页与光感材质的可读性。'))
    this.article(t('用量与稳定性'), t('上下文详情展示整个会话的累计用量，每轮仍保留独立统计。改进长回复滚动和预览加载，保留工具执行保护、完整调用记录与错误提示。'))
    this.article(t('0.1.6 测试版 · 2026-10-09'), t('新增工具编排，可组合文件、网页与 MCP 工具，统一汇总结果；展开工具回执可查看各子调用的参数、状态和结果，支持停止与错误恢复。'))
    this.article(t('上下文用量明细'), t('点击输入框旁的上下文圆圈，可展开查看系统提示、工具定义、用户输入、助手消息、工具结果、摘要、附件与协议开销。分类为本地估算，模型实际返回的请求及本轮用量单独显示。'))
    this.article(t('0.1.5 测试版 · 2026-10-07'), t('新增聊天底部的 AI 提示、使用帮助与关于 Tinybot，可查看更新说明、公告和首次使用指引。评分和评论直接打开系统评价弹窗；服务列表新增品牌 Logo，并修复切换明暗主题时状态栏文字颜色滞后的问题。'))
    this.article(t('备份与恢复'), t('云备份支持确认后删除指定快照。恢复备份时保留本机密钥与配置，复用能明确匹配的模型服务和 MCP；无法匹配或存在多个候选时导入为停用副本。'))
    this.article(t('0.1.4 测试版 · 2026-10-05'), t('新增系统语音转文字和华为云空间手动备份与恢复；改进会话滑动删除的回弹体验，修复长思考流式传输和 Responses 推理内容显示问题。'))
  }

  build() {
    if (this.page === 'feedback') {
      FeedbackPanel({ onClose: this.onClose })
    } else if (this.page === 'developer') {
      DeveloperPanel({ onDisabled: () => this.onOpen('about') })
    } else if (this.page === 'licenses') {
      ThirdPartyLicensesPanel()
    } else if (this.page === 'terms') {
      LegalDocumentPanel()
    } else {
      Scroll() {
        Column({ space: Space.md }) {
          if (this.error) { Banner({ text: this.error, compId: 'support-error' }) }
          if (this.page === 'help') {
            this.help()
          } else if (this.page === 'updates') {
            this.updates()
          } else if (this.page === 'announcements') {
            if (!this.announcementService.configured) {
              this.article(t('公告'), t('公告暂未开放。'))
            } else if (this.announcementService.loading) {
              LoadingProgress().width(32).height(32)
            } else if (this.announcementService.error) {
              Banner({ text: this.announcementService.error, compId: 'announcement-error' })
            } else if (this.announcementService.current) {
              GroupCard() {
                Column({ space: Space.md }) {
                  Text(this.announcementService.current.title).fontFamily(this.appearance.fontFamily)
                    .fontSize(Font.title).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
                  MarkdownView({ content: this.announcementService.current.body, fontSize: Font.body })
                }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
              }
            } else {
              this.article(t('暂无公告'), t('有新的公告时，会显示在这里。'))
            }
          } else {
            this.about()
          }
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
      }.height('100%').width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }
  }
}
