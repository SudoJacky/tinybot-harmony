import { fileIo as fs } from '@kit.CoreFileKit';
import { Attachment } from '../model/Productivity';
import { Attachments } from './Attachments';
import { Cancellation } from './Cancellation';
import { readBounded } from './FileBytes';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { FileJobWorkspace } from './WorkspaceFiles';

export class NativeImageWorkspace implements FileJobWorkspace {
  private files: NativeWorkspaceFiles;
  private attachments: () => Attachment[];

  constructor(files: NativeWorkspaceFiles, attachments: () => Attachment[]) {
    this.files = files;
    this.attachments = attachments;
  }

  async readJobInput(path: string, maximum: number, cancellation: Cancellation): Promise<Uint8Array> {
    const photo = this.attachments().find((item) => !item.original && item.mime === 'image/jpeg' && item.path === path);
    if (!photo) { return this.files.readJobInput(path, maximum, cancellation); }
    const file = await fs.open(Attachments.path(photo), fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const bytes = await readBounded(file.fd, Math.min(photo.size, maximum));
      cancellation.check();
      return new Uint8Array(bytes);
    } finally { await fs.close(file); }
  }

  createJobOutput(path: string, bytes: Uint8Array, cancellation: Cancellation): Promise<void> {
    return this.files.createJobOutput(path, bytes, cancellation);
  }
}
