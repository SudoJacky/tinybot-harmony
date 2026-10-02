import { t } from '../model/I18n';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { Attachment } from '../model/Productivity';
import { ProviderProfile, ModelReference } from '../model/ProviderProfiles';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { CredentialStore } from './CredentialStore';
import { Attachments, readBounded, writeBytes } from './Attachments';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { ToolApproval } from './ToolApproval';
import { protocolUrl } from './providers/WireProtocols';
interface ImageArguments { prompt: string; source?: string; }
interface ImageDatum { b64_json?: string; url?: string; }
interface ImageResponse { data: ImageDatum[]; }
export interface ImageResult { path: string; attachment: Attachment; }
export class ImageTools implements AgentTools {
  private profile: ProviderProfile; private model: string; private root: string; private approval: ToolApproval; private attachments: Attachment[];
  constructor(profile: ProviderProfile, reference: ModelReference, root: string, approval: ToolApproval, attachments: Attachment[]) {
    this.profile = profile; this.model = reference.modelId; this.root = root; this.approval = approval; this.attachments = attachments.filter((item) => item.mime === 'image/jpeg');
  }
  definitions(): ToolDefinition[] {
    const sources = this.attachments.map((item) => item.id + ': ' + item.name).join('\n');
    return [{ type: 'function', function: { name: 'generate_image', description: '按描述生成图片，或编辑已有图片。使用配置的图片模型，可能产生费用。输出保存到工作区，可继续编辑。可用附件 ID：\n' + sources,
      parameters: { type: 'object', properties: { 'prompt': { type: 'string', description: '图片生成或编辑要求' },
        'source': { type: 'string', description: '编辑时使用图片附件 ID 或工作区相对路径；生成新图时省略' } }, required: ['prompt'], additionalProperties: false } } }];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    const args = JSON.parse(call.function.arguments) as ImageArguments;
    if (!args || typeof args.prompt !== 'string' || !args.prompt.trim() || args.prompt.length > 8000 || (args.source !== undefined && typeof args.source !== 'string')) { throw new Error(t("图片描述需为 1–8000 字符。")); }
    cancellation.check();
    await this.approval.request(t('图片模型 · {0}', [this.model]), args.prompt + (args.source ? t('\n参考图片：{0}', [args.source]) : ''), cancellation);
    const base = protocolUrl(this.profile.protocol, this.profile.baseUrl, true).replace(/\/(chat\/completions|responses|messages)$/, '');
    const key = await new CredentialStore().read(this.profile.credentialAlias); cancellation.check();
    let body: string | ArrayBuffer; let contentType = 'application/json';
    if (args.source) {
      const attachment = this.attachments.find((item) => item.id === args.source);
      const path = attachment ? Attachments.path(attachment) : await new NativeWorkspaceFiles(this.root).checkedPath(args.source);
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW); let bytes: ArrayBuffer;
      try { bytes = await readBounded(file.fd, 8 * 1024 * 1024); } finally { await fs.close(file); }
      const magic = new Uint8Array(bytes); const png = magic[0] === 137 && magic[1] === 80;
      if (!png && !(magic[0] === 255 && magic[1] === 216)) { throw new Error(t("图片编辑支持 PNG 或 JPEG。")); }
      const boundary = 'tinybot-' + util.generateRandomUUID(); const encoder = new util.TextEncoder();
      const prefix = encoder.encodeInto('--' + boundary + '\r\nContent-Disposition: form-data; name="model"\r\n\r\n' + this.model +
        '\r\n--' + boundary + '\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n' + args.prompt +
        '\r\n--' + boundary + '\r\nContent-Disposition: form-data; name="image"; filename="source.' + (png ? 'png' : 'jpg') + '"\r\nContent-Type: image/' + (png ? 'png' : 'jpeg') + '\r\n\r\n');
      const suffix = encoder.encodeInto('\r\n--' + boundary + '--\r\n'); const buffer = new Uint8Array(prefix.byteLength + bytes.byteLength + suffix.byteLength);
      buffer.set(prefix); buffer.set(new Uint8Array(bytes), prefix.byteLength); buffer.set(suffix, prefix.byteLength + bytes.byteLength);
      body = buffer.buffer as ArrayBuffer; contentType = 'multipart/form-data; boundary=' + boundary;
    } else { const payload: Record<string, string | number> = { 'model': this.model, 'prompt': args.prompt, 'n': 1 }; body = JSON.stringify(payload); }
    const request = http.createHttp(); const remove = cancellation.onCancel(() => request.destroy());
    try {
      const headers: Record<string, string> = { 'Content-Type': contentType }; if (key) { headers['Authorization'] = 'Bearer ' + key; }
      const response = await request.request(base + (args.source ? '/images/edits' : '/images/generations'), { method: http.RequestMethod.POST,
        header: headers, extraData: body, usingCache: false, maxRedirects: 0, connectTimeout: 15000, readTimeout: 180000,
        maxLimit: 16 * 1024 * 1024, expectDataType: http.HttpDataType.STRING });
      cancellation.check(); if (response.responseCode !== 200) { throw new Error(t("图片服务 HTTP ") + response.responseCode + t("，请检查图片模型及接口支持情况。未自动重试。")); }
      const parsed = JSON.parse(response.result as string) as ImageResponse; const result = parsed?.data?.[0];
      let bytes: ArrayBuffer;
      if (result?.b64_json) { if (result.b64_json.length > 12 * 1024 * 1024) { throw new Error(t("返回图片过大。")); } bytes = new util.Base64Helper().decodeSync(result.b64_json).buffer as ArrayBuffer; }
      else if (result?.url && /^https:\/\/[^\s@\\]+$/.test(result.url)) {
        const download = http.createHttp(); const detach = cancellation.onCancel(() => download.destroy());
        try {
          const image = await download.request(result.url, { method: http.RequestMethod.GET, usingCache: false, maxRedirects: 0,
            maxLimit: 8 * 1024 * 1024, readTimeout: 60000, expectDataType: http.HttpDataType.ARRAY_BUFFER });
          if (image.responseCode !== 200) { throw new Error(t("生成图片下载失败。")); } bytes = image.result as ArrayBuffer;
        } finally { detach(); download.destroy(); }
      } else { throw new Error(t("图片服务没有返回图片。")); }
      cancellation.check();
      const raw = this.root + '/.tinybot-image-' + util.generateRandomUUID(); await writeBytes(raw, bytes);
      let item: Attachment;
      try { item = await Attachments.import(raw, true); } finally { await fs.unlink(raw); }
      item.name = '生成图片-' + item.id.slice(0, 8) + '.jpg';
      const input = await fs.open(Attachments.path(item), fs.OpenMode.READ_ONLY);
      try { await writeBytes(this.root + '/' + item.name, await readBounded(input.fd, 4 * 1024 * 1024)); } finally { await fs.close(input); }
      const output: ImageResult = { path: item.name, attachment: item }; return JSON.stringify(output);
    } finally { remove(); request.destroy(); }
  }
}
