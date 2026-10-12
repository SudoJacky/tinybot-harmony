import { AgentStep } from './Agent';

// Presentation only. Model history uses step.content and the compact tool receipt.
export function stepDisplayContent(step: AgentStep): string {
  return [step.content].concat(step.tools.filter((tool) => tool.status === 'complete' &&
    tool.call.function.name === 'publish_preview' && !!tool.previewContent).map((tool) => tool.previewContent as string))
    .filter((content) => content.length > 0).join('\n\n');
}
