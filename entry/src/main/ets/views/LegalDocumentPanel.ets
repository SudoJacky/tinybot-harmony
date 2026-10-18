import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Font, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { t } from '../model/I18n';
import { MarkdownView } from './MarkdownView';

@Component
export struct LegalDocumentPanel {
  @Prop kind: 'privacy' | 'terms' = 'privacy';
  @State private content: string = '';
  @State private error: string = '';

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const resource = this.kind === 'terms' ? 'user-agreement.md' : 'privacy-policy.md';
      const bytes = context.resourceManager.getRawFileContentSync(resource);
      this.content = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
      if (!this.content.trim()) { throw new Error('Empty legal document: ' + resource); }
    } catch (error) {
      this.error = (this.kind === 'terms' ? t('用户协议') : t('隐私政策')) + '：' + (error as Error).message;
    }
  }

  build() {
    Scroll() {
      Column() {
        if (this.error) {
          Banner({ text: this.error, compId: this.kind === 'terms' ? 'user-agreement-error' : 'privacy-policy-error' })
        } else {
          MarkdownView({ content: this.content, fontSize: Font.body, selectable: true })
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
    }.id(this.kind === 'terms' ? 'user-agreement-page' : 'privacy-policy-page').width('100%').height('100%').align(Alignment.Top)
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }
}
