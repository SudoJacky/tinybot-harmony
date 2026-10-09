import { t } from '../model/I18n';
import { readAppInformation } from '../services/AppInformation';
import { Font, Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';

export function supportTitle(page: string): string {
  if (page === 'help') { return t('使用帮助'); }
  if (page === 'updates') { return t('更新说明'); }
  if (page === 'announcements') { return t('公告'); }
  if (page === 'guide') { return t('首次使用指引'); }
  return t('关于 Tinybot');
}

@Component
export struct SupportPanel {
  @Prop page: string = 'about';
  @State private version: string = '';
  @State private error: string = '';
  onOpen: (page: string) => void = () => {};

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
  article(title: string, body: string) {
    GroupCard() {
      Column({ space: Space.sm }) {
        Text(title).fontSize(Font.body).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(body).fontSize(Font.small).fontColor($r('app.color.text_secondary')).lineHeight(22).width('100%')
      }.alignItems(HorizontalAlign.Start).width('100%').padding(Space.lg)
    }
  }

  @Builder
  about() {
    Column({ space: Space.sm }) {
      Image($r('app.media.tinybot_icon')).width(72).height(72).borderRadius(18).accessibilityLevel('no')
      Text('Tinybot').fontSize(Font.headline).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Text(t('你的随身 AI 助手')).fontSize(Font.small).fontColor($r('app.color.text_secondary'))
      if (this.version) {
        Text(t('版本 {0}', [this.version])).id('about-version').fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
      }
    }.width('100%').padding({ top: Space.lg, bottom: Space.xl })
    GroupCard() {
      Column() {
        NavRow({ title: t('更新说明'), compId: 'open-release-notes', onTap: () => this.onOpen('updates') })
        RowDivider()
        NavRow({ title: t('公告'), compId: 'open-announcements', onTap: () => this.onOpen('announcements') })
        RowDivider()
        NavRow({ title: t('评分和评论'), compId: 'open-about-rating', onTap: () => this.onOpen('rating') })
        RowDivider()
        NavRow({ title: t('首次使用指引'), compId: 'open-startup-guide', onTap: () => this.onOpen('guide') })
      }
    }
    SectionHeader({ title: t('协议与政策') })
    GroupCard() {
      Column() {
        NavRow({ title: t('用户协议'), value: t('待补充'), compId: 'user-agreement', disabled: true })
        RowDivider()
        NavRow({ title: t('隐私政策'), value: t('待补充'), compId: 'privacy-policy', disabled: true })
      }
    }
  }

  @Builder
  help() {
    this.article(t('开始对话'), t('先在“设置 → 添加模型服务”选择服务商，填写自己的 API Key 和模型。保存后，点击聊天顶部的模型名称选择模型，再输入问题并发送。'))
    this.article(t('附件与语音'), t('点击输入框的“+”添加图片或文档；图片需要支持视觉的模型。点击或按住麦克风可转写语音，识别文字仍需手动发送。'))
    this.article(t('让助手记住偏好'), t('在“设置 → 用户文档（USER.md）”填写称呼和回答偏好；在“管理长期记忆”中查看、编辑或删除记忆。'))
    this.article(t('文件与备份'), t('聊天右上角的更多菜单可打开当前会话文件；在“设置 → 备份与恢复”导出备份或使用华为云空间。模型密钥不会随备份导出。'))
    this.article(t('连接失败时'), t('检查服务地址、模型名称、API Key 和网络连接。失败提示会保留在聊天中，可修改后重试；模型服务的额度与计费请在服务商处查看。'))
    GroupCard() {
      NavRow({ title: t('首次使用指引'), compId: 'help-startup-guide', onTap: () => this.onOpen('guide') })
    }
  }

  @Builder
  guide() {
    this.article(t('1. 准备模型服务'), t('Tinybot 直接连接你选择的模型服务。请先准备服务商提供的 API Key；模型调用费用与可用额度由该服务商决定。'))
    this.article(t('2. 添加并选择模型'), t('打开“设置 → 添加模型服务”，选择服务商或自定义服务，填写地址、API Key 和模型并保存。回到聊天，点击顶部模型名称选择要使用的模型。'))
    this.article(t('3. 开始第一个任务'), t('直接输入你想解决的问题，也可以通过“+”添加材料。发送后可随时停止生成；需要多个助手协作时，可输入 /team 并描述目标。'))
    this.article(t('4. 查看结果与保存资料'), t('AI可能会犯错，请仔细鉴别。重要信息请核实来源；需要保留资料时，可从聊天更多菜单导出对话，或在设置中创建备份。'))
    Text(t('你可以随时从“关于 Tinybot”重新查看这份指引。')).fontSize(Font.caption)
      .fontColor($r('app.color.text_secondary')).width('100%')
  }

  @Builder
  updates() {
    this.article(t('0.1.6 测试版 · 2026-10-09'), t('新增工具编排，可组合文件、网页与 MCP 工具，统一汇总结果；展开工具回执可查看各子调用的参数、状态和结果，支持停止与错误恢复。'))
    this.article(t('上下文用量明细'), t('点击输入框旁的上下文圆圈，可展开查看系统提示、工具定义、用户输入、助手消息、工具结果、摘要、附件与协议开销。分类为本地估算，模型实际返回的请求及本轮用量单独显示。'))
    this.article(t('0.1.5 测试版 · 2026-10-07'), t('新增聊天底部的 AI 提示、使用帮助与关于 Tinybot，可查看更新说明、公告和首次使用指引。评分和评论直接打开系统评价弹窗；服务列表新增品牌 Logo，并修复切换明暗主题时状态栏文字颜色滞后的问题。'))
    this.article(t('备份与恢复'), t('云备份支持确认后删除指定快照。恢复备份时保留本机密钥与配置，复用能明确匹配的模型服务和 MCP；无法匹配或存在多个候选时导入为停用副本。'))
    this.article(t('0.1.4 测试版 · 2026-10-05'), t('新增系统语音转文字和华为云空间手动备份与恢复；改进会话滑动删除的回弹体验，修复长思考流式传输和 Responses 推理内容显示问题。'))
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        if (this.error) { Banner({ text: this.error, compId: 'support-error' }) }
        if (this.page === 'help') {
          this.help()
        } else if (this.page === 'guide') {
          this.guide()
        } else if (this.page === 'updates') {
          this.updates()
        } else if (this.page === 'announcements') {
          this.article(t('暂无公告'), t('有新的公告时，会显示在这里。'))
        } else {
          this.about()
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
    }.height('100%').width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }
}
