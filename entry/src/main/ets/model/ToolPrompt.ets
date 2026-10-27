import { ToolDefinition } from './Agent';
import { PromptSection } from './ContextProjection';

// Contributions follow the executable catalog after permission/role filtering.
export function toolPromptSections(tools: ToolDefinition[]): PromptSection[] {
  const snippets: string[] = [];
  const guidelines = new Set<string>();
  if (tools.length) {
    guidelines.add('Read each tool receipt conclusion: failed/cancelled means the requested operation did not fully succeed; partial means observations or content were reduced. Inspect code, recovery, notices and orchestration issues. Preserve completed effects and continue paging when cursors are present; do not repeat successful writes merely to recover missing observations.');
  }
  for (const tool of tools) {
    const snippet = tool.promptSnippet?.replace(/\s+/g, ' ').trim();
    if (snippet) { snippets.push('- ' + tool.function.name + ': ' + snippet); }
    for (const rule of tool.promptGuidelines || []) {
      if (rule.trim()) { guidelines.add(rule.trim()); }
    }
  }
  return [{ name: 'tools', content: snippets.join('\n') },
    { name: 'tool_guidelines', content: Array.from(guidelines).map((rule) => '- ' + rule).join('\n') }];
}
