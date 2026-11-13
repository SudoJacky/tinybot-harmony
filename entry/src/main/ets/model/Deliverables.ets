import { AgentStep, toolReceipts } from './Agent';

export interface PresentedFile { path: string; description?: string; generatedImage?: boolean; }
interface DeliveryReceipt { files?: PresentedFile[]; }

export function deliveredFiles(steps: AgentStep[]): PresentedFile[] {
  const files: PresentedFile[] = [];
  for (const step of steps) {
    for (const tool of toolReceipts(step.tools)) {
      // Team-worker files must still be presented explicitly in this workspace.
      const generated = tool.call.function.name === 'image_gen';
      if ((!generated && tool.call.function.name !== 'present_files') || tool.status !== 'complete') { continue; }
      let receipt: DeliveryReceipt;
      try { receipt = JSON.parse(tool.output) as DeliveryReceipt; }
      catch (_) { continue; }
      if (!Array.isArray(receipt?.files)) { continue; }
      for (const file of receipt.files) {
        if (!file || typeof file.path !== 'string' ||
          (generated && !/^generated-images\/[A-Za-z0-9-]+\.(png|jpg|webp)$/.test(file.path))) { continue; }
        const previous = files.find((item) => item.path === file.path);
        if (previous) {
          if (generated) { previous.generatedImage = true; }
          continue;
        }
        const delivery: PresentedFile = { path: file.path, description: typeof file.description === 'string' ? file.description : undefined };
        if (generated) { delivery.generatedImage = true; }
        files.push(delivery);
      }
    }
  }
  return files;
}
