import { t } from './I18n';

export type ToolApprovalMode = 'ask' | 'full';

export function toolApprovalMode(value?: string): ToolApprovalMode {
  return value === 'full' ? 'full' : 'ask';
}

export function toolApprovalModeName(mode: ToolApprovalMode): string {
  return mode === 'full' ? t('完全访问') : t('请求审批');
}
