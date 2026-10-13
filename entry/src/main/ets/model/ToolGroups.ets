// Shared inventory for custom selection and existing read-only permissions.
export interface ToolGroup { id: string; readOnly: boolean; tools: string[]; }
export const BASIC_FILE_TOOLS: string[] = ['list_files', 'find_files', 'read_file', 'read_file_lines', 'search_file_content', 'write_file', 'edit_file'];
export const TOOL_GROUPS: ToolGroup[] = [
  { id: 'workspace-read', readOnly: true, tools: ['list_files', 'find_files', 'read_file', 'read_file_lines', 'search_file_content'] },
  { id: 'workspace-write', readOnly: false, tools: ['write_file', 'edit_file'] },
  { id: 'context-read', readOnly: true, tools: ['read_attachment', 'read_reference', 'read_tool_result'] },
  { id: 'web', readOnly: true, tools: ['read_web', 'search_web'] },
  { id: 'browser', readOnly: true, tools: ['browser_open', 'browser_snapshot', 'browser_action', 'browser_handoff', 'browser_close'] },
  { id: 'calculation', readOnly: true, tools: ['execute_code'] },
  { id: 'orchestration', readOnly: true, tools: ['orchestrate'] },
  { id: 'interaction', readOnly: true, tools: ['request_user_input', 'update_plan'] },
  { id: 'delivery', readOnly: true, tools: ['publish_preview', 'publish_data_view', 'present_files'] },
  { id: 'image', readOnly: false, tools: ['generate_image'] },
  { id: 'skill-read', readOnly: true, tools: ['read_skill', 'list_skills'] },
  { id: 'mcp-discovery', readOnly: true, tools: ['mcp_search_tools', 'mcp_list_tools'] },
  { id: 'mcp-execution', readOnly: false, tools: ['mcp_call'] },
  { id: 'extension-management', readOnly: false, tools: ['skill_manage', 'mcp_manage'] },
  { id: 'memory', readOnly: false, tools: ['memory'] },
  { id: 'team-coordination', readOnly: true, tools: ['team_recruit', 'team_wait', 'team_inspect', 'team_read_result', 'team_control', 'team_resume'] },
  { id: 'team-handoff', readOnly: true, tools: ['team_complete_task', 'team_list_messages', 'team_read_message'] }
];
export const OPTIONAL_TOOL_NAMES: string[] = TOOL_GROUPS.flatMap((group) => group.tools).filter((name) => !BASIC_FILE_TOOLS.includes(name));

export const READ_ONLY_BROWSER_ACTIONS: string[] = ['scroll', 'back', 'forward', 'reload'];
