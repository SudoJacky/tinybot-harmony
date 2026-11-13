import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { PresentedFile } from '../model/Deliverables';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { FileJobWorkspace } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';

export const MAX_IMAGE_BYTES: number = 16 * 1024 * 1024;
export const IMAGE_ASPECT_RATIOS: string[] = ['1:1', '3:2', '2:3'];

export interface ImageGenerationInput {
  prompt: string;
  reference_images?: string[];
  aspect_ratio?: string;
  transparent_background?: boolean;
}

export interface ImageReference {
  bytes: Uint8Array;
  mime: string;
}

export interface ImageGenerator {
  generate(input: ImageGenerationInput, references: ImageReference[], cancellation: Cancellation): Promise<Uint8Array>;
}

export function rasterMime(bytes: Uint8Array): string {
  if (bytes.length >= 24 && [137, 80, 78, 71, 13, 10, 26, 10].every((value, index) => bytes[index] === value)) {
    return 'image/png';
  }
  if (bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) { return 'image/jpeg'; }
  if (bytes.length >= 16 && [82, 73, 70, 70].every((value, index) => bytes[index] === value) &&
    [87, 69, 66, 80].every((value, index) => bytes[index + 8] === value)) { return 'image/webp'; }
  return '';
}

export class ImageGenerationTools implements AgentTools {
  private generator: ImageGenerator;
  private files: FileJobWorkspace;
  private createId: () => string;
  private supportsTransparency: boolean;
  private approve?: (input: ImageGenerationInput, paths: string[], cancellation: Cancellation) => Promise<void>;
  constructor(generator: ImageGenerator, files: FileJobWorkspace, createId: () => string, supportsTransparency: boolean,
    approve?: (input: ImageGenerationInput, paths: string[], cancellation: Cancellation) => Promise<void>) {
    this.generator = generator;
    this.files = files;
    this.createId = createId;
    this.supportsTransparency = supportsTransparency;
    this.approve = approve;
  }

  definitions(): ToolDefinition[] {
    const properties: Record<string, ToolProperty> = {
      'prompt': { type: 'string', minLength: 1, maxLength: 32000,
        description: 'Describe the image to create or the changes to make, including the subject, composition and style.' },
      'reference_images': { type: 'array', maxItems: 4,
        items: { type: 'string', description: 'A PNG, JPEG or WebP workspace path, or the exact photo reference from the conversation.' },
        description: 'For edits or visual references, supply file paths from attachments or previous successful tool results, in order.' },
      'aspect_ratio': { type: 'string', enum: IMAGE_ASPECT_RATIOS, description: 'Optional output aspect ratio. Omit to use the image model default.' }
    };
    if (this.supportsTransparency) {
      properties['transparent_background'] = { type: 'boolean',
        description: 'Request a transparent background. Requires a model that supports transparency.' };
    }
    return [{ type: 'function', executionMode: 'sequential', promptSnippet: 'Generate or edit an image',
      promptGuidelines: ['Use image_gen when the user asks to generate or edit an image. For edits, describe what to change and what to preserve.',
        'The successful result is displayed in chat and saved in the workspace. Report the result briefly and use its path for future edits.'],
      function: { name: 'image_gen', description: 'Generate one image from a text prompt, with optional reference images. Saves and delivers the result in the current workspace.',
        parameters: { type: 'object', properties: properties, required: ['prompt'], additionalProperties: false } } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const input = parseToolArguments(call.function.arguments) as ImageGenerationInput;
    if (call.function.name !== 'image_gen' || !input || Array.isArray(input) ||
      Object.keys(input).some((key) => !['prompt', 'reference_images', 'aspect_ratio', 'transparent_background'].includes(key)) ||
      typeof input.prompt !== 'string' || !input.prompt.trim() || input.prompt.length > 32000 ||
      (input.aspect_ratio !== undefined && !IMAGE_ASPECT_RATIOS.includes(input.aspect_ratio)) ||
      (input.transparent_background !== undefined && (!this.supportsTransparency || typeof input.transparent_background !== 'boolean')) ||
      (input.reference_images !== undefined && (!Array.isArray(input.reference_images) || input.reference_images.length > 4 ||
        input.reference_images.some((path) => typeof path !== 'string')))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Check the image prompt, reference paths and supported options.', 'fix_arguments');
    }
    input.prompt = input.prompt.trim();
    const paths = (input.reference_images || []).map((path) => workspaceRelativePath(path, false));
    if (new Set(paths).size !== paths.length) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Reference images must have distinct paths.', 'fix_arguments');
    }
    let remaining = MAX_IMAGE_BYTES;
    const references: ImageReference[] = [];
    for (const path of paths) {
      const bytes = await this.files.readJobInput(path, remaining, cancellation);
      const mime = rasterMime(bytes);
      if (!mime) { throw new ToolFailure('INVALID_ARGUMENTS', 'Reference must be a PNG, JPEG or WebP image.', 'fix_path', { path: path }); }
      remaining -= bytes.length;
      references.push({ bytes: bytes, mime: mime });
    }
    if (this.approve) { await this.approve(input, paths, cancellation); }
    const bytes = await this.generator.generate(input, references, cancellation);
    const mime = rasterMime(bytes);
    if (!mime || bytes.length > MAX_IMAGE_BYTES) {
      throw new ToolFailure('INVALID_RESPONSE', 'Image service returned an invalid or oversized raster image.', 'inspect_service');
    }
    const path = 'generated-images/' + this.createId() + '.' + (mime === 'image/jpeg' ? 'jpg' : mime.slice(6));
    await this.files.createJobOutput(path, bytes, cancellation);
    const file: PresentedFile = { path: path };
    return JSON.stringify({ path: path, mime: mime, bytes: bytes.length, files: [file] });
  }
}
