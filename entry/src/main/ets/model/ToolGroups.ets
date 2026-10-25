// Shared inventory for custom selection and existing read-only permissions.
export interface ToolGroup { id: string; readOnly: boolean; tools: string[]; }
export const BASIC_FILE_TOOLS: string[] = ['list_files', 'find_files', 'read_file', 'search_file_content', 'write_file', 'edit_file'];
export const TOOL_GROUPS: ToolGroup[] = [
  { id: 'workspace-read', readOnly: true, tools: ['list_files', 'find_files', 'read_file', 'search_file_content'] },
  { id: 'workspace-write', readOnly: false, tools: ['write_file', 'edit_file'] },
  { id: 'context-read', readOnly: true, tools: ['read_attachment', 'read_reference'] },
  { id: 'web', readOnly: true, tools: ['read_web', 'search_web'] },
  { id: 'browser', readOnly: true, tools: ['browser_open', 'browser_snapshot', 'browser_action', 'browser_handoff', 'browser_close'] },
  { id: 'calculation', readOnly: true, tools: ['execute_code'] },
  { id: 'orchestration', readOnly: true, tools: ['orchestrate'] },
  { id: 'interaction', readOnly: true, tools: ['request_user_input', 'update_plan'] },
  { id: 'delivery', readOnly: true, tools: ['publish_preview', 'present_files'] },
  { id: 'skill-read', readOnly: true, tools: ['read_skill', 'list_skills'] },
  { id: 'mcp-discovery', readOnly: true, tools: ['mcp_search_tools', 'mcp_list_tools'] },
  { id: 'mcp-execution', readOnly: false, tools: ['mcp_call'] },
  { id: 'extension-management', readOnly: false, tools: ['skill_manage', 'mcp_manage'] },
  { id: 'memory', readOnly: false, tools: ['memory'] },
  { id: 'team-coordination', readOnly: true, tools: ['team_recruit', 'team_wait', 'team_inspect', 'team_read_result', 'team_control', 'team_resume'] },
  { id: 'team-handoff', readOnly: true, tools: ['team_complete_task', 'team_list_messages', 'team_read_message'] }
];
// Governed by assistant settings and the dedicated Skills page, never conversation switches.
export const MANAGED_TOOL_NAMES: string[] = ['memory', 'read_skill', 'list_skills', 'skill_manage'];

// User-facing capabilities are independent of the read-only permission groups above.
export interface ToolCapability { id: string; section: string; tools: string[]; }
function groupTools(ids: string[]): string[] {
  return TOOL_GROUPS.filter((group) => ids.includes(group.id)).flatMap((group) => group.tools);
}
export const TOOL_CAPABILITIES: ToolCapability[] = [
  { id: 'context-read', section: 'research', tools: groupTools(['context-read']) },
  { id: 'web', section: 'research', tools: groupTools(['web']) },
  { id: 'browser', section: 'research', tools: groupTools(['browser']) },
  { id: 'calculation', section: 'execution', tools: groupTools(['calculation']) },
  { id: 'orchestration', section: 'execution', tools: groupTools(['orchestration']) },
  { id: 'user-input', section: 'execution', tools: ['request_user_input'] },
  { id: 'plan', section: 'execution', tools: ['update_plan'] },
  { id: 'team', section: 'execution', tools: groupTools(['team-coordination', 'team-handoff']) },
  { id: 'preview', section: 'delivery', tools: ['publish_preview'] },
  { id: 'file-delivery', section: 'delivery', tools: ['present_files'] },
  { id: 'mcp', section: 'extensions', tools: groupTools(['mcp-discovery', 'mcp-execution']) },
  { id: 'mcp-manage', section: 'extensions', tools: ['mcp_manage'] }
];
export const OPTIONAL_TOOL_NAMES: string[] = TOOL_CAPABILITIES.flatMap((capability) => capability.tools);

export const READ_ONLY_BROWSER_ACTIONS: string[] = ['scroll', 'back', 'forward', 'reload'];
