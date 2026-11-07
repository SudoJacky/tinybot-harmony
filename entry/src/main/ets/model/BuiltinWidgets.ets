import { PanelSpec } from './LifePanel';
import { miniAppPage } from './MiniApp';
import { PanelCheck } from './PanelContract';
import { t } from './I18n';

export interface BuiltinWidget {
  id: string; title: string; description: string; label: string; color: string;
  width: number; height: number; checks: PanelCheck[];
}
// A catalog of finished cards. Adding one creates an independent, editable instance.
export function builtinWidgets(): BuiltinWidget[] {
  return [
    { id: 'balance', title: t('余额与额度'), description: t('模型服务账户，一眼掌握'), label: t('已连接的模型服务'), color: '#547C70', width: 6, height: 6, checks: [] },
    { id: 'clock', title: t('此刻'), description: t('时间、日期与一周节奏'), label: t('本地时钟'), color: '#8E755A', width: 6, height: 7,
      checks: [{ action: 'click', selector: '#format' }, { action: 'stored', path: '/hour12', expected: true }] },
    { id: 'focus', title: t('专注片刻'), description: t('给眼前的事，一段完整时间'), label: t('专注计时'), color: '#B36A51', width: 12, height: 9,
      checks: [{ action: 'click', selector: '#reset' }, { action: 'stored', path: '/remaining', expected: 1500 }] },
    { id: 'todo', title: t('今日小事'), description: t('写下、完成，轻一点前行'), label: t('待办清单'), color: '#5F8471', width: 12, height: 9,
      checks: [{ action: 'input', selector: '#new-task', value: 'A small step' }, { action: 'click', selector: '#add-task' },
        { action: 'stored', path: '/items/0/text', expected: 'A small step' }] },
    { id: 'countdown', title: t('值得期待'), description: t('为重要的日子，留一个位置'), label: t('倒数日'), color: '#7E75A1', width: 12, height: 9,
      checks: [{ action: 'input', selector: '#event-name', value: 'A good day' }, { action: 'input', selector: '#event-date', value: '2030-01-01' },
        { action: 'click', selector: '#save-event' }, { action: 'stored', path: '/date', expected: '2030-01-01' }] }
  ];
}
export function builtinWidget(id: string): BuiltinWidget {
  const widget = builtinWidgets().concat(guideWidgets()).find((item: BuiltinWidget) => item.id === id);
  if (!widget) { throw new Error('Unknown built-in widget'); }
  return widget;
}
export function guideWidgets(): BuiltinWidget[] {
  return [
    { id: 'guide-welcome', title: t('让日常，有条不紊'), description: '', label: '', color: '#4E8172', width: 12, height: 8, checks: [] },
    { id: 'guide-move', title: t('长按左上角，拖动排序'), description: '', label: '', color: '#668B78', width: 6, height: 10, checks: [] },
    { id: 'guide-resize', title: t('长按右下角，改变大小'), description: '', label: '', color: '#8A7BB2', width: 6, height: 10, checks: [] }
  ];
}
export function builtinWidgetSpec(id: string, html: string): PanelSpec {
  const widget = builtinWidget(id);
  return { version: 2, title: widget.title, size: 'M', nodes: [], data: {} as Record<string, Object>,
    dataSchema: { type: 'object', additionalProperties: false }, checks: widget.checks,
    view: miniAppPage(id + '.html', html) };
}
