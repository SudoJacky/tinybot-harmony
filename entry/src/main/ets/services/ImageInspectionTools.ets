import { ToolCall, ToolDefinition } from '../model/Agent';
import { Attachment } from '../model/Productivity';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { MAX_IMAGE_BYTES, rasterMime } from './ImageGenerationTools';
import { workspaceRelativePath } from './WorkspaceTools';

interface ImageInspectionArguments { path: string; }
interface ImageInspectionResult { path: string; mime: string; }

export class ImageInspectionTools implements AgentTools {
  private readImage: (path: string, maximum: number, cancellation: Cancellation) => Promise<Uint8Array>;
  private saveInspection: (bytes: Uint8Array, name: string) => Promise<Attachment>;

  constructor(readImage: (path: string, maximum: number, cancellation: Cancellation) => Promise<Uint8Array>,
    saveInspection: (bytes: Uint8Array, name: string) => Promise<Attachment>) {
    this.readImage = readImage;
    this.saveInspection = saveInspection;
  }

  definitions(): ToolDefinition[] {
    return [{ type: 'function', executionMode: 'sequential', promptSnippet: 'Inspect a local image visually',
      function: { name: 'view_image',
        description: 'Show a PNG, JPEG or WebP from this workspace or a known photo attachment to a vision-capable chat model. Use it to inspect an image_gen result before a targeted revision. The text receipt identifies the source; the image is sent separately. Does not change the source.',
        parameters: { type: 'object', properties: { 'path': { type: 'string',
          description: 'Exact workspace-relative path or conversation photo reference.' } }, required: ['path'], additionalProperties: false } } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    const args = parseToolArguments(call.function.arguments) as ImageInspectionArguments;
    if (call.function.name !== 'view_image' || !args || typeof args.path !== 'string' ||
      Object.keys(args).some((key) => key !== 'path')) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected a single local image path.', 'fix_arguments');
    }
    if (!context) { throw new Error('Image inspection requires a durable tool invocation context'); }
    const path = workspaceRelativePath(args.path, false);
    const bytes = await this.readImage(path, MAX_IMAGE_BYTES, cancellation);
    const mime = rasterMime(bytes);
    if (!mime) { throw new ToolFailure('UNSUPPORTED_CONTENT', 'Expected a PNG, JPEG or WebP image.', 'fix_path', { path: path }); }
    cancellation.check();
    context.execution.inspectedImage = await this.saveInspection(bytes, path.slice(path.lastIndexOf('/') + 1).slice(0, 200));
    const result: ImageInspectionResult = { path: path, mime: mime };
    return JSON.stringify(result);
  }
}
