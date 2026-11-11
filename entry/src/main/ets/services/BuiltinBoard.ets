import { common } from '@kit.AbilityKit';
import { builtinWidget, guideWidgets } from '../model/BuiltinWidgets';
import { BALANCE_PANEL_HTML } from '../model/BalancePanelTemplate';
import { PanelEntry, PanelSpec } from '../model/LifePanel';
import { BoardItem, PanelTarget } from '../model/LifeBoard';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { webUiPage } from '../model/WebUi';
import { t } from '../model/I18n';
import { BuiltinWidgets } from './BuiltinWidgets';
import { LifeBoards } from './LifeBoards';
import { LifePanels } from './LifePanels';
import { Cancellation } from './Cancellation';
import { withFileMutation } from './FileMutationQueue';
import { ProviderBalanceSource } from './ProviderBalanceSource';
import { gridVacancy } from '../model/PanelGrid';

const GUIDE_WORKSPACE: string = 'tinybot-builtins';
const GUIDE_BOARD: string = 'board-welcome';
const DAILY_BOARD: string = 'board-daily';
export class BuiltinBoard {
  private context: common.Context;
  constructor(context: common.Context) { this.context = context; }
  async prepare(cancellation: Cancellation): Promise<PanelTarget | undefined> {
    const filesDir = this.context.getApplicationContext().filesDir;
    return withFileMutation('builtin-board:' + filesDir, async (): Promise<PanelTarget | undefined> => {
      cancellation.check();
      const panels = new LifePanels(filesDir), boards = new LifeBoards(filesDir);
      // AI-edited cards have their own source path/thread. Update only untouched packaged instances.
      for (const entry of await panels.list()) { await this.updatePackaged(panels, entry, cancellation); }
      const existingBoards = await boards.list();
      const existing = existingBoards.find((entry) => entry.workspaceId === GUIDE_WORKSPACE && entry.board.id === GUIDE_BOARD);
      cancellation.check();
      await new WorkspaceStore(filesDir).ensureThread(GUIDE_WORKSPACE);
      const repository = panels.repository(GUIDE_WORKSPACE), widgets = new BuiltinWidgets(this.context);
      if (!existing) {
        const items: BoardItem[] = [];
        for (const guide of guideWidgets()) {
          cancellation.check();
          const id = 'panel-' + guide.id;
          if (!await repository.lookup(id)) {
            await repository.publish(id, await widgets.definition(guide.id), 'builtin-widgets/' + guide.id + '.html', '', false, cancellation);
          }
          const size = builtinWidget(guide.id);
          items.push({ workspaceId: GUIDE_WORKSPACE, panelId: id, x: guide.id === 'guide-resize' ? 6 : 0,
            y: guide.id === 'guide-welcome' ? 0 : 8, w: size.width, h: size.height });
        }
        cancellation.check();
        // Stable IDs let an interrupted first install resume without duplicating cards.
        await boards.create(GUIDE_WORKSPACE, GUIDE_BOARD, t('看板入门'), t('直接在指引卡片上练习移动和缩放，再用右上角加号添加自己的卡片。'), items);
      }
      const daily = existingBoards.find((entry) => entry.workspaceId === GUIDE_WORKSPACE && entry.board.id === DAILY_BOARD);
      const target: PanelTarget = { workspaceId: GUIDE_WORKSPACE, boardId: DAILY_BOARD };
      // Introduce the banner once, retaining existing placements and later user removals.
      if (daily) {
        if (daily.board.archived) { return undefined; }
        if (!daily.board.builtinRevision) {
          const id = 'panel-default-ascii';
          if (!await repository.lookup(id)) {
            await repository.publish(id, await widgets.definition('ascii'), 'builtin-widgets/ascii.html', '', false, cancellation);
          }
          cancellation.check();
          await boards.prependBuiltin(GUIDE_WORKSPACE, DAILY_BOARD, { workspaceId: GUIDE_WORKSPACE, panelId: id }, 5, 1);
        }
        return target;
      }
      const balance = ProviderBalanceSource.accounts().length > 0;
      const ids: string[] = balance ? ['ascii', 'clock', 'balance', 'todo', 'focus', 'countdown'] : ['ascii', 'clock', 'todo', 'focus', 'countdown'];
      const items: BoardItem[] = [];
      for (const widgetId of ids) {
        cancellation.check();
        const id = 'panel-default-' + widgetId;
        if (!await repository.lookup(id)) {
          await repository.publish(id, await widgets.definition(widgetId), 'builtin-widgets/' + widgetId + '.html', '', false, cancellation);
        }
        const widget = builtinWidget(widgetId);
        const rect = gridVacancy(items, widgetId === 'clock' && !balance ? 12 : widget.width, widgetId === 'balance' ? 7 : widget.height);
        items.push({ workspaceId: GUIDE_WORKSPACE, panelId: id, x: rect.x, y: rect.y, w: rect.w, h: rect.h });
      }
      cancellation.check();
      await boards.create(GUIDE_WORKSPACE, DAILY_BOARD, t('我的日常'), t('时间、待办与值得期待的事，打开就能用。'), items, 1);
      return target;
    });
  }
  private async updatePackaged(panels: LifePanels, entry: PanelEntry, cancellation: Cancellation): Promise<void> {
    const panel = entry.panel;
    if (panel.archived || panel.sourceThreadId || !panel.definition.view) { return; }
    const guide = guideWidgets().find((widget) => panel.sourcePath === 'builtin-widgets/' + widget.id + '.html');
    const balance = panel.sourcePath === 'builtin-widgets/balance.html';
    const ascii = panel.sourcePath === 'builtin-widgets/ascii.html';
    if (!balance && !guide && !ascii) { return; }
    cancellation.check();
    const definition = JSON.parse(JSON.stringify(panel.definition)) as PanelSpec;
    definition.view = balance ? webUiPage('balance.html', BALANCE_PANEL_HTML) : (await new BuiltinWidgets(this.context).definition(ascii ? 'ascii' : guide!.id)).view;
    definition.view!.height = panel.definition.view.height;
    if (JSON.stringify(definition.view) === JSON.stringify(panel.definition.view)) { return; }
    if (balance) { definition.checks = (definition.checks || []).filter((check) => check.selector !== '#privacy'); }
    await panels.repository(entry.workspaceId).publish(panel.id, definition, panel.sourcePath, '', true, cancellation,
      { expectedRevision: panel.configRevision });
  }
}
