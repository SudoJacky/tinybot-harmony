import { uiMaterial } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Banner, GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { Btn, Font, Motion, Space } from '../common/Theme';
import { t } from '../model/I18n';
import { HuaweiAccount } from '../services/HuaweiAccount';
import { OnboardingMascot } from './OnboardingMascot';

@Component
export struct HuaweiAccountPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink account: HuaweiAccount;
  @Prop taskBusy: boolean = false;
  @State private agreed: boolean = false;
  @State private bodyHeight: number = 0;
  onSupport: (page: string) => void = () => {};

  @Builder
  signedInContent() {
    Scroll() {
      Column({ space: Space.lg }) {
        SymbolGlyph($r('sys.symbol.person')).fontSize(56).fontColor([$r('app.color.accent')])
          .margin({ top: Space.xl })
        Text(this.account.signedIn ? t('已登录华为账号') : t('登录华为账号'))
          .fontFamily(this.appearance.fontFamily).fontSize(Font.headline).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).id('huawei-account-status')
        Text(t('登录后使用 AI 生成功能，模型服务仍使用你配置的 Key。'))
          .fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        Text(t('仅在本机安全保存华为账号标识，不获取姓名、手机号或身份证号。退出登录不会删除本地会话和文件。'))
          .fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary'))
        if (this.account.error) { Banner({ text: this.account.error, compId: 'huawei-account-error' }) }
        if (this.account.signedIn) {
          Button(t('退出登录')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.tonal)
            .id('huawei-account-signout').width('100%').enabled(!this.account.busy && !this.taskBusy)
            .onClick(() => this.account.signOut())
        }
        if (this.taskBusy) { Text(t('有任务正在进行，完成后可修改登录状态。')).fontSize(Font.small).fontColor($r('app.color.text_secondary')) }
        GroupCard() {
          Column() {
            NavRow({ title: t('用户协议'), icon: $r('sys.symbol.doc_plaintext'), compId: 'account-user-agreement', onTap: () => this.onSupport('terms') })
            RowDivider()
            NavRow({ title: t('隐私政策'), icon: $r('sys.symbol.lock'), compId: 'account-privacy-policy', onTap: () => this.onSupport('privacy') })
          }
        }
      }.width('100%').padding(Space.page)
    }.width('100%').height('100%').align(Alignment.Top)
  }

  private loginAvailable(): boolean {
    return this.account.ready && !this.account.busy && this.agreed && !this.taskBusy;
  }

  private signIn(): void {
    if (this.loginAvailable()) { this.account.signIn(); }
  }

  @Builder
  loginContent() {
    Column({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        OnboardingMascot({ diameter: 132, scene: 0, mood: 'curious', energized: true })
      }.id('huawei-account-mascot').width('100%').height(144)
      Text(t('登录华为账号')).id('huawei-account-status').fontFamily(this.appearance.fontFamily)
        .fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
      Text(!this.account.ready ? t('正在确认登录状态，请稍候。') :
        t('根据监管需要，须登录以使用AI生成功能。\n我们承诺不会收集任何隐私信息至Tinybot服务器。'))
        .fontFamily(this.appearance.fontFamily).fontSize(14).lineHeight(21).fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center).width('100%').padding({ left: 8, right: 8 })
      if (this.account.error) { Banner({ text: this.account.error, compId: 'huawei-account-error' }) }
      Row({ space: 10 }) {
        Checkbox().id('huawei-account-consent').select(this.agreed).selectedColor(this.appearance.accent)
          .enabled(!this.account.busy).accessibilityText(t('我已阅读并同意用户协议和隐私政策'))
          .onChange((value: boolean) => { this.agreed = value; })
        Text() {
          Span(t('我已阅读并同意'))
          Span(t('用户协议')).fontColor(this.appearance.accent).decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.onSupport('terms'))
          Span(t('和'))
          Span(t('隐私政策')).fontColor(this.appearance.accent).decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.onSupport('privacy'))
        }.id('huawei-account-agreement').fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(19)
          .fontColor($r('app.color.text_primary')).layoutWeight(1).enabled(!this.account.busy)
      }.width('100%').padding({ left: 2, right: 2 })
      if (this.account.error) {
        Button(t('清除本机登录记录')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
          .id('huawei-account-clear').enabled(!this.account.busy && !this.taskBusy).onClick(() => this.account.signOut())
      }
      if (this.taskBusy) {
        Text(t('有任务正在进行，完成后可修改登录状态。')).fontFamily(this.appearance.fontFamily)
          .fontSize(Font.small).fontColor($r('app.color.text_secondary'))
      }
    }.width('100%').constraintSize({ minHeight: this.bodyHeight }).justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
  }

  build() {
    if (this.account.signedIn) {
      this.signedInContent()
    } else {
      Column() {
        Scroll() { this.loginContent() }
          .width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .onAreaChange((_old: Area, area: Area) => { this.bodyHeight = Number(area.height); })
        Column() {
          Toggle({ type: ToggleType.Button, isOn: false }) {
            Text(this.account.busy ? t('正在登录…') : t('华为账号登录')).fontFamily(this.appearance.fontFamily)
              .fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(this.loginAvailable() ? this.appearance.onAccent : $r('app.color.text_secondary'))
          }.id('huawei-account-signin').width('100%').height(48).borderRadius(24).padding(0)
            .clickEffect(this.appearance.effectStrength > 0 ? null : Motion.press)
            .backgroundColor(this.loginAvailable() ? this.appearance.accent : $r('app.color.surface_variant'))
            .selectedColor(this.loginAvailable() ? this.appearance.accent : $r('app.color.surface_variant'))
            .systemMaterial(this.loginAvailable() ? this.appearance.accentControl : uiMaterial.Material.empty)
            .enabled(this.loginAvailable()).accessibilityRole(AccessibilityRoleType.BUTTON)
            .accessibilityText(this.account.busy ? t('正在登录…') : t('华为账号登录'))
            .onClick(() => this.signIn())
        }.width('100%').padding({ top: 60, bottom: 8 })
      }.width('100%').height('100%').padding({ left: 24, right: 24, top: 8, bottom: 4 })
    }
  }

}
