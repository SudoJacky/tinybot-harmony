import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn } from '../common/Theme';
import { GroupCard, SectionHeader } from '../common/Widgets';
import { t } from '../model/I18n';
import { ProviderProfile } from '../model/ProviderProfiles';
import { supportsProviderBalance } from '../services/ProviderBalance';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';
import { BalanceQuerySettings } from './BalanceQuerySettings';
import { ProviderBalanceResult } from './ProviderBalanceResult';

@Component
export struct ProviderBalanceCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink editor: ProviderEditorViewModel;
  @Prop profiles: ProviderProfile[] = [];
  @Prop disabled: boolean = false;
  @Prop active: boolean = false;
  @Prop scope: string = '';
  @State private configuring: boolean = false;

  private supported(): boolean { return supportsProviderBalance(this.editor.protocol, this.editor.baseUrl, this.editor.balanceSettings()); }

  build() {
    Column() {
      SectionHeader({ title: t('余额与额度') })
      GroupCard() {
        Column({ space: 10 }) {
          Button(this.configuring ? t('收起查询设置') : t('余额查询设置')).fontFamily(this.appearance.fontFamily)
            .attributeModifier(Btn.text).id('balance-configure').onClick(() => { this.configuring = !this.configuring; })
          if (this.configuring) { BalanceQuerySettings({ editor: this.editor, disabled: this.disabled }) }
          if (this.supported()) {
            Text(t('账户余额、Key 限额和订阅额度分别显示，不代表本次对话的费用。'))
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
            ProviderBalanceResult({ draft: this.editor.snapshot(), profiles: this.profiles, active: this.active,
              disabled: this.disabled, scope: this.scope, canQuery: this.editor.canQueryBalance })
          } else if (this.editor.balanceMode !== 'off') {
            Text(t('此地址未匹配余额接口。可选择中转站类型或配置自定义查询，也可到服务商控制台查看。'))
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
          }
        }.padding(12).width('100%').alignItems(HorizontalAlign.Start)
      }
    }.width('100%')
  }
}
