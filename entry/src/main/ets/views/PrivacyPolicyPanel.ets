import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Font, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { t } from '../model/I18n';
import { MarkdownView } from './MarkdownView';

@Component
export struct PrivacyPolicyPanel {
  @State private content: string = '';
  @State private error: string = '';

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = context.resourceManager.getRawFileContentSync('privacy-policy.md');
      this.content = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
      if (!this.content.trim()) { throw new Error('Empty privacy policy resource'); }
    } catch (error) {
      this.error = t('隐私政策') + '：' + (error as Error).message;
    }
  }

  build() {
    Scroll() {
      Column() {
        if (this.error) {
          Banner({ text: this.error, compId: 'privacy-policy-error' })
        } else {
          MarkdownView({ content: this.content, fontSize: Font.body, selectable: true })
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
    }.id('privacy-policy-page').width('100%').height('100%').align(Alignment.Top)
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }
}
