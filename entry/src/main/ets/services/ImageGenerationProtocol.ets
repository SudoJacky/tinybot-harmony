import { ImageServiceAccess } from '../model/ProviderProfiles';
import { protocolUrl, providerEndpointRoot } from '../model/ProviderEndpoint';
import { ToolFailure, parseToolResponse } from '../model/ToolFailure';
import { ImageGenerationInput, ImageReference } from './ImageGenerationTools';

export interface ImageRequest {
  url: string;
  headers: Record<string, string>;
  body: string | ArrayBuffer;
}
export interface EncodedImage { base64?: string; url?: string; }
export interface ImageEncoding {
  base64: (bytes: Uint8Array) => string;
  utf8: (text: string) => Uint8Array;
  boundary: () => string;
}

interface GeminiImagePart { type: string; text?: string; mime_type?: string; data?: string; }
interface GeminiImageFormat { type: string; aspect_ratio?: string; }
interface GeminiImageRequest { model: string; input: GeminiImagePart[]; response_format: GeminiImageFormat; store: boolean; }
interface GeminiImageStep { type: string; content?: GeminiImagePart[]; }
interface DashScopePart { text?: string; image?: string; }
interface DashScopeMessage { role?: string; content?: DashScopePart[]; }
interface DashScopeInput { messages: DashScopeMessage[]; }
interface DashScopeParameters { n: number; size?: string; }
interface DashScopeImageRequest { model: string; input: DashScopeInput; parameters: DashScopeParameters; }
interface DashScopeChoice { message?: DashScopeMessage; }
interface DashScopeOutput { choices?: DashScopeChoice[]; }
interface SeedreamRequest { model: string; prompt: string; size?: string; image?: string | string[]; }
interface ImagesItem { b64_json?: string; url?: string; error?: Object; }
interface ImageResponse {
  data?: ImagesItem[];
  error?: Object;
  code?: string;
  status?: string;
  steps?: GeminiImageStep[];
  output?: DashScopeOutput;
}

function dataUrl(reference: ImageReference, encoding: ImageEncoding): string {
  return 'data:' + reference.mime + ';base64,' + encoding.base64(reference.bytes);
}

function dimensions(ratio: string | undefined, seedream: boolean): string | undefined {
  if (ratio === '1:1') { return seedream ? '2048x2048' : '1024x1024'; }
  if (ratio === '3:2') { return seedream ? '2496x1664' : '1536x1024'; }
  if (ratio === '2:3') { return seedream ? '1664x2496' : '1024x1536'; }
  return undefined;
}

function multipart(fields: Record<string, string>, references: ImageReference[], boundary: string, encoding: ImageEncoding): ArrayBuffer {
  const chunks: Uint8Array[] = [];
  const delimiter = '--' + boundary + '\r\n';
  for (const field of Object.keys(fields)) {
    chunks.push(encoding.utf8(delimiter + 'Content-Disposition: form-data; name="' + field + '"\r\n\r\n' + fields[field] + '\r\n'));
  }
  references.forEach((reference, index) => {
    const extension = reference.mime === 'image/jpeg' ? 'jpg' : reference.mime.slice(6);
    chunks.push(encoding.utf8(delimiter + 'Content-Disposition: form-data; name="image[]"; filename="reference-' +
      (index + 1) + '.' + extension + '"\r\nContent-Type: ' + reference.mime + '\r\n\r\n'),
      reference.bytes, encoding.utf8('\r\n'));
  });
  chunks.push(encoding.utf8('--' + boundary + '--\r\n'));
  const result = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result.buffer as ArrayBuffer;
}

export function imageRequest(profile: ImageServiceAccess, model: string, key: string, input: ImageGenerationInput,
  references: ImageReference[], encoding: ImageEncoding): ImageRequest {
  const protocol = profile.protocol;
  const endpoint = protocolUrl(protocol, profile.baseUrl, true);
  const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
  if (key) {
    if (protocol === 'gemini-images') { headers['x-goog-api-key'] = key; }
    else { headers['Authorization'] = 'Bearer ' + key; }
  }
  const size = dimensions(input.aspect_ratio, protocol === 'seedream-images');
  if (protocol === 'gemini-images') {
    const parts: GeminiImagePart[] = [{ type: 'text', text: input.prompt }];
    for (const reference of references) {
      parts.push({ type: 'image', mime_type: reference.mime, data: encoding.base64(reference.bytes) });
    }
    const payload: GeminiImageRequest = { model: model, input: parts, store: false,
      response_format: { type: 'image', aspect_ratio: input.aspect_ratio } };
    return { url: endpoint, headers: headers, body: JSON.stringify(payload) };
  }
  if (protocol === 'dashscope-images') {
    const content: DashScopePart[] = references.map((reference): DashScopePart => ({ image: dataUrl(reference, encoding) }));
    content.push({ text: input.prompt });
    const payload: DashScopeImageRequest = { model: model, input: { messages: [{ role: 'user', content: content }] },
      parameters: { n: 1, size: size?.replace('x', '*') } };
    return { url: endpoint, headers: headers, body: JSON.stringify(payload) };
  }
  if (protocol === 'seedream-images') {
    const images = references.map((reference) => dataUrl(reference, encoding));
    const payload: SeedreamRequest = { model: model, prompt: input.prompt, size: size,
      image: images.length === 0 ? undefined : images.length === 1 ? images[0] : images };
    return { url: endpoint, headers: headers, body: JSON.stringify(payload) };
  }
  if (protocol !== 'openai-images') {
    throw new ToolFailure('NOT_CONFIGURED', 'Configure a supported image generation protocol.', 'check_settings');
  }
  const fields: Record<string, string> = { 'model': model, 'prompt': input.prompt };
  if (size) { fields['size'] = size; }
  if (input.transparent_background) { fields['background'] = 'transparent'; fields['output_format'] = 'png'; }
  if (references.length > 0) {
    const boundary = encoding.boundary();
    headers['Content-Type'] = 'multipart/form-data; boundary=' + boundary;
    return { url: providerEndpointRoot(endpoint) + '/images/edits', headers: headers, body: multipart(fields, references, boundary, encoding) };
  }
  return { url: endpoint, headers: headers, body: JSON.stringify(fields) };
}

export function imageResponse(protocol: string, body: string): EncodedImage {
  const result = parseToolResponse(body) as ImageResponse;
  if (result?.error || result?.code) {
    const code = typeof result.code === 'string' && /^[A-Za-z0-9_.-]{1,80}$/.test(result.code) ? ' (' + result.code + ')' : '';
    throw new ToolFailure('IMAGE_SERVICE_ERROR', 'The image service rejected the request' + code + '.', 'inspect_service');
  }
  if (protocol === 'gemini-images') {
    if (result?.status !== 'completed') {
      throw new ToolFailure('IMAGE_SERVICE_ERROR', 'Gemini did not complete the image generation request.', 'inspect_service');
    }
    for (const step of Array.isArray(result.steps) ? result.steps : []) {
      const parts = step?.content;
      if (step?.type !== 'model_output' || !Array.isArray(parts)) { continue; }
      for (const part of parts) {
        if (part?.type === 'image' && typeof part.data === 'string' && part.data.length > 0) { return { base64: part.data }; }
      }
    }
  } else if (protocol === 'dashscope-images') {
    const choices = result?.output?.choices;
    for (const choice of Array.isArray(choices) ? choices : []) {
      const content = choice?.message?.content;
      if (!Array.isArray(content)) { continue; }
      const part = content.find((item) => typeof item?.image === 'string' && item.image.length > 0);
      if (part) { return { url: part.image }; }
    }
  } else if (['openai-images', 'seedream-images'].includes(protocol) && Array.isArray(result?.data)) {
    const item = result.data[0];
    if (item?.error) { throw new ToolFailure('IMAGE_SERVICE_ERROR', 'The image service reported that generation failed.', 'inspect_service'); }
    if (typeof item?.b64_json === 'string' && item.b64_json.length > 0) { return { base64: item.b64_json }; }
    if (typeof item?.url === 'string' && item.url.length > 0) { return { url: item.url }; }
  }
  throw new ToolFailure('INVALID_RESPONSE', 'The image service returned no generated image.', 'inspect_service');
}
