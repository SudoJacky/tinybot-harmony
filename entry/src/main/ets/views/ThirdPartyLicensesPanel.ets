import { AppearanceStyle } from '../common/AppearanceStyle';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { t } from '../model/I18n';
import { THIRD_PARTY_LICENSES, ThirdPartyLicense } from '../model/ThirdPartyLicenses';
import { Font, Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider } from '../common/Widgets';

@Component
struct LicenseCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop item: ThirdPartyLicense;
  @State private expanded: boolean = false;
  @State private loading: boolean = false;
  @State private text: string = '';
  @State private error: string = '';

  private async toggle(): Promise<void> {
    if (this.loading) { return; }
    if (this.expanded) { this.expanded = false; return; }
    if (this.text) { this.expanded = true; return; }
    this.loading = true;
    this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = await context.resourceManager.getRawFileContent(this.item.resource);
      const text = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
      if (!text.trim()) { throw new Error('Empty license resource: ' + this.item.resource); }
      this.text = text;
      this.expanded = true;
    } catch (error) {
      this.error = t('无法读取许可文本：{0}', [this.item.resource + ' · ' + (error as Error).message]);
    } finally { this.loading = false; }
  }

  build() {
    GroupCard() {
      Column() {
        Column({ space: Space.sm }) {
          Text(this.item.name).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).width('100%')
          Text(t('许可证：{0}', [this.item.license])).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
            .fontColor($r('app.color.text_secondary')).width('100%')
          Text(this.item.copyright).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(20)
            .fontColor($r('app.color.text_secondary')).width('100%').copyOption(CopyOptions.LocalDevice)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(Space.lg)
        RowDivider()
        NavRow({ title: this.expanded ? t('收起许可全文') : t('展开许可全文'),
          compId: 'license-toggle-' + this.item.id, trailing: 'expand', active: this.expanded,
          disabled: this.loading, onTap: () => this.toggle() })
        if (this.error) { Banner({ text: this.error, compId: 'license-error-' + this.item.id }) }
        if (this.expanded) {
          Text(this.text).fontFamily(this.appearance.fontFamily).id('license-text-' + this.item.id).fontSize(Font.small).lineHeight(22)
            .fontColor($r('app.color.text_secondary')).width('100%').padding(Space.lg)
            .copyOption(CopyOptions.LocalDevice)
        }
      }.width('100%')
    }
  }
}

@Component
export struct ThirdPartyLicensesPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  build() {
    Scroll() {
      Column({ space: Space.md }) {
        Text(t('感谢开源社区。本应用使用或参考了以下开源组件与设计，版权归各自权利人所有。展开可离线查看随应用附带的原文；各组件适用其自身许可证。')).fontFamily(this.appearance.fontFamily)
          .fontSize(Font.small).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        ForEach(THIRD_PARTY_LICENSES, (item: ThirdPartyLicense) => {
          LicenseCard({ item: item })
        }, (item: ThirdPartyLicense) => item.id)
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
    }.id('third-party-licenses').height('100%').width('100%').align(Alignment.Top)
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }
}
