import { AgentStep, toolReceipts } from './Agent';

export interface PresentedFile { path: string; description?: string; }
interface DeliveryReceipt { files?: PresentedFile[]; }

export function deliveredFiles(steps: AgentStep[]): PresentedFile[] {
  const files: PresentedFile[] = [];
  for (const step of steps) {
    for (const tool of toolReceipts(step.tools)) {
      // Team-worker files must still be presented explicitly in this workspace.
      if (tool.call.function.name !== 'present_files' || tool.status !== 'complete') { continue; }
      let receipt: DeliveryReceipt;
      try { receipt = JSON.parse(tool.output) as DeliveryReceipt; }
      catch (_) { continue; }
      if (!Array.isArray(receipt?.files)) { continue; }
      for (const file of receipt.files) {
        if (file && typeof file.path === 'string' && !files.some((item) => item.path === file.path)) {
          files.push({ path: file.path, description: typeof file.description === 'string' ? file.description : undefined });
        }
      }
    }
  }
  return files;
}
