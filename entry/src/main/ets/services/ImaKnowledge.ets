import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { t } from '../model/I18n';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation } from './Cancellation';
import { readDocumentFile } from './DocumentFiles';
import { withFileMutation } from './FileMutationQueue';
import { ImaClient, ImaFileInfo, ImaNamedMedia, ImaSession } from './ImaClient';
import { ImaMediaLink, ImaTransfers, ImaUploadGrant, imaFileType } from './ImaTransfers';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';

interface ImaMedia {
  media_type: number;
  url_info?: ImaMediaLink;
  notebook_ext_info?: ImaNotebookReference;
}
interface ImaNotebookReference { notebook_id: string; }
interface ImaNote { content: string; }
interface ImaCreatedMedia { media_id: string; cos_credential: ImaUploadGrant; }
interface ImaAddedMedia { media_id: string; }
interface ImaDuplicateCheck { results: ImaDuplicate[]; }
interface ImaDuplicate { name: string; is_repeated: boolean; }

export interface ImaDestination { knowledgeBaseId: string; folderId?: string; }
interface ImaReadResult { mediaId: string; content: string; truncated: boolean; }
interface ImaDownloadResult { mediaId: string; path: string; }
interface ImaUploadResult { mediaId: string; fileName: string; }
type ImaApproval = (title: string, details: string, cancellation: Cancellation) => Promise<void>;

const TEXT_EXTENSIONS: string[] = ['txt', 'md', 'markdown', 'csv', 'html', 'htm', 'pdf', 'docx', 'xlsx', 'pptx'];
const MIME_EXTENSIONS: Record<string, string> = {
  'application/pdf': 'pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'text/plain': 'txt',
  'text/markdown': 'md',
  'text/html': 'html',
  'text/csv': 'csv'
};
const READ_LIMIT: number = 25 * 1024 * 1024;
const CONTENT_LIMIT: number = 30000;

function extension(name: string): string { return /\.([a-z0-9]+)$/i.exec(name)?.[1]?.toLowerCase() || ''; }

function unavailable(): ToolFailure {
  return new ToolFailure('PERMISSION_DENIED', t('腾讯 ima 未开放此条目的原文，请在 ima 客户端查看。'), 'check_permissions');
}

function invalidResponse(): ToolFailure {
  return new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 返回了无效响应。'), 'inspect_service');
}

export class ImaKnowledge {
  private client: ImaClient;
  private workspace: NativeWorkspaceFiles;
  private cache: string;
  private approval?: ImaApproval;
  private transfers: ImaTransfers = new ImaTransfers();

  constructor(client: ImaClient, workspace: NativeWorkspaceFiles, cache: string, approval?: ImaApproval) {
    this.client = client; this.workspace = workspace; this.cache = cache; this.approval = approval;
  }

  private async original(session: ImaSession, id: string): Promise<ImaMedia> {
    const media = await session.query('get_media_info', { media_id: id }) as ImaMedia;
    if (media.media_type === 11 && typeof media.notebook_ext_info?.notebook_id === 'string' && media.notebook_ext_info.notebook_id) { return media; }
    if (typeof media.url_info?.url === 'string' && media.url_info.url) { return media; }
    throw unavailable();
  }

  private async note(session: ImaSession, media: ImaMedia): Promise<string> {
    const id = media.notebook_ext_info?.notebook_id;
    if (!id) { throw unavailable(); }
    const result = await session.query('get_doc_content', { note_id: id, target_content_format: 0 }) as ImaNote;
    if (typeof result.content !== 'string') { throw invalidResponse(); }
    return result.content;
  }

  private async temporary<T>(use: (path: string) => Promise<T>): Promise<T> {
    const path = this.cache + '/.tinybot-ima-' + util.generateRandomUUID();
    try { return await use(path); }
    finally { if (await fs.access(path)) { await fs.unlink(path); } }
  }

  async read(id: string, fileName: string, cancellation: Cancellation): Promise<ImaReadResult> {
    return this.client.withAccess(cancellation, async (session): Promise<ImaReadResult> => {
      const media = await this.original(session, id);
      const content = media.media_type === 11 ? await this.note(session, media) :
        await this.temporary(async (path) => {
          const mime = await this.transfers.download(media.url_info!, path, cancellation, session.checkAccess);
          const fileExtension = Object.keys(MIME_EXTENSIONS).includes(mime) ? MIME_EXTENSIONS[mime] :
            extension(fileName || media.url_info!.url.split('?')[0]);
          if (!TEXT_EXTENSIONS.includes(fileExtension)) {
            throw new ToolFailure('UNSUPPORTED_FORMAT', t('此原文格式可下载到工作区。'), 'choose_another_path');
          }
          const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
          try {
            if ((await fs.stat(file.fd)).size > READ_LIMIT) {
              throw new ToolFailure('LIMIT_EXCEEDED', t('原文超出直接读取上限，请下载到工作区。'), 'choose_another_path');
            }
            return await readDocumentFile(file.fd, 'ima.' + fileExtension, this.cache, cancellation);
          } finally { await fs.close(file); }
        });
      return { mediaId: id, content: content.slice(0, CONTENT_LIMIT), truncated: content.length > CONTENT_LIMIT };
    });
  }

  async download(id: string, name: string, cancellation: Cancellation): Promise<ImaDownloadResult> {
    if (/[\\/:\u0000-\u001f\u007f]/.test(name) || name === '.' || name === '..' || name.startsWith('.tinybot-')) {
      throw new ToolFailure('INVALID_ARGUMENTS', t('请填写不带目录的文件名。'), 'fix_arguments');
    }
    return this.client.withAccess(cancellation, async (session): Promise<ImaDownloadResult> => {
      const media = await this.original(session, id);
      const destination = 'ima/' + name;
      if (media.media_type === 11) {
        const content = await this.note(session, media);
        session.checkAccess();
        const bytes = content ? new util.TextEncoder().encodeInto(content) : new Uint8Array(0);
        await this.workspace.createJobOutput(destination, bytes, cancellation);
      } else {
        await this.temporary(async (path) => {
          await this.transfers.download(media.url_info!, path, cancellation, session.checkAccess);
          session.checkAccess();
          await this.workspace.importFile(path, destination);
        });
      }
      return { mediaId: id, path: destination };
    });
  }

  async upload(target: ImaDestination, path: string, cancellation: Cancellation): Promise<ImaUploadResult> {
    const name = path.slice(path.lastIndexOf('/') + 1);
    const ext = extension(name), type = imaFileType(ext);
    const details = [name, target.knowledgeBaseId, target.folderId || ''].filter(value => value).join('\n');
    await this.approval?.(t('允许上传文件到腾讯 ima？'), details, cancellation);
    const key = 'ima-upload:' + JSON.stringify([target.knowledgeBaseId, target.folderId, name, type.media]);
    return withFileMutation(key, () => this.client.withAccess(cancellation, (session) =>
      this.workspace.withJobInput(path, type.maximum, cancellation, async (fd, size, modifiedAt): Promise<ImaUploadResult> => {
        if (type.media !== 15) {
          const names: ImaNamedMedia[] = [{ name: name, media_type: type.media }];
          const existing = await session.query('check_repeated_names', { knowledge_base_id: target.knowledgeBaseId,
            folder_id: target.folderId, params: names }) as ImaDuplicateCheck;
          const match = existing.results?.find(row => row.name === name);
          if (typeof match?.is_repeated !== 'boolean') { throw invalidResponse(); }
          if (match.is_repeated) {
            throw new ToolFailure('ALREADY_EXISTS', t('腾讯 ima 目标文件夹中已有同名文件。'), 'choose_another_path');
          }
        }
        const media = await session.query('create_media', { knowledge_base_id: target.knowledgeBaseId,
          file_name: name, file_size: size, content_type: type.mime, file_ext: ext }) as ImaCreatedMedia;
        if (typeof media.media_id !== 'string' || !media.media_id) { throw invalidResponse(); }
        await this.transfers.upload(media.cos_credential, fd, size, type.mime, cancellation, session.checkAccess);
        const file: ImaFileInfo = { cos_key: media.cos_credential.cos_key, file_name: name, file_size: size,
          last_modify_time: Math.floor(modifiedAt) };
        const saved = await session.query('add_knowledge', { knowledge_base_id: target.knowledgeBaseId,
          folder_id: target.folderId, media_type: type.media, title: name, media_id: media.media_id, file_info: file }) as ImaAddedMedia;
        if (typeof saved.media_id !== 'string' || !saved.media_id) { throw invalidResponse(); }
        return { mediaId: saved.media_id, fileName: name };
      })));
  }

  async importLinks(target: ImaDestination, links: string[], cancellation: Cancellation): Promise<Object> {
    await this.approval?.(t('允许导入链接到腾讯 ima？'), [target.knowledgeBaseId, target.folderId || ''].concat(links).join('\n'), cancellation);
    return this.client.query('import_urls', { knowledge_base_id: target.knowledgeBaseId, folder_id: target.folderId || target.knowledgeBaseId,
      urls: links }, cancellation);
  }

  async addReference(target: ImaDestination, kind: string, id: string, title: string, cancellation: Cancellation): Promise<Object> {
    await this.approval?.(t('允许添加资料到腾讯 ima？'), [title, target.knowledgeBaseId, target.folderId || ''].join('\n'), cancellation);
    return this.client.query('add_knowledge', { knowledge_base_id: target.knowledgeBaseId, folder_id: target.folderId,
      title: title, media_type: kind === 'note' ? 11 : 12,
      note_info: kind === 'note' ? { content_id: id } : undefined,
      session_info: kind === 'session' ? { content_id: id } : undefined }, cancellation);
  }
}
