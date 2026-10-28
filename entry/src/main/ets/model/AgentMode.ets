import { t } from './I18n';
import { BASIC_FILE_TOOLS, OPTIONAL_TOOL_NAMES, MANAGED_TOOL_NAMES, TOOL_CAPABILITIES } from './ToolGroups';
import { isConfigurationName } from './ConfigurationValue';

export type AgentMode = 'full' | 'custom';
export const AGENT_MODES: AgentMode[] = ['full', 'custom'];
// Tools that no longer exist but may still appear in saved selections.
export const REMOVED_TOOL_NAMES: string[] = ['generate_image', 'read_tool_result', 'publish_data_view'];
export interface ToolSelection { agentMode?: string; disabledTools?: string[]; }

export function validateAgentMode(mode: string): void {
  if (!AGENT_MODES.includes(mode as AgentMode)) { throw new Error(t('Agent 模式无效。')); }
}

export function knownDisabledTool(name: string): boolean {
  return OPTIONAL_TOOL_NAMES.concat(MANAGED_TOOL_NAMES, REMOVED_TOOL_NAMES).includes(name);
}
export function validateToolSelection(selection: ToolSelection, stored: boolean = false): void {
  if (selection.agentMode !== undefined) {
    if (!isConfigurationName(selection.agentMode)) { throw new Error(t('Agent 模式无效。')); }
    if (!stored) { validateAgentMode(selection.agentMode); }
  }
  const disabled = selection.disabledTools;
  if (disabled === undefined) { return; }
  // Accept removed tools in old saves; normalize their selections before use.
  if (!Array.isArray(disabled) || disabled.length > 256 || new Set(disabled).size !== disabled.length ||
    disabled.some((name) => !isConfigurationName(name) || BASIC_FILE_TOOLS.includes(name) || (!stored && !knownDisabledTool(name)))) {
    throw new Error(t('自定义工具设置无效。'));
  }
}

export function toolEnabled(name: string, selection: ToolSelection): boolean {
  // A newer permission mode cannot authorize any tool in an older runtime.
  if (selection.agentMode !== undefined && !AGENT_MODES.includes(selection.agentMode as AgentMode)) { return false; }
  if (BASIC_FILE_TOOLS.includes(name) || MANAGED_TOOL_NAMES.includes(name) || selection.agentMode !== 'custom') { return true; }
  const capability = TOOL_CAPABILITIES.find((item) => item.tools.includes(name));
  return !(capability ? capability.tools : [name]).some((tool) => selection.disabledTools?.includes(tool));
}

// Preserve denials within selectable capabilities; discard obsolete memory/Skills overrides.
export function normalizeDisabledTools(names: string[]): string[] {
  // The retired chart tool shared the preview switch; retain that denial on upgrade.
  const migrated = names.includes('publish_data_view') ? names.concat(['publish_preview']) : names;
  return names.filter((name) => !knownDisabledTool(name)).concat(TOOL_CAPABILITIES.filter((capability) => capability.tools.some((name) => migrated.includes(name)))
    .flatMap((capability) => capability.tools));
}

export function agentModeName(mode: string): string {
  return mode === 'custom' ? t('自定义') : mode === 'full' ? t('全部') : t('当前版本不支持');
}
