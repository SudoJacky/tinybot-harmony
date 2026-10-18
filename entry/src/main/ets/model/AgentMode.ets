import { t } from './I18n';
import { BASIC_FILE_TOOLS, OPTIONAL_TOOL_NAMES, MANAGED_TOOL_NAMES, TOOL_CAPABILITIES } from './ToolGroups';

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
  const known = OPTIONAL_TOOL_NAMES.concat(MANAGED_TOOL_NAMES);
  if (!Array.isArray(disabled) || disabled.length > known.length || new Set(disabled).size !== disabled.length ||
    disabled.some((name) => !known.includes(name))) {
    throw new Error(t('自定义工具设置无效。'));
  }
}

export function toolEnabled(name: string, selection: ToolSelection): boolean {
  if (BASIC_FILE_TOOLS.includes(name) || MANAGED_TOOL_NAMES.includes(name) || selection.agentMode !== 'custom') { return true; }
  const capability = TOOL_CAPABILITIES.find((item) => item.tools.includes(name));
  return !(capability ? capability.tools : [name]).some((tool) => selection.disabledTools?.includes(tool));
}

// Preserve denials within selectable capabilities; discard obsolete memory/Skills overrides.
export function normalizeDisabledTools(names: string[]): string[] {
  return TOOL_CAPABILITIES.filter((capability) => capability.tools.some((name) => names.includes(name)))
    .flatMap((capability) => capability.tools);
}

export function agentModeName(mode: AgentMode): string {
  return mode === 'custom' ? t('自定义') : t('全部');
}
