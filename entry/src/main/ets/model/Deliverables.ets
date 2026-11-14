import { AgentStep, ToolExecution, toolReceipts } from './Agent';

export interface PresentedFile { path: string; description?: string; generatedImage?: boolean; }
interface DeliveryReceipt { files?: PresentedFile[]; }
interface ImageArguments { aspect_ratio?: string; }
export interface ImageDelivery { id: string; path: string; ratio: number; }

function receiptFiles(tool: ToolExecution, generated: boolean): PresentedFile[] {
  try {
    const receipt = JSON.parse(tool.output) as DeliveryReceipt;
    if (!Array.isArray(receipt?.files)) { return []; }
    return receipt.files.filter((file) => file && typeof file.path === 'string' &&
      (!generated || /^generated-images\/[A-Za-z0-9-]+\.(png|jpg|webp)$/.test(file.path)));
  } catch (_) { return []; }
}

function requestedImageRatio(tool: ToolExecution): number {
  try {
    const args = JSON.parse(tool.call.function.arguments) as ImageArguments;
    if (args?.aspect_ratio === '3:2') { return 3 / 2; }
    if (args?.aspect_ratio === '2:3') { return 2 / 3; }
  } catch (_) { return 1; }
  return 1;
}

export function imageDeliveries(steps: AgentStep[], active: boolean): ImageDelivery[] {
  const images: ImageDelivery[] = [];
  const paths = new Set<string>();
  steps.forEach((step, index) => {
    for (const tool of toolReceipts(step.tools)) {
      if (tool.call.function.name !== 'image_gen') { continue; }
      const id = index + '-' + tool.call.id;
      if (active && tool.status === 'running') {
        images.push({ id: id, path: '', ratio: requestedImageRatio(tool) });
      } else if (tool.status === 'complete') {
        receiptFiles(tool, true).forEach((file, fileIndex) => {
          if (paths.has(file.path)) { return; }
          paths.add(file.path);
          images.push({ id: fileIndex === 0 ? id : id + '-' + fileIndex,
            path: file.path, ratio: requestedImageRatio(tool) });
        });
      }
    }
  });
  return images;
}

export function deliveredFiles(steps: AgentStep[]): PresentedFile[] {
  const files: PresentedFile[] = [];
  for (const step of steps) {
    for (const tool of toolReceipts(step.tools)) {
      // Team-worker files must still be presented explicitly in this workspace.
      const generated = tool.call.function.name === 'image_gen';
      if ((!generated && tool.call.function.name !== 'present_files') || tool.status !== 'complete') { continue; }
      for (const file of receiptFiles(tool, generated)) {
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
