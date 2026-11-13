import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ImageServiceAccess } from '../model/ProviderProfiles';
import { Diagnostics } from '../model/Diagnostics';
import { ToolFailure, toolHttpFailure } from '../model/ToolFailure';
import { CredentialReader } from './providers/Provider';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CompatHttp, CompatRequest, CompatResponse } from './CompatHttp';
import { NetworkTransfers } from './NetworkTransfers';
import { ImageGenerator, ImageGenerationInput, ImageReference, MAX_IMAGE_BYTES, rasterMime } from './ImageGenerationTools';
import { ImageEncoding, imageRequest, imageResponse } from './ImageGenerationProtocol';

const RESPONSE_LIMIT: number = Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 512 * 1024;

export class NativeImageGenerator implements ImageGenerator {
  private profile: ImageServiceAccess;
  private model: string;
  private credentials: CredentialReader;
  constructor(profile: ImageServiceAccess, model: string, credentials: CredentialReader) {
    this.profile = profile;
    this.model = model;
    this.credentials = credentials;
  }

  async generate(input: ImageGenerationInput, references: ImageReference[], cancellation: Cancellation): Promise<Uint8Array> {
    cancellation.check();
    const started = Date.now();
    let stage = 'credential';
    let bytes: Uint8Array;
    try {
      const key = await this.credentials.read(this.profile.credentialAlias);
      cancellation.check();
      stage = 'generate';
      const codec = new util.Base64Helper();
      const encoding: ImageEncoding = { base64: (value) => codec.encodeToStringSync(value),
        utf8: (value) => new util.TextEncoder().encodeInto(value), boundary: () => 'tinybot-' + util.generateRandomUUID() };
      const request = imageRequest(this.profile, this.model, key, input, references, encoding);
      const response = await this.exchange({ url: request.url, method: 'POST', headers: request.headers, body: request.body,
        connectTimeout: 15000, readTimeout: 180000, maxBytes: RESPONSE_LIMIT, dataType: 'string', redirect: 'refuse' }, cancellation);
      stage = 'decode';
      const result = imageResponse(this.profile.protocol, response.text);
      if (result.base64) {
        if (result.base64.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4) {
          throw new ToolFailure('LIMIT_EXCEEDED', 'The generated image exceeds the download limit.', 'inspect_service');
        }
        try { bytes = codec.decodeSync(result.base64); }
        catch (_) { throw new ToolFailure('INVALID_RESPONSE', 'The image service returned invalid Base64.', 'inspect_service'); }
      } else {
        stage = 'download';
        const url = result.url || '';
        if (url.length > 8192 || !/^https:\/\/[^\s/?#@\\:]+(?::\d+)?(?:[/?][^\s#\\]*)?$/.test(url)) {
          throw new ToolFailure('INVALID_RESPONSE', 'The image service returned an invalid HTTPS download URL.', 'inspect_service');
        }
        const download = await this.exchange({ url: url, method: 'GET', headers: { 'Accept': 'image/*' },
          connectTimeout: 15000, readTimeout: 60000, maxBytes: MAX_IMAGE_BYTES, dataType: 'buffer', redirect: 'refuse' }, cancellation);
        bytes = new Uint8Array(download.bytes);
      }
      if (bytes.length > MAX_IMAGE_BYTES || !rasterMime(bytes)) {
        throw new ToolFailure('INVALID_RESPONSE', 'Image service returned an invalid or oversized raster image.', 'inspect_service');
      }
    } catch (error) {
      const failure = error as ToolFailure;
      Diagnostics.log(cancellation.cancelled ? 'info' : 'warn', 'image-generation', 'request_failed',
        { protocol: this.profile.protocol, providerId: this.profile.id, phase: stage, elapsedMs: Date.now() - started,
          cancelled: cancellation.cancelled }, failure);
      throw error as Error;
    }
    Diagnostics.log('info', 'image-generation', 'request_complete', { protocol: this.profile.protocol,
      providerId: this.profile.id, elapsedMs: Date.now() - started, bytes: bytes.length });
    return bytes;
  }

  private async exchange(request: CompatRequest, cancellation: Cancellation): Promise<CompatResponse> {
    const end = await NetworkTransfers.begin(cancellation);
    try {
      cancellation.check();
      return await new Promise<CompatResponse>((resolve, reject) => {
        let stop = (): void => {};
        const unsubscribe = cancellation.onCancel(() => { reject(new RunCancelledError()); stop(); });
        CompatHttp.request(request, (abort) => { stop = abort; }).then((response) => {
          cancellation.check();
          if (response.status < 200 || response.status >= 300) {
            throw toolHttpFailure(response.status, 'Image service ' + request.method + ' returned HTTP ' + response.status + '.', this.profile.protocol);
          }
          resolve(response);
        }).catch((error: Error) => {
          const native = error as BusinessError;
          reject(error instanceof ToolFailure ? error :
            new ToolFailure('NETWORK_ERROR', 'Image service network request failed.', 'check_connection', { nativeCode: native.code }));
        }).finally(unsubscribe);
      });
    } finally { await end(); }
  }
}
