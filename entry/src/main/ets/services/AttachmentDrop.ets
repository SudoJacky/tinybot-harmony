import { unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Attachment, MAX_MESSAGE_ATTACHMENTS } from '../model/Productivity';
import { t } from '../model/I18n';
import { Attachments } from './Attachments';

export const ATTACHMENT_DROP_TYPES: string[] = ['general.file-uri', 'general.file', 'general.image'];

interface DroppedFile { uri: string; photo: boolean; }

function isImage(type: string): boolean {
  return uniformTypeDescriptor.getTypeDescriptor(type).belongsTo('general.image');
}

// Prefer the file representation of a record; alternate representations are not additional attachments.
export function droppedFiles(data: unifiedDataChannel.UnifiedData, maximum: number): DroppedFile[] {
  const files: DroppedFile[] = [];
  const seen = new Set<string>();
  for (const record of data.getRecords()) {
    let uri: string = ''; let photo: boolean = false;
    if (record.getTypes().includes('general.file-uri')) {
      const file = record.getEntry('general.file-uri') as uniformDataStruct.FileUri;
      uri = file.oriUri; photo = isImage(file.fileType);
    } else if (isImage(record.getType())) {
      uri = (record as unifiedDataChannel.Image).imageUri; photo = true;
    } else if (record.getType() === 'general.file') {
      uri = (record as unifiedDataChannel.File).uri;
      // Legacy generic files may carry images without an image UTD.
      photo = /\.(jpe?g|png|webp|heic|heif|gif|bmp|avif|tiff?)(?:\?|$)/i.test(uri);
    }
    if (typeof uri !== 'string' || !uri.startsWith('file://')) {
      throw new Error(t('请拖入本地图片或文件，暂不支持链接、文件夹或纯位图。'));
    }
    if (!seen.has(uri)) { files.push({ uri: uri, photo: photo }); seen.add(uri); }
  }
  if (!files.length) { throw new Error(t('没有收到可添加的附件。')); }
  if (files.length > maximum) { throw new Error(t('每条消息最多添加 {0} 个附件。', [MAX_MESSAGE_ATTACHMENTS])); }
  return files;
}

export async function importDroppedAttachments(data: unifiedDataChannel.UnifiedData, maximum: number,
  isCurrent: () => boolean, commit: (items: Attachment[]) => Promise<void>): Promise<void> {
  const files = droppedFiles(data, maximum);
  const items: Attachment[] = [];
  let handedOff = false;
  try {
    for (const file of files) {
      if (!isCurrent()) { throw new Error(t('对话已切换或当前无法添加附件，请重新拖入。')); }
      items.push(await Attachments.import(file.uri, file.photo));
    }
    if (!isCurrent()) { throw new Error(t('对话已切换或当前无法添加附件，请重新拖入。')); }
    // Session persistence can fail after the draft has adopted the files. Keep them for Retry Save.
    handedOff = true;
    await commit(items);
  } finally {
    if (!handedOff) {
      for (const item of items) { await fs.unlink(Attachments.path(item)); }
    }
  }
}

// Own the native loading lifetime, including late/repeated callbacks and navigation cancellation.
export class AttachmentDrop {
  private key: string = '';
  private rejectLoad?: (error: Error) => void;
  load(event: DragEvent): Promise<unifiedDataChannel.UnifiedData> {
    return new Promise((resolve, reject) => {
      let finished = false;
      const fail = (error: Error): void => {
        if (finished) { return; }
        finished = true; this.key = ''; this.rejectLoad = undefined; reject(error);
      };
      this.rejectLoad = fail;
      try {
        const key = event.startDataLoading({
          progressIndicator: unifiedDataChannel.ProgressIndicator.NONE,
          dataProgressListener: (progress: unifiedDataChannel.ProgressInfo, data: unifiedDataChannel.UnifiedData | null): void => {
            if (finished) { return; }
            if (progress.status === unifiedDataChannel.ListenerStatus.FINISHED && data) {
              finished = true; this.key = ''; this.rejectLoad = undefined; resolve(data);
            } else if (progress.status !== unifiedDataChannel.ListenerStatus.PROCESSING) {
              fail(new Error(t('拖入数据读取失败（{0}）。', [progress.status])));
            }
          }
        });
        if (!finished) { this.key = key; }
      } catch (error) { fail(error as Error); }
    });
  }
  cancel(ui: UIContext): void {
    const key = this.key;
    if (this.rejectLoad) { this.rejectLoad(new Error(t('对话已切换或当前无法添加附件，请重新拖入。'))); }
    if (key) { ui.getDragController().cancelDataLoading(key); }
  }
}
