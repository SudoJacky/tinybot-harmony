import { AgentStep, toolReceipts } from './Agent';
import { PanelTarget, parsePanelTarget } from './LifeBoard';
export interface PublishedPanel { key: string; title: string; target: PanelTarget; excludedPanelKeys?: string[]; }
interface Receipt { workspaceId?: string; panelId?: string; boardId?: string; title?: string; }
export function publishedPanels(steps: AgentStep[]): PublishedPanel[] {
  const links: Map<string, PublishedPanel> = new Map<string, PublishedPanel>();
  for (const step of steps) {
    for (const tool of toolReceipts(step.tools)) {
      if (tool.status !== 'complete' || !['publish_life_panel', 'manage_life_board'].includes(tool.call.function.name)) { continue; }
      const receipt = JSON.parse(tool.output) as Receipt;
      // Older receipts predate shared navigation targets; retain readable history.
      if (!receipt.workspaceId) { continue; }
      const target = parsePanelTarget(JSON.stringify({ workspaceId: receipt.workspaceId, panelId: receipt.panelId, boardId: receipt.boardId } as PanelTarget));
      const key = target.workspaceId + '/' + (target.panelId || target.boardId);
      links.set(key, { key: key, title: receipt.title || 'Life Panel', target: target });
    }
  }
  const published = Array.from(links.values());
  const panelKeys = published.filter((item: PublishedPanel) => !!item.target.panelId).map((item: PublishedPanel) => item.key);
  // A board receipt retains its navigation and other cards, without repeating standalone previews from this answer.
  for (const item of published) {
    if (item.target.boardId) { item.excludedPanelKeys = panelKeys; }
  }
  return published;
}
