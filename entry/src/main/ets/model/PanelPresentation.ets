import { getLocale, t } from './I18n';
import { PanelRecord, PanelRun } from './LifePanel';

// Known application errors can also be present in records saved by older versions.
export function panelErrorText(message: string): string {
  if (message === 'API authentication is not connected for this request. Open the card connection settings.') { return t('API 尚未连接，请在卡片选项中打开「API 连接」。'); }
  if (message === 'OAuth connection is unavailable; reconnect the card') { return t('OAuth 连接不可用，请重新连接卡片。'); }
  if (message === 'OAuth token could not be loaded or renewed. Reconnect the card.') { return t('OAuth 凭据无法读取或续期，请重新连接卡片。'); }
  if (message === 'API key is unavailable; reconnect the card') { return t('API 凭据不可用，请重新连接卡片。'); }
  return message;
}
export function panelRunTrigger(run: PanelRun): string {
  if (run.trigger === 'automatic') { return t('自动触发'); }
  if (run.trigger === 'manual') { return t('手动触发'); }
  if (run.trigger === 'agent' || run.trigger === 'tool') { return t('助手触发'); }
  return t('触发方式未记录');
}
export function panelRunLabel(run: PanelRun): string {
  const status: Record<string, string> = { 'running': t('运行中'), 'complete': t('已完成'), 'failed': t('失败'), 'cancelled': t('已取消'), 'interrupted': t('运行已中断') };
  return status[run.status] + ' · ' + panelRunTrigger(run) + ' · ' + new Date(run.startedAt).toLocaleString(getLocale());
}
export function panelSourceLabel(panel: PanelRecord): string {
  const type = panel.definition.source?.type;
  return type === 'api' ? t('API 数据源') : type === 'workspace-json' ? t('工作区文件') : type === 'agent' ? t('Agent 内容更新') : type === 'mail' ? t('邮箱数据刷新') : t('本地数据');
}
export interface PanelRect { x: number; y: number; width: number; height: number; }
// Measured card heights keep short lists compact and place later cards below all
// columns they span. Geometry is shared by rendering and drag hit testing.
export function panelMasonry(width: number, columns: number, spans: number[], heights: number[]): PanelRect[] {
  const gap = 12, unit = (width - gap * (columns - 1)) / columns;
  const bottoms: number[] = Array(columns).fill(0);
  return spans.map((span: number, index: number): PanelRect => {
    const count = Math.min(columns, Math.max(1, span));
    let column = 0, top = Number.MAX_VALUE;
    for (let start = 0; start <= columns - count; start++) {
      const candidate = Math.max(...bottoms.slice(start, start + count));
      if (candidate < top) { top = candidate; column = start; }
    }
    const height = heights[index] || 180;
    for (let i = column; i < column + count; i++) { bottoms[i] = top + height + gap; }
    return { x: column * (unit + gap), y: top, width: count * (unit + gap) - gap, height: height };
  });
}
