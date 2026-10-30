import { common } from '@kit.AbilityKit';
import { Diagnostics } from '../model/Diagnostics';
import { preferences } from '@kit.ArkData';
import { CredentialStore } from './CredentialStore';
import { CompatHttp, CompatResponse } from './CompatHttp';
import { hostedPrivacy } from './HostedPrivacy';
import { FeedbackFiles } from './FeedbackFiles';
import { t } from '../model/I18n';
import { FeedbackAttachment, FeedbackCounts, FeedbackDraft, FeedbackFilter, FeedbackItem, FeedbackType, FeedbackTypeFilter,
  FeedbackUpload, feedbackInput, parseFeedbackAttachment, parseFeedbackDetail, parseFeedbackIdentity, parseFeedbackPage,
  parseFeedbackReceipt, validFeedbackFilename, validFeedbackToken } from '../model/Feedback';

const BASE: string = 'https://sudotinybot.cn/api/feedback';
const ALIAS: string = 'tinybot.feedback.identity.v1';
interface UploadQueue { feedbackId: string; files: FeedbackUpload[]; }
function copyUpload(file: FeedbackUpload): FeedbackUpload { return JSON.parse(JSON.stringify(file)) as FeedbackUpload; }
class FeedbackHttpError extends Error {
  status: number;
  constructor(status: number, seconds: number) {
    super(status === 429 ? t('请求过于频繁，请 {0} 秒后重试。', [seconds]) : status === 401 ?
      t('反馈凭证无效，无法访问原有反馈。凭证已保留，请联系开发者。') : status === 404 ?
      t('这条反馈不存在、已删除或无法访问。') : status === 409 ? t('这条反馈的附件数量已满，请删除不需要的附件后重试。') :
      status === 507 ? t('反馈附件存储额度已满，请删除不需要的附件后重试。') : t('反馈请求失败（HTTP {0}），请稍后重试。', [status]));
    this.status = status;
  }
}

// Installation-local identity and view state. No credentials, drafts or replies enter backups or logs.
@Observed
export class FeedbackService {
  ready: boolean = false;
  busy: boolean = false;
  error: string = '';
  notice: string = '';
  body: string = '';
  contact: string = '';
  type: FeedbackType = 'other';
  uncertain: boolean = false;
  items: FeedbackItem[] = [];
  detail: FeedbackItem | null = null;
  filter: FeedbackFilter = 'all';
  typeFilter: FeedbackTypeFilter = 'all';
  uploads: FeedbackUpload[] = [];
  attachmentFeedbackId: string = '';
  uploadsChecked: boolean = false;
  progress: string = '';
  nextCursor: string | null = null;
  counts: FeedbackCounts = { new: 0, handled: 0 };
  private vault: CredentialStore = new CredentialStore();
  private store?: preferences.Preferences;
  private seen: Record<string, string> = {};
  private token: string = '';
  private unsavedToken: string = '';
  private cooldowns: Record<string, number> = {};

  async initialize(context: common.Context): Promise<void> {
    if (this.ready || this.busy) { return; }
    this.busy = true; this.error = '';
    let phase: string = 'storage';
    try {
      FeedbackFiles.configure(context);
      this.store = preferences.getPreferencesSync(context, { name: 'tinybot-feedback' });
      this.seen = JSON.parse(this.store.getSync('seenReplies', '{}') as string) as Record<string, string>;
      if (!this.seen || typeof this.seen !== 'object' || Array.isArray(this.seen) ||
        !Object.keys(this.seen).every((key: string) => typeof this.seen[key] === 'string')) { throw new Error('Invalid reply view state'); }
      const pending = this.store.getSync('pendingSubmission', '') as string;
      if (pending) {
        const draft = JSON.parse(pending) as FeedbackDraft;
        const input = feedbackInput(draft.body, draft.contact, draft.type || 'other');
        this.body = input.body; this.contact = input.contact; this.type = input.type; this.uncertain = true;
      }
      const queue = JSON.parse(this.store.getSync('uploadQueue', '{"feedbackId":"","files":[]}') as string) as UploadQueue;
      if (!queue || typeof queue.feedbackId !== 'string' || !Array.isArray(queue.files) || queue.files.length > 4 ||
        !queue.files.every((file: FeedbackUpload) => !!file && typeof file.localId === 'string' && typeof file.path === 'string' &&
          typeof file.filename === 'string' && validFeedbackFilename(file.filename) && ['image', 'log'].includes(file.kind) &&
          ['pending', 'uploaded', 'failed', 'uncertain'].includes(file.state) && Array.isArray(file.beforeIds))) { throw new Error('Invalid upload queue'); }
      this.uploads = queue.files; this.attachmentFeedbackId = queue.feedbackId;
      // The durable receipt proves that text was saved even if the process stopped before clearing the draft.
      if (queue.feedbackId) { this.save('pendingSubmission', ''); this.uncertain = false; this.body = ''; this.contact = ''; }
      phase = 'credential';
      const token = await this.vault.readOptional(ALIAS);
      if (token !== undefined && !validFeedbackToken(token)) { throw new Error(t('本机反馈凭证无法读取，已保留原凭证。')); }
      this.token = token || ''; this.ready = true;
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'initialize_failed', { phase: phase }, error as Error);
      this.error = t('无法读取本机反馈记录或安全凭证，请解锁设备后重试。');
    }
    finally { this.busy = false; }
  }

  private save(key: string, value: string): void {
    if (!this.store) { throw new Error(t('反馈尚未就绪，请重新打开页面。')); }
    const previous = this.store.getSync(key, '');
    try { this.store.putSync(key, value); this.store.flushSync(); }
    catch (error) {
      Diagnostics.log('error', 'feedback', 'save_failed', { setting: 'feedback.' + key }, error as Error);
      this.store.putSync(key, previous);
      throw new Error(t('无法保存本机反馈记录，请检查存储空间后重试。'));
    }
  }

  private async identity(): Promise<void> {
    if (this.token) { return; }
    // Retain a freshly issued token in memory if secure storage failed; retry saving it before any POST.
    if (!this.unsavedToken) { this.unsavedToken = parseFeedbackIdentity(await this.request('/identity', 'identity', '', '{"schemaVersion":1}', 201)).token; }
    try { await this.vault.write(ALIAS, this.unsavedToken); }
    catch (error) {
      Diagnostics.log('error', 'feedback', 'credential_failed', undefined, error as Error);
      throw new Error(t('无法安全保存反馈凭证，尚未提交反馈。请解锁设备后重试。'));
    }
    this.token = this.unsavedToken; this.unsavedToken = '';
  }

  private async exchange(path: string, bucket: string, token: string, method: string, body?: string | ArrayBuffer,
    expected: number = 200, extraHeaders: Record<string, string> = {}, binary: boolean = false): Promise<CompatResponse> {
    hostedPrivacy.requireConsent();
    const remaining = Math.ceil(((this.cooldowns[bucket] || 0) - Date.now()) / 1000);
    if (remaining > 0) { throw new FeedbackHttpError(429, remaining); }
    const started = Date.now();
    try {
      const headers: Record<string, string> = { 'Accept': 'application/json' };
      if (token) { headers['Authorization'] = 'Bearer ' + token; }
      if (body !== undefined) { headers['Content-Type'] = 'application/json'; }
      Object.keys(extraHeaders).forEach((key: string) => { headers[key] = extraHeaders[key]; });
      // A submission and its attachments carry the feedback identity, so a redirect is refused
      // rather than followed to another origin.
      const response = await CompatHttp.request({
        url: BASE + path, method: method, headers: headers,
        body: body,
        connectTimeout: 10000, readTimeout: 30000, maxBytes: binary ? 5 * 1024 * 1024 : 1024 * 1024,
        dataType: binary ? 'buffer' : 'string', redirect: 'refuse'
      });
      if (response.status !== expected) {
        const key = Object.keys(response.header).find((name: string) => name.toLowerCase() === 'retry-after');
        const seconds = Math.max(1, Math.ceil(Number(key ? response.header[key] : '60') || 60));
        if (response.status === 429) { this.cooldowns[bucket] = Date.now() + seconds * 1000; }
        throw new FeedbackHttpError(response.status, seconds);
      }
      return response;
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'request_failed', { phase: bucket, elapsedMs: Date.now() - started,
        http: error instanceof FeedbackHttpError ? error.status : 0 }, error as Error);
      if (error instanceof FeedbackHttpError) { throw error; }
      throw new Error(t('无法连接反馈服务，请检查网络后重试。'));
    }
  }
  private async request(path: string, bucket: string, token: string, body?: string, expected: number = 200): Promise<string> {
    const response = await this.exchange(path, bucket, token, body === undefined ? 'GET' : 'POST', body, expected);
    if (!response.text) { throw new Error(t('反馈服务返回的数据无效，请稍后刷新。')); }
    return response.text;
  }

  async submit(): Promise<boolean> {
    if (!this.ready || this.busy || this.uncertain || this.attachmentFeedbackId) { return false; }
    this.busy = true; this.error = ''; this.notice = '';
    let sent = false;
    try {
      const draft = feedbackInput(this.body, this.contact, this.type);
      hostedPrivacy.requireConsent();
      await this.identity();
      this.save('pendingSubmission', JSON.stringify(draft));
      this.uncertain = true; sent = true;
      const receipt = parseFeedbackReceipt(await this.request('', 'submit', this.token,
        JSON.stringify({ schemaVersion: 1, type: draft.type, body: draft.body, contact: draft.contact }), 201));
      if (this.uploads.length) { this.commitUploads(this.uploads, receipt.id); }
      this.save('pendingSubmission', ''); this.uncertain = false;
      this.body = ''; this.contact = ''; this.type = 'other'; this.notice = t('反馈已提交，可在“我的反馈”查看处理状态和回复。');
      if (this.uploads.length) {
        try { await this.uploadFiles(); }
        catch (error) {
          Diagnostics.log('error', 'feedback', 'upload_failed', undefined, error as Error);
          this.error = t('反馈正文已提交，附件尚未全部上传。请在附件任务中继续。');
        }
      }
      return true;
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'submit_failed', { uncertain: this.uncertain }, error as Error);
      if (sent && error instanceof FeedbackHttpError && error.status >= 400 && error.status < 500) {
        try { this.save('pendingSubmission', ''); this.uncertain = false; }
        catch (storageError) { this.error = (storageError as Error).message; return false; }
      }
      this.error = this.uncertain ? t('提交结果尚未确认，请先查询近期反馈，避免重复提交。') :
        error instanceof FeedbackHttpError ? error.message : sent ? t('反馈提交失败，请稍后重试。') : (error as Error).message;
      return false;
    } finally { this.busy = false; this.progress = ''; }
  }

  // Explicit user confirmation after reviewing recent records, never an automatic retry.
  resolveUncertain(): void {
    if (this.busy) { return; }
    try { this.save('pendingSubmission', ''); this.uncertain = false; this.error = ''; }
    catch (error) { this.error = (error as Error).message; }
  }

  async load(filter: FeedbackFilter = this.filter, more: boolean = false, type: FeedbackTypeFilter = this.typeFilter): Promise<void> {
    if (!this.ready || this.busy || more && !this.nextCursor) { return; }
    this.busy = true; this.error = '';
    try {
      if (!this.token) { this.items = []; this.nextCursor = null; this.filter = filter; this.typeFilter = type; return; }
      const cursor = more ? this.nextCursor : null;
      const page = parseFeedbackPage(await this.request('/mine?status=' + filter + '&type=' + type +
        (cursor ? '&before=' + encodeURIComponent(cursor) : ''), 'query', this.token));
      this.items = more ? this.items.concat(page.items.filter((item: FeedbackItem) => !this.items.some((old: FeedbackItem) => old.id === item.id))) : page.items;
      this.nextCursor = page.nextCursor; this.counts = page.counts; this.filter = filter; this.typeFilter = type;
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'list_failed', undefined, error as Error);
      this.error = error instanceof FeedbackHttpError ? error.message : t('无法加载反馈，请检查网络后重试。');
    }
    finally { this.busy = false; }
  }

  hasNewReply(item: FeedbackItem): boolean { return !!item.reply && this.seen[item.id] !== item.reply.updatedAt; }

  async open(id: string): Promise<void> {
    if (!this.ready || this.busy || !this.token) { return; }
    this.busy = true; this.error = '';
    try {
      const item = parseFeedbackDetail(await this.request('/' + encodeURIComponent(id), 'query', this.token));
      if (item.id !== id) { throw new Error('Mismatched feedback ID'); }
      this.detail = item;
      this.items = this.items.map((old: FeedbackItem) => old.id === item.id ? item : old);
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'detail_failed', undefined, error as Error);
      this.error = error instanceof FeedbackHttpError ? error.message : t('无法读取反馈详情或保存已读状态，请稍后重试。');
    }
    finally { this.busy = false; }
  }

  markViewed(item: FeedbackItem): void {
    if (!item.reply) { return; }
    try {
      const next: Record<string, string> = {};
      Object.keys(this.seen).forEach((key: string) => { next[key] = this.seen[key]; });
      next[item.id] = item.reply.updatedAt;
      this.save('seenReplies', JSON.stringify(next)); this.seen = next;
    } catch (_) { this.error = t('无法读取反馈详情或保存已读状态，请稍后重试。'); }
  }

  private commitUploads(files: FeedbackUpload[], feedbackId: string = this.attachmentFeedbackId): void {
    this.save('uploadQueue', JSON.stringify({ feedbackId: feedbackId, files: files }));
    this.uploads = files; this.attachmentFeedbackId = feedbackId;
  }
  addUploads(files: FeedbackUpload[]): void {
    if (this.busy || this.uncertain || this.attachmentFeedbackId) { throw new Error(t('请先完成当前反馈的附件任务。')); }
    const next = this.uploads.concat(files);
    if (next.filter((file: FeedbackUpload) => file.kind === 'image').length > 3 || next.filter((file: FeedbackUpload) => file.kind === 'log').length > 1) {
      throw new Error(t('每条反馈最多添加 3 张图片和 1 份日志。'));
    }
    this.commitUploads(next);
  }
  async removeUpload(id: string): Promise<void> {
    if (this.busy) { return; }
    const file = this.uploads.find((item: FeedbackUpload) => item.localId === id);
    if (!file || file.state === 'uncertain') { return; }
    try {
      this.commitUploads(this.uploads.filter((item: FeedbackUpload) => item.localId !== id));
      await FeedbackFiles.remove(file.path);
    } catch (error) {
      Diagnostics.log('warn', 'feedback', 'cleanup_failed', undefined, error as Error);
      this.error = t('无法移除本机附件，请稍后重试。');
    }
  }
  async clearUploadTask(): Promise<void> {
    if (this.busy) { return; }
    try {
      const files = this.uploads.slice(); this.commitUploads([], '');
      for (const file of files) { await FeedbackFiles.remove(file.path); }
    } catch (error) {
      Diagnostics.log('warn', 'feedback', 'cleanup_failed', undefined, error as Error);
      this.error = t('无法移除本机附件，请稍后重试。');
    }
  }
  private replaceUpload(file: FeedbackUpload): void {
    this.commitUploads(this.uploads.map((old: FeedbackUpload) => old.localId === file.localId ? file : old));
  }
  private async currentUploadFeedback(): Promise<FeedbackItem> {
    const item = parseFeedbackDetail(await this.request('/' + encodeURIComponent(this.attachmentFeedbackId), 'query', this.token));
    if (item.id !== this.attachmentFeedbackId) { throw new Error('Mismatched attachment feedback'); }
    return item;
  }
  private async uploadFiles(): Promise<void> {
    if (!this.attachmentFeedbackId || this.uploads.some((file: FeedbackUpload) => file.state === 'uncertain')) { return; }
    const item = await this.currentUploadFeedback();
    for (let index = 0; index < this.uploads.length; index++) {
      const original = this.uploads[index];
      if (original.state === 'uploaded') { continue; }
      this.progress = t('正在上传附件 {0}/{1}', [index + 1, this.uploads.length]); this.uploadsChecked = false;
      let sending = false;
      try {
        const bytes = await FeedbackFiles.read(original);
        const file = copyUpload(original); file.state = 'uncertain'; file.error = '';
        file.beforeIds = item.attachments.map((remote: FeedbackAttachment) => remote.id);
        this.replaceUpload(file); sending = true;
        const response = await this.exchange('/' + encodeURIComponent(item.id) + '/attachments', 'upload', this.token, 'POST', bytes, 201,
          { 'Content-Type': file.mimeType, 'X-Attachment-Kind': file.kind, 'X-File-Name': encodeURIComponent(file.filename) });
        if (!response.text) { throw new Error('Invalid attachment response'); }
        const remote = parseFeedbackAttachment(response.text);
        if (remote.kind !== file.kind || remote.filename !== file.filename.replace(/\.[^.]+$/, remote.kind === 'image' ? '.webp' : '.log')) {
          throw new Error('Mismatched attachment response');
        }
        file.state = 'uploaded'; file.remoteId = remote.id; this.replaceUpload(file); item.attachments.push(remote);
      } catch (error) {
        Diagnostics.log('error', 'feedback', 'upload_failed', { chunk: index + 1, total: this.uploads.length }, error as Error);
        const definite = !sending || error instanceof FeedbackHttpError && (error.status >= 400 && error.status < 500 || error.status === 507);
        const file = copyUpload(this.uploads[index]); file.state = definite ? 'failed' : 'uncertain';
        file.error = error instanceof FeedbackHttpError ? error.message : t('附件上传未完成，请核对后重试。');
        this.replaceUpload(file);
        this.error = t('反馈正文已提交，附件尚未全部上传。请在附件任务中继续。');
        break;
      }
    }
    this.progress = '';
    if (this.uploads.every((file: FeedbackUpload) => file.state === 'uploaded')) {
      const files = this.uploads.slice(); this.commitUploads([], '');
      for (const file of files) { await FeedbackFiles.remove(file.path); }
      this.notice = t('反馈和附件均已提交。');
    }
  }
  async retryUploads(): Promise<void> {
    if (!this.ready || this.busy || !this.attachmentFeedbackId) { return; }
    this.busy = true; this.error = '';
    try { await this.uploadFiles(); }
    catch (error) {
      Diagnostics.log('error', 'feedback', 'upload_failed', undefined, error as Error);
      this.error = error instanceof FeedbackHttpError ? error.message : t('反馈正文已提交，附件尚未全部上传。请在附件任务中继续。');
    }
    finally { this.busy = false; this.progress = ''; }
  }
  async reconcileUploads(): Promise<void> {
    if (!this.ready || this.busy || !this.attachmentFeedbackId) { return; }
    this.busy = true; this.error = ''; this.uploadsChecked = false;
    try {
      const item = await this.currentUploadFeedback();
      const files = this.uploads.map((file: FeedbackUpload) => {
        if (file.state !== 'uncertain') { return file; }
        const expectedName = file.kind === 'image' ? file.filename.replace(/\.[^.]+$/, '.webp') : file.filename;
        const found = item.attachments.find((remote: FeedbackAttachment) => remote.kind === file.kind && remote.filename === expectedName && !file.beforeIds.includes(remote.id));
        if (!found) { return file; }
        const next = copyUpload(file); next.state = 'uploaded'; next.remoteId = found.id; next.error = ''; return next;
      });
      this.commitUploads(files); this.detail = item; this.uploadsChecked = true;
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'reconcile_failed', undefined, error as Error);
      this.error = error instanceof FeedbackHttpError ? error.message : t('无法核对附件，请稍后刷新。');
    }
    finally { this.busy = false; }
  }
  resolveUploadUncertainty(): void {
    if (this.busy || !this.uploadsChecked) { return; }
    try {
      this.commitUploads(this.uploads.map((file: FeedbackUpload) => {
        const next = copyUpload(file); if (next.state === 'uncertain') { next.state = 'failed'; } return next;
      })); this.uploadsChecked = false;
    }
    catch (_) { this.error = t('无法保存本机反馈记录，请检查存储空间后重试。'); }
  }
  async attachToRecoveredFeedback(item: FeedbackItem): Promise<void> {
    if (!this.uncertain || this.busy || !this.uploads.length || item.body !== this.body.trim() || item.contact !== this.contact.trim() || item.type !== this.type) { return; }
    try {
      this.commitUploads(this.uploads, item.id); this.save('pendingSubmission', '');
      this.uncertain = false; this.body = ''; this.contact = ''; this.type = 'other';
      await this.retryUploads();
    } catch (_) { this.error = t('无法保存本机反馈记录，请检查存储空间后重试。'); }
  }
  async attachmentBytes(item: FeedbackItem, file: FeedbackAttachment): Promise<ArrayBuffer> {
    const response = await this.exchange('/' + encodeURIComponent(item.id) + '/attachments/' + encodeURIComponent(file.id), 'query', this.token,
      'GET', undefined, 200, { 'Accept': file.mimeType }, true);
    if (response.bytes.byteLength !== file.size) { throw new Error(t('反馈附件数据无效，请重新加载。')); }
    return response.bytes;
  }
  async deleteAttachment(item: FeedbackItem, file: FeedbackAttachment): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = '';
    try {
      const response = await this.exchange('/' + encodeURIComponent(item.id) + '/attachments/' + encodeURIComponent(file.id), 'query', this.token, 'DELETE');
      const result = JSON.parse(response.text) as Record<string, boolean>;
      if (result.deleted !== true) { throw new Error('Invalid deletion response'); }
      const next = JSON.parse(JSON.stringify(item)) as FeedbackItem;
      next.attachments = item.attachments.filter((old: FeedbackAttachment) => old.id !== file.id); this.detail = next;
      this.items = this.items.map((old: FeedbackItem) => old.id === item.id ? this.detail as FeedbackItem : old);
    } catch (error) {
      Diagnostics.log('error', 'feedback', 'delete_failed', undefined, error as Error);
      this.error = error instanceof FeedbackHttpError ? error.message : t('无法确认附件删除结果，请刷新详情后核对。');
    }
    finally { this.busy = false; }
  }
}

export const feedbackService: FeedbackService = new FeedbackService();
