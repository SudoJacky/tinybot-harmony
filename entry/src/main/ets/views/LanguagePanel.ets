import { Space } from '../common/Theme';
import { AppLanguage, t } from '../model/I18n';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Banner, GroupCard, NavRow, RowDivider } from '../common/Widgets';

export function languageName(choice: string): string {
  return choice === 'system' ? t('跟随系统') : choice === 'zh-CN' ? '简体中文' : 'English';
}

@Component
export struct LanguagePanel {
  @StorageProp('tinybot.language') private language: string = 'system';
  @ObjectLink app: ChatViewModel;
  @State private error: string = '';
  @State private selecting: boolean = false;
  private disposed: boolean = false;

  aboutToDisappear(): void { this.disposed = true; }
  private canEdit(): boolean { return !this.selecting && (!this.app.busy || this.app.saving) && this.app.saveError.length === 0; }
  private async select(choice: AppLanguage): Promise<void> {
    if (!this.canEdit()) { return; }
    this.selecting = true; this.error = '';
    try {
      await this.app.flushDraft();
      if (this.disposed || this.app.saveError) { return; }
      LanguagePreferences.select(choice);
    } catch (_) {
      if (!this.disposed) { this.error = t('无法保存语言设置，请重试。'); }
    } finally { this.selecting = false; }
  }

  build() {
    Column({ space: Space.md }) {
      GroupCard() {
        Column() {
          ForEach(['system', 'zh-CN', 'en'], (choice: string, index: number) => {
            if (index > 0) { RowDivider() }
            NavRow({ title: languageName(choice), trailing: 'select', active: this.language === choice,
              compId: 'language-' + choice, disabled: !this.canEdit(), onTap: () => this.select(choice as AppLanguage) })
          }, (choice: string) => choice)
        }
      }
      if (this.error || this.app.saveError) { Banner({ text: this.error || this.app.saveError }) }
    }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
  }
}
