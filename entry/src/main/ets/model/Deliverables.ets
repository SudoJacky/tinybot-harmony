import { AgentStep, ToolExecution, toolReceipts } from './Agent';

export interface PresentedFile { path: string; description?: string; generatedImage?: boolean; }
interface DeliveryReceipt { files?: PresentedFile[]; }
interface ImageArguments { aspect_ratio?: string; reference_images?: string[]; }
export interface ImageDelivery { id: string; path: string; ratio: number; references?: string[]; compareReference?: string; }

function receiptFiles(tool: ToolExecution, generated: boolean): PresentedFile[] {
  try {
    const receipt = JSON.parse(tool.output) as DeliveryReceipt;
    if (!Array.isArray(receipt?.files)) { return []; }
    return receipt.files.filter((file) => file && typeof file.path === 'string' &&
      (!generated || /^generated-images\/[A-Za-z0-9-]+\.(png|jpg|webp)$/.test(file.path)));
  } catch (_) { return []; }
}

function imageArguments(tool: ToolExecution): ImageArguments {
  try {
    return (JSON.parse(tool.call.function.arguments) as ImageArguments) || {};
  } catch (_) { return {}; }
}

function requestedImageRatio(ratio?: string): number {
  return ratio === '3:2' ? 3 / 2 : ratio === '2:3' ? 2 / 3 : 1;
}

export function latestImageDelivery(steps: AgentStep[], active: boolean): ImageDelivery | undefined {
  for (let index = steps.length - 1; index >= 0; index--) {
    const tools = toolReceipts(steps[index].tools);
    for (let position = tools.length - 1; position >= 0; position--) {
      const tool = tools[position];
      if (tool.call.function.name !== 'image_gen') { continue; }
      const id = index + '-' + tool.call.id;
      if (active && tool.status === 'running') {
        const args = imageArguments(tool);
        const refs = args.reference_images;
        const delivery: ImageDelivery = { id: id, path: '', ratio: requestedImageRatio(args.aspect_ratio) };
        if (Array.isArray(refs) && refs.length > 0 && refs.length <= 4 &&
          refs.every((path) => typeof path === 'string' && path.length > 0)) {
          delivery.references = refs;
          if (refs.length === 1) { delivery.compareReference = refs[0]; }
        }
        return delivery;
      } else if (tool.status === 'complete') {
        const files = receiptFiles(tool, true);
        if (files.length) {
          const args = imageArguments(tool);
          const refs = args.reference_images;
          const delivery: ImageDelivery = { id: id, path: files[files.length - 1].path, ratio: requestedImageRatio(args.aspect_ratio) };
          if (Array.isArray(refs) && refs.length === 1 && typeof refs[0] === 'string' && refs[0]) {
            delivery.compareReference = refs[0];
          }
          return delivery;
        }
      }
    }
  }
  return undefined;
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
