import { AppearanceStyle } from '../common/AppearanceStyle';
import { Banner, GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { Btn, Font, Space } from '../common/Theme';
import { t } from '../model/I18n';
import { HuaweiAccount } from '../services/HuaweiAccount';

@Component
export struct HuaweiAccountPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink account: HuaweiAccount;
  @Prop taskBusy: boolean = false;
  @State private agreed: boolean = false;
  onSupport: (page: string) => void = () => {};

  build() {
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
        } else {
          Row({ space: Space.sm }) {
            Checkbox().id('huawei-account-consent').select(this.agreed).enabled(!this.account.busy)
              .onChange((value: boolean) => { this.agreed = value; })
            Text(t('我已阅读并同意用户协议和隐私政策'))
              .fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
          }.width('100%')
          Button(this.account.busy ? t('正在登录…') : t('华为账号登录'))
            .fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary).width('100%').id('huawei-account-signin')
            .enabled(this.account.ready && !this.account.busy && this.agreed && !this.taskBusy)
            .onClick(() => { if (this.agreed) { this.account.signIn(); } })
          if (this.account.error) {
            Button(t('清除本机登录记录')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
              .id('huawei-account-clear').enabled(!this.account.busy && !this.taskBusy).onClick(() => this.account.signOut())
          }
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
}
