import { PanelInputs } from '../model/PanelContract';
import { util } from '@kit.ArkTS';
import { PanelSource, validatePanelSource, panelQueryAddress } from '../model/PanelSource';
import { CompatHttp, CompatResponse } from './CompatHttp';
import { Cancellation, RunCancelledError } from './Cancellation';
import { NetworkTransfers } from './NetworkTransfers';
import { PanelCredentials } from './PanelCredentials';
import { Diagnostics } from '../model/Diagnostics';
import { BusinessError } from '@kit.BasicServicesKit';

export class PanelApiTransport {
  private credentials: PanelCredentials;
  constructor(credentials: PanelCredentials) { this.credentials = credentials; }
  async read(id: string, source: PanelSource, cancellation: Cancellation, inputs: PanelInputs = {}): Promise<string> {
    validatePanelSource(source); cancellation.check();
    const started = Date.now();
    let address = panelQueryAddress(source, inputs);
    const headers: Record<string, string> = {};
    const customHeaders: Record<string, string> = source.headers || {};
    for (const key of Object.keys(customHeaders)) { headers[key] = customHeaders[key]; }
    if (!Object.keys(headers).some((key: string) => key.toLowerCase() === 'accept')) { headers['Accept'] = 'application/json'; }
    if (source.body !== undefined && !Object.keys(headers).some((key: string) => key.toLowerCase() === 'content-type')) { headers['Content-Type'] = 'application/json'; }
    if (source.auth) {
      const secret = await this.credentials.secret(id, source); cancellation.check();
      if (source.auth.type === 'api-key') {
        const value = (source.auth.prefix || '') + secret;
        if (source.auth.in === 'header') { headers[source.auth.name!] = value; }
        else { address += (address.includes('?') ? '&' : '?') + encodeURIComponent(source.auth.name!) + '=' + encodeURIComponent(value); }
      } else { headers['Authorization'] = 'Bearer ' + secret; }
    }
    const endTransfer = await NetworkTransfers.begin(cancellation);
    try {
      // Each refresh makes exactly one request. POST query bodies are never automatically replayed.
      const response = await new Promise<CompatResponse>((resolve, reject) => {
        let settled = false, abort = (): void => {}, remove = (): void => {};
        const finish = (value?: CompatResponse, error?: Error): void => {
          if (settled) { return; } settled = true; clearTimeout(timer); remove();
          if (error) { abort(); reject(error); } else { resolve(value!); }
        };
        const timer = setTimeout(() => finish(undefined, new Error('API query timed out after 30 seconds')), 30000);
        remove = cancellation.onCancel(() => finish(undefined, new RunCancelledError() as Error));
        if (settled) { return; }
        CompatHttp.request({ url: address, method: source.method || 'GET', headers: headers,
          body: source.body === undefined ? undefined : JSON.stringify(source.body), connectTimeout: 10000, readTimeout: 30000,
          maxBytes: 256 * 1024, dataType: 'buffer', redirect: 'return' }, (stop: () => void) => { abort = stop; })
          .then((value: CompatResponse) => finish(value))
          // Platform errors may echo headers/URLs. Persist only a generic transport failure.
          .catch((error: Error) => {
            const code = (error as BusinessError).code;
            Diagnostics.log('error', 'life-panel', 'api_failed', { previewId: id, code: typeof code === 'number' ? code : undefined, cancelled: cancellation.cancelled });
            finish(undefined, cancellation.cancelled ? new RunCancelledError() : new Error('API transport failed; check connection and endpoint'));
          });
      });
      cancellation.check();
      Diagnostics.log('info', 'life-panel', 'api_response', { previewId: id, http: response.status, bytes: response.bytes.byteLength, elapsedMs: Date.now() - started });
      if (response.status >= 300 && response.status < 400) { throw new Error('API redirect refused. Configure the final HTTPS endpoint.'); }
      if (response.status === 401 || response.status === 403) { throw new Error('API authentication rejected (HTTP ' + response.status + '). Reconnect the card or check its permissions.'); }
      if (response.status < 200 || response.status >= 300) { throw new Error('API query returned HTTP ' + response.status); }
      if (response.bytes.byteLength > 256 * 1024) { throw new Error('API response exceeds 256 KiB'); }
      return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(response.bytes));
    } finally { await endTransfer(); }
  }
}
