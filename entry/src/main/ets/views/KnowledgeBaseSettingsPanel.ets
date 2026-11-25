import { common } from '@kit.AbilityKit';
import { PageStyles } from '../common/PageStyles';
import { Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, SectionHeader, SwitchRow } from '../common/Widgets';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { imaClient } from '../services/ImaClient';
import { knowledgeBaseAccess } from '../services/KnowledgeBaseAccess';

@Component
export struct KnowledgeBaseSettingsPanel {
  @State private ready: boolean = false;
  @State private saving: boolean = false;
  @State private accessEnabled: boolean = false;
  @State private accessError: string = '';
  @State private imaError: string = '';
  @State private imaStatus: string = '';
  private mounted: boolean = false;
  onIma: (onReturn: () => void) => void = () => {};

  aboutToAppear(): void {
    this.mounted = true;
    try {
      knowledgeBaseAccess.initialize(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.accessEnabled = knowledgeBaseAccess.enabled;
      this.ready = true;
      if (this.accessEnabled) { this.reloadIma(); }
    } catch (error) { this.reportAccess(error as Error, 'load_failed'); }
  }

  aboutToDisappear(): void { this.mounted = false; }

  private async reloadIma(): Promise<void> {
    this.imaError = '';
    try {
      const settings = await imaClient.load();
      if (this.mounted) {
        this.imaStatus = settings ? (settings.enabled ? t('已启用') : t('已停用')) : t('未连接');
      }
    } catch (error) {
      Diagnostics.log('warn', 'ima', 'settings_failed', {}, error as Error);
      if (this.mounted) { this.imaStatus = ''; this.imaError = (error as Error).message; }
    }
  }

  private reportAccess(error: Error, event: string): void {
    Diagnostics.log('warn', 'knowledge-base', event, {}, error);
    this.accessError = error.message;
  }

  private async toggle(value: boolean): Promise<void> {
    if (!this.ready || this.saving) { return; }
    this.accessError = ''; this.saving = true;
    try {
      await knowledgeBaseAccess.setEnabled(value);
      if (!this.mounted) { return; }
      this.accessEnabled = knowledgeBaseAccess.enabled;
      if (this.accessEnabled) { await this.reloadIma(); }
    } catch (error) { this.reportAccess(error as Error, 'save_failed'); }
    finally { this.saving = false; }
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        GroupCard() {
          SwitchRow({ title: t('启用知识库'), isOn: this.accessEnabled, disabled: !this.ready || this.saving, compId: 'knowledge-bases-enabled',
            subtitle: t('关闭后，助手会停止访问所有知识库服务，已保存的连接会保留。'),
            onChange: (value: boolean) => this.toggle(value) })
        }
        if (this.accessError) { Banner({ text: this.accessError, compId: 'knowledge-base-access-error' }) }
        if (this.accessEnabled) {
          SectionHeader({ title: t('知识库服务') })
          GroupCard() {
            NavRow({ title: t('腾讯 ima 知识库'), icon: $r('sys.symbol.doc_text'), subtitle: t('检索、读取和导入腾讯 ima 知识库资料'),
              value: this.imaStatus, disabled: this.saving, compId: 'configure-ima-knowledge-base', onTap: () => this.onIma(() => this.reloadIma()) })
          }
          if (this.imaError) { Banner({ text: this.imaError, compId: 'knowledge-base-ima-error' }) }
        }
      }.width('100%').padding(Space.page).attributeModifier(PageStyles.form)
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor($r('app.color.page_background'))
  }
}
