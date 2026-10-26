import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { StorageUsage } from '../services/StorageUsage';
import { StorageCategorySummary, StorageEntry, StorageEntryResult, StorageReport, emptyStorageEntryResult,
  emptyStorageReport, storageCategoryKey } from '../model/StoragePlan';
import { Btn, Font, Radius, Space, storageSize } from '../common/Theme';
import { Banner, EmptyState, GroupCard, IconButton, NavRow, RowDivider, SectionHeader, Tag } from '../common/Widgets';

function categoryIcon(id: string): Resource {
  if (id === 'sessions') { return $r('sys.symbol.ellipsis_message'); }
  if (id === 'workspace') { return $r('sys.symbol.folder'); }
  if (id === 'attachments') { return $r('sys.symbol.doc'); }
  if (id === 'backups') { return $r('sys.symbol.archivebox'); }
  if (id === 'usage') { return $r('sys.symbol.clock'); }
  if (id === 'diagnostics') { return $r('sys.symbol.wrench_and_screwdriver'); }
  if (id === 'cache') { return $r('sys.symbol.rectangle_stack'); }
  return $r('sys.symbol.doc_text');
}

@Component
export struct StoragePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.storage.revision') @Watch('storageChanged') private storageRevision: number = 0;
  @ObjectLink app: ChatViewModel;
  onCategory: (id: string) => void = () => {};
  @State private report: StorageReport = emptyStorageReport();
  @State private loading: boolean = true;
  @State private error: string = '';
  @State private status: string = '';
  @State private busy: boolean = false;
  private mounted: boolean = false;
  private revision: number = 0;

  aboutToAppear(): void { this.mounted = true; this.scan(); }
  aboutToDisappear(): void { this.mounted = false; this.revision++; }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.app.busy || this.busy; }
  // A category page deletes an item; refresh the overview underneath it right away.
  private storageChanged(): void { if (this.mounted) { this.scan(); } }

  private async scan(): Promise<void> {
    const revision = ++this.revision;
    this.loading = true; this.error = '';
    try {
      const report = await StorageUsage.scan(this.context(), this.app.exportSnapshot());
      if (this.mounted && revision === this.revision) { this.report = report; this.loading = false; }
    } catch (error) {
      if (this.mounted && revision === this.revision) { this.error = (error as Error).message; this.loading = false; }
    }
  }

  private confirmClean(): void {
    if (this.locked() || this.report.safeBytes <= 0) { return; }
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('清理这些数据？'),
      message: t('将删除缓存、临时文件、未使用的附件和已删除会话残留的工作区，共 {0}。聊天记录和工作区文件不会被删除。', [storageSize(this.report.safeBytes)]),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('清理'), fontColor: $r('app.color.danger'), action: () => this.clean() } });
  }

  private async clean(): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.status = ''; this.error = '';
    try {
      const result = await StorageUsage.cleanSafe(this.context(), this.app.exportSnapshot());
      let message = result.failed > 0 ? t('已释放 {0}，有 {1} 项未能删除。', [storageSize(result.freedBytes), result.failed])
        : t('已释放 {0}。', [storageSize(result.freedBytes)]);
      if (result.incomplete) { message = t('部分目录无法读取，清理可能不完整。') + ' ' + message; }
      this.status = message;
      await this.scan();
    } catch (error) { this.error = (error as Error).message; }
    finally { if (this.mounted) { this.busy = false; } }
  }

  private deviceKnown(): boolean {
    return this.report.deviceBytes > 0 && this.report.freeBytes > 0 && this.report.freeBytes <= this.report.deviceBytes;
  }
  private deviceUsed(): number { return this.deviceKnown() ? this.report.deviceBytes - this.report.freeBytes : 0; }
  private devicePercent(): number {
    if (!this.deviceKnown()) { return 0; }
    return Math.min(100, Math.round(this.deviceUsed() / this.report.deviceBytes * 100));
  }

  @Builder
  summary() {
    GroupCard() {
      Column({ space: Space.md }) {
        Row() {
          Column({ space: 2 }) {
            Text(t('Tinybot 数据')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
            Text(storageSize(this.report.totalBytes)).fontFamily(this.appearance.fontFamily)
              .fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.deviceKnown()) {
            Column({ space: 2 }) {
              Text(t('设备可用')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
              Text(storageSize(this.report.freeBytes)).fontFamily(this.appearance.fontFamily)
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            }.alignItems(HorizontalAlign.End)
          }
        }.width('100%')
        if (this.deviceKnown()) {
          Progress({ value: this.deviceUsed(), total: this.report.deviceBytes, type: ProgressType.Linear })
            .width('100%').color(this.appearance.accent).backgroundColor($r('app.color.surface_variant'))
          Text(t('设备已用 {0}%', [this.devicePercent()])).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
        }
        Text(t('统计只包含 Tinybot 私有目录，不含共享文件夹中的文件。')).fontFamily(this.appearance.fontFamily)
          .fontSize(Font.caption).lineHeight(18).fontColor($r('app.color.text_tertiary'))
      }.width('100%').padding(Space.lg)
    }
  }

  @Builder
  cleanCard() {
    GroupCard() {
      Column({ space: Space.md }) {
        Row({ space: Space.md }) {
          Column({ space: 3 }) {
            Row({ space: Space.sm }) {
              Text(t('建议清理')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              if (this.report.safeBytes > 0) {
                Tag({ text: t('可释放 {0}', [storageSize(this.report.safeBytes)]), strong: true })
              }
            }.width('100%')
            Text(t('缓存、临时文件、未使用的附件和已删除会话残留的工作区。聊天记录与工作区文件不会被删除。'))
              .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(18)
              .fontColor($r('app.color.text_secondary'))
            if (this.report.safeBytes > 0) {
              Text(t('缓存 {0} · 未使用附件 {1} · 残留工作区 {2}', [storageSize(this.report.cacheCleanBytes),
                storageSize(this.report.orphanAttachmentBytes), storageSize(this.report.orphanWorkspaceBytes)]))
                .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(18)
                .fontColor($r('app.color.text_tertiary'))
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.busy) {
            LoadingProgress().width(24).height(24).color(this.appearance.accent)
          }
        }.width('100%').alignItems(VerticalAlign.Top)
        Button(t('清理')).fontFamily(this.appearance.fontFamily).id('clean-storage').attributeModifier(Btn.primarySmall)
          .enabled(!this.locked() && this.report.safeBytes > 0 && !this.loading)
          .onClick(() => this.confirmClean())
      }.width('100%').padding(Space.lg)
    }
  }

  @Builder
  categories() {
    SectionHeader({ title: t('占用明细'), caption: t('点按类别查看占用最大的文件') })
    GroupCard() {
      Column() {
        ForEach(this.report.categories, (item: StorageCategorySummary, index: number) => {
          if (index > 0) { RowDivider() }
          NavRow({ title: t(storageCategoryKey(item.id)), icon: categoryIcon(item.id), value: storageSize(item.bytes),
            subtitle: t('{0} 个文件', [item.files]), compId: 'storage-category-' + item.id,
            disabled: this.loading, onTap: () => this.onCategory(item.id) })
        }, (item: StorageCategorySummary) => item.id + ':' + item.bytes + ':' + item.files)
      }
    }
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        if (this.loading) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color(this.appearance.accent)
            Text(t('正在统计存储占用…')).fontFamily(this.appearance.fontFamily).fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }.width('100%').padding({ top: Space.sm })
        }
        if (this.status.length > 0) { Banner({ text: this.status, danger: false, compId: 'storage-status' }) }
        if (this.error.length > 0) { Banner({ text: this.error, compId: 'storage-error' }) }
        if (this.report.incomplete) {
          Banner({ text: t('部分目录无法读取，统计结果可能不完整。'), danger: false,
            icon: $r('sys.symbol.exclamationmark_circle'), compId: 'storage-incomplete' })
        }
        this.summary()
        this.cleanCard()
        this.categories()
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.lock')).fontSize(16).fontColor([$r('app.color.text_secondary')])
          Text(t('删除会话、清理工作区或导出备份，请分别使用「会话」「文件」和「备份与恢复」。'))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(18).layoutWeight(1)
            .fontColor($r('app.color.text_secondary'))
        }.width('100%').alignItems(VerticalAlign.Top).padding(Space.md).borderRadius(Radius.md)
        .backgroundColor($r('app.color.surface_variant'))
        Button(t('重新统计')).fontFamily(this.appearance.fontFamily).id('refresh-storage').attributeModifier(Btn.tonalSmall)
          .enabled(!this.locked() && !this.loading).onClick(() => this.scan())
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
    }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
  }
}

@Component
export struct StorageCategoryPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @Prop category: string = 'sessions';
  @State private result: StorageEntryResult = emptyStorageEntryResult();
  @State private loading: boolean = true;
  @State private error: string = '';
  @State private status: string = '';
  @State private busy: boolean = false;
  private mounted: boolean = false;
  private revision: number = 0;

  aboutToAppear(): void { this.mounted = true; this.load(); }
  aboutToDisappear(): void { this.mounted = false; this.revision++; }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.app.busy || this.busy; }

  private note(): string {
    if (this.category === 'sessions') { return t('会话文件由应用维护，不能单独删除。'); }
    if (this.category === 'workspace') { return t('工作区文件请在文件面板中管理；已删除会话残留的文件可以直接删除，整个目录请使用“建议清理”。'); }
    if (this.category === 'attachments') { return t('只删除没有被任何会话引用的附件；使用中的附件会保留。'); }
    if (this.category === 'backups') { return t('删除修改备份后，将无法再恢复对应的修改前内容。'); }
    if (this.category === 'cache') { return t('缓存可以随时清理；刚生成的文件稍后才会出现清理入口。'); }
    if (this.category === 'diagnostics') { return t('诊断日志在开发者模式中清除。'); }
    if (this.category === 'feedback') { return t('反馈附件随反馈记录管理。'); }
    return t('用量账本用于统计，不建议删除。');
  }

  private total(): number {
    let total = 0;
    for (const entry of this.result.entries) { total += entry.bytes; }
    return total;
  }

  private async load(): Promise<void> {
    const revision = ++this.revision;
    this.loading = true; this.error = '';
    try {
      const result = await StorageUsage.entries(this.context(), this.app.exportSnapshot(), this.category);
      if (this.mounted && revision === this.revision) { this.result = result; this.loading = false; }
    } catch (error) {
      if (this.mounted && revision === this.revision) { this.error = (error as Error).message; this.loading = false; }
    }
  }

  private confirmDelete(entry: StorageEntry): void {
    if (this.locked()) { return; }
    const warning = entry.directory ? t('将删除整个残留工作区，删除后无法恢复。') : t('删除后无法恢复。');
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('删除这项？'),
      message: entry.label + '\n' + warning,
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('删除'), fontColor: $r('app.color.danger'), action: () => this.remove(entry) } });
  }

  private async remove(entry: StorageEntry): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.status = '';
    try {
      const result = await StorageUsage.remove(this.context(), [entry]);
      if (result.removed > 0 || result.freedBytes > 0) {
        this.status = result.failed > 0
          ? t('已释放 {0}，有 {1} 项未能删除。', [storageSize(result.freedBytes), result.failed])
          : t('已释放 {0}。', [storageSize(result.freedBytes)]);
        AppStorage.setOrCreate('tinybot.storage.revision', Date.now());
      } else { this.error = t('未能删除，请稍后重试。'); }
      await this.load();
    } catch (error) { this.error = (error as Error).message; }
    finally { if (this.mounted) { this.busy = false; } }
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        GroupCard() {
          Column({ space: 4 }) {
            Row() {
              Text(t(storageCategoryKey(this.category))).fontFamily(this.appearance.fontFamily)
                .fontSize(Font.body).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(storageSize(this.total())).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
                .fontColor(this.appearance.accent)
            }.width('100%')
            Text(this.note()).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(18)
              .fontColor($r('app.color.text_secondary'))
          }.width('100%').padding(Space.lg)
        }
        if (this.status.length > 0) { Banner({ text: this.status, danger: false, compId: 'storage-category-status' }) }
        if (this.error.length > 0) { Banner({ text: this.error, compId: 'storage-category-error' }) }
        if (this.result.incomplete) {
          Banner({ text: t('部分目录无法读取，统计结果可能不完整。'), danger: false,
            icon: $r('sys.symbol.exclamationmark_circle'), compId: 'storage-category-incomplete' })
        }
        if (this.loading) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color(this.appearance.accent)
            Text(t('正在统计存储占用…')).fontFamily(this.appearance.fontFamily).fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }.width('100%').padding(Space.md)
        } else if (this.result.entries.length === 0) {
          EmptyState({ icon: $r('sys.symbol.folder'), title: t('这里还没有占用空间的文件') })
        } else {
          GroupCard() {
            Column() {
              ForEach(this.result.entries, (entry: StorageEntry, index: number) => {
                if (index > 0) { RowDivider() }
                Row({ space: Space.sm }) {
                  Column({ space: 3 }) {
                    Text(entry.label).fontFamily(this.appearance.fontFamily).fontSize(Font.small).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
                    Text(entry.detail).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  Text(storageSize(entry.bytes)).fontFamily(this.appearance.fontFamily).fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                  if (entry.removable) {
                    IconButton({ icon: $r('sys.symbol.trash'), tint: $r('app.color.danger'), label: t('删除') + ' ' + entry.label,
                      diameter: 36, iconSize: 18, compId: 'storage-entry-delete-' + index,
                      disabled: this.locked(), onTap: () => this.confirmDelete(entry) })
                  }
                }.width('100%').constraintSize({ minHeight: 56 })
                .padding({ left: Space.lg, right: Space.xs, top: 8, bottom: 8 })
              }, (entry: StorageEntry) => entry.path + ':' + entry.bytes)
            }
          }
          if (this.result.entries.length >= 300) {
            Text(t('仅显示占用最大的 300 项。')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
              .fontColor($r('app.color.text_tertiary')).width('100%')
          }
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
    }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
  }
}
