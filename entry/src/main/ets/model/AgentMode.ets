import { t } from './I18n';
import { BASIC_FILE_TOOLS, OPTIONAL_TOOL_NAMES } from './ToolGroups';

export type AgentMode = 'full' | 'custom';
export const AGENT_MODES: AgentMode[] = ['full', 'custom'];
export interface ToolSelection { agentMode?: AgentMode; disabledTools?: string[]; }

export function validateAgentMode(mode: string): void {
  if (!AGENT_MODES.includes(mode as AgentMode)) { throw new Error(t('Agent 模式无效。')); }
}

export function validateToolSelection(selection: ToolSelection): void {
  if (selection.agentMode !== undefined) { validateAgentMode(selection.agentMode); }
  const disabled = selection.disabledTools;
  if (disabled === undefined) { return; }
  if (!Array.isArray(disabled) || disabled.length > OPTIONAL_TOOL_NAMES.length || new Set(disabled).size !== disabled.length ||
    disabled.some((name) => !OPTIONAL_TOOL_NAMES.includes(name))) {
    throw new Error(t('自定义工具设置无效。'));
  }
}

export function toolEnabled(name: string, selection: ToolSelection): boolean {
  if (BASIC_FILE_TOOLS.includes(name) || selection.agentMode !== 'custom') { return true; }
  if (selection.disabledTools?.includes(name)) { return false; }
  // Delegation cannot start or resume without the worker's required handoff.
  return !['team_recruit', 'team_resume'].includes(name) || !selection.disabledTools?.includes('team_complete_task');
}

export function agentModeName(mode: AgentMode): string {
  return mode === 'custom' ? t('自定义') : t('全部');
}
