import { ToolDefinition } from './Agent';
import { PromptSection } from './ContextProjection';

// Contributions follow the executable catalog after permission/role filtering.
export function toolPromptSections(tools: ToolDefinition[]): PromptSection[] {
  const snippets: string[] = [];
  const guidelines = new Set<string>();
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
